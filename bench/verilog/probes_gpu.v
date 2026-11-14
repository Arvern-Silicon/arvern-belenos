//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      probes_gpu
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : probes_gpu.v
// Module Description : GPU command and primitive tracer -> slipstream.log.
//                      One cycle-stamped row per GPU event:
//                        PSH  a word written to GPU_CMD (DROP: dropped)
//                        CMD  a command word decoded (with its operand)
//                        GO   a primitive leaves the set-up for the engine
//                        END  a primitive completes, draws nothing or is
//                             abandoned: its cycles, pixels and VRAM accesses
//                        LST  a command list ends
//                        ERR  the decoder stops on an error
//                        CTL  CLEAR_ERR, ABORT, DISCARD, GPU_EN, the FIFO
//                             words a flush dropped (FLUSHED), a DISCARD
//                             marker queued (MARK) and reached (MARK done),
//                             freeze / release
//                        BSY, IDL, WAI, FRM  busy / idle, WAIT_REFR_DONE,
//                             display frames
//                      Every primitive gets an id (#n) at its EXEC and ends
//                      in exactly one END row.
//                      Observer only: cross-module references rooted at
//                      `BLNS_INST (default dut). Cycles: `BLNS_TRACE_CYCLE
//                      when defined (an existing counter, e.g. the asphalt
//                      one), else a counter on `BLNS_TRACE_CLK (default the
//                      Belenos clock). NOTRACE stops the file only: the
//                      references stay elaborated. Format specification:
//                      doc/slipstream_trace_format.md.
//----------------------------------------------------------------------------
`ifndef BLNS_INST
`define BLNS_INST dut
`endif
`ifndef BLNS_TRACE_CLK
`define BLNS_TRACE_CLK `BLNS_INST.hclk_i
`endif

module probes_gpu #(
  parameter GPU_EN  = 1,
  parameter LOGFILE = "slipstream.log"
);

`define SS_GPU `BLNS_INST.u_core.G_GPU.u_gpu
`define SS_DEC `SS_GPU.u_dec
`define SS_ARB `BLNS_INST.u_core.u_vram_arb
`define SS_RFR `BLNS_INST.u_core.u_regs.u_refresh

  // VRAM arbiter requester slots (belenos_core RQ_*)
  localparam  SS_RQ_WIN = 0;
  localparam  SS_RQ_BK  = 2;
  localparam  SS_RQ_WP  = 3;

  integer     ss_fd;

  // Cycle basis
  reg  [63:0] ss_cnt;
  // Traced once the reset has been applied
  reg         ss_on;
  initial ss_on = 1'b0;
  always @(negedge `BLNS_INST.hresetn_i) ss_on = 1'b1;

  always @(posedge `BLNS_TRACE_CLK or negedge `BLNS_INST.hresetn_i)
    if (!`BLNS_INST.hresetn_i) ss_cnt <= 64'd0;
    else                       ss_cnt <= ss_cnt + 64'd1;

  // (an external counter may not exist under NOTRACE, which writes no trace)
`ifdef NOTRACE
  wire [63:0] ss_cycle = ss_cnt;
`elsif BLNS_TRACE_CYCLE
  wire [63:0] ss_cycle = `BLNS_TRACE_CYCLE;
`else
  wire [63:0] ss_cycle = ss_cnt;
`endif

  initial begin
    ss_fd = 0;
`ifndef NOTRACE
    if (GPU_EN != 0) begin
      ss_fd = $fopen(LOGFILE, "w");
      $fdisplay(ss_fd, "# ###########################################################################");
      $fdisplay(ss_fd, "# Belenos GPU trace (slipstream)");
      $fdisplay(ss_fd, "# ###########################################################################");
      $fdisplay(ss_fd, "#");
      $fdisplay(ss_fd, "#   cycle  PSH  w=<n>  <word>  used=<FIFO words> | DROP full|GPU_EN=0");
      $fdisplay(ss_fd, "#                 w: number of the GPU_CMD write (accepted or dropped), from 0");
      $fdisplay(ss_fd, "#   cycle  CMD  <src>  w=<n>  q=<cycles>  <word> [<operand>]  <command>  <fields>");
      $fdisplay(ss_fd, "#                 src FIFO: w of the command word, q its cycles in the FIFO");
      $fdisplay(ss_fd, "#                 src L:<word address> (command list): w of the CALL");
      $fdisplay(ss_fd, "#   cycle  GO   #<id>  <kind>  <w>x<h>  setup=<cycles>");
      $fdisplay(ss_fd, "#   cycle  END  #<id>  <kind>  done|empty|abort|bound|drop  total=<cycles from the EXEC>");
      $fdisplay(ss_fd, "#                 draw=<engine cycles> px=<pixels walked> rd=<reads> wr=<writes>");
      $fdisplay(ss_fd, "#                 wait=<cycles refused> wbk=, wwin=<... the VRAM given to the refresh, the window>");
      $fdisplay(ss_fd, "#   cycle  BSY | IDL                  the GPU becomes busy / idle (GPU_STAT.BUSY)");
      $fdisplay(ss_fd, "#   cycle  WAI  start | end  frame|flush   WAIT_REFR_DONE holds the decoder (GPU_STAT.WAIT)");
      $fdisplay(ss_fd, "#   cycle  FRM  start n=<k> | done    a display refresh starts / ends");
      $fdisplay(ss_fd, "#   cycle  LST  end|flush  words=<consumed> rd=<list reads>");
      $fdisplay(ss_fd, "#   cycle  ERR  cause=<n> <name>  word=0x<the word in GPU_ERR>");
      $fdisplay(ss_fd, "#   cycle  CTL  CLEAR_ERR | ABORT | DISCARD | GPU_EN=0|1 | FLUSHED <n> words | FREEZE | RELEASE");
      $fdisplay(ss_fd, "#   cycle  CTL  MARK  used=<n> | MARK done   a DISCARD marker queued / reached by the decoder");
      $fdisplay(ss_fd, "#");
      $fdisplay(ss_fd, "#   swaps {X,Y,CL}; rop names S ~S ~D S&D S|D S^D ~(S&D) ~(S|D) ~(S^D) ~S&D S&~D ~S|D S|~D");
      $fdisplay(ss_fd, "#   ZERO ONES FILL; fixed point printed as <value>/<scale>");
      $fdisplay(ss_fd, "#");
    end
`endif
  end

  // Flush and close (called by the bench before $finish)
  task close;
    begin
      if (ss_fd != 0) begin
        $fflush(ss_fd);
        $fclose(ss_fd);
        ss_fd = 0;
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // Decoding
  //--------------------------------------------------------------------------
  // Eight hex digits as a string (formatted the same in every simulator)
  function [63:0] ss_hex8;
    input [31:0] v;
    integer i;
    reg [3:0] n;
    begin
      for (i = 0; i < 8; i = i + 1) begin
        n = v[4*i +: 4];
        ss_hex8[8*i +: 8] = (n < 4'd10) ? (8'h30 + n) : (8'h57 + n);
      end
    end
  endfunction

  task ss_rop;
    input [3:0] op;
    case (op)
      4'd0:  $fwrite(ss_fd, "S");
      4'd1:  $fwrite(ss_fd, "~S");
      4'd2:  $fwrite(ss_fd, "~D");
      4'd3:  $fwrite(ss_fd, "S&D");
      4'd4:  $fwrite(ss_fd, "S|D");
      4'd5:  $fwrite(ss_fd, "S^D");
      4'd6:  $fwrite(ss_fd, "~(S&D)");
      4'd7:  $fwrite(ss_fd, "~(S|D)");
      4'd8:  $fwrite(ss_fd, "~(S^D)");
      4'd9:  $fwrite(ss_fd, "~S&D");
      4'd10: $fwrite(ss_fd, "S&~D");
      4'd11: $fwrite(ss_fd, "~S|D");
      4'd12: $fwrite(ss_fd, "S|~D");
      4'd13: $fwrite(ss_fd, "ZERO");
      4'd14: $fwrite(ss_fd, "ONES");
      default: $fwrite(ss_fd, "FILL");
    endcase
  endtask

  // Primitive kind of an EXEC word (fixed width)
  task ss_kind;
    input [31:0] w;
    case (w[31:28])
      4'h8:    if (w[7]) $fwrite(ss_fd, "TRI    "); else if (w[24]) $fwrite(ss_fd, "LINE   "); else $fwrite(ss_fd, "FILL   ");
      4'h9:    $fwrite(ss_fd, "COPY   ");
      4'hA:    $fwrite(ss_fd, "COPYT  ");
      4'hB:    $fwrite(ss_fd, "SPAN   ");
      4'hC:    $fwrite(ss_fd, "EXPAND ");
      4'hD:    $fwrite(ss_fd, "TEXSPAN");
      4'hE:    if (w[7]) $fwrite(ss_fd, "TEXTRI "); else $fwrite(ss_fd, "TEXRECT");
      default: $fwrite(ss_fd, "?      ");
    endcase
  endtask

  // Command name and fields; id: the primitive id of an EXEC
  task ss_cmd;
    input [31:0] w;
    input [31:0] op;
    input [31:0] id;
    begin
      case (w[31:28])
        4'h1: begin
                $fwrite(ss_fd, "SET_SRC       pitch=%0d fmt=%0d", w[15:0], w[19:16]);
                if (w[20]) $fwrite(ss_fd, " IMM");
                $fwrite(ss_fd, " base=0x%h", op[23:0]);
              end
        4'h2: begin
                $fwrite(ss_fd, "SET_DST       pitch=%0d", w[15:0]);
                if (w[16]) $fwrite(ss_fd, " XY fmt=%0d origin=0x%h", w[19:17], op[23:0]);
                else       $fwrite(ss_fd, " fmt=%0d base=0x%h", w[19:17], op[23:0]);
              end
        4'h3: $fwrite(ss_fd, "SET_SIZE      w=%0d h=%0d", w[13:0], w[27:14]);
        4'h4: $fwrite(ss_fd, "SET_FILL      c=0x%h", op[15:0]);
        4'h5: $fwrite(ss_fd, "SET_TRANSP    c=0x%h", op[15:0]);
        4'h6:
          case (w[27:24])
            4'd0:  begin
                     $fwrite(ss_fd, "SET_TEX       log2w=%0d log2h=%0d transp=%0d dsw=%b free_pitch=%0d bound=%0d shade=%0d",
                             w[3:0], w[7:4], w[8], w[11:9], w[12], w[13], w[23:16]);
                     if (w[15:14] != 2'd0) $fwrite(ss_fd, " remap=%0d", w[15:14]);
                   end
            4'd1:  $fwrite(ss_fd, "SET_UV        u=%0d/64 v=%0d/64", op[31:16], op[15:0]);
            4'd2:  $fwrite(ss_fd, "SET_STEP      du=%0d/2048 dv=%0d/2048", $signed(op[31:16]), $signed(op[15:0]));
            4'd3:  $fwrite(ss_fd, "SET_XY        x=%0d y=%0d", $signed(w[11:0]), $signed(w[23:12]));
            4'd4:  $fwrite(ss_fd, "SET_CLIP      x0=%0d y0=%0d x1=%0d y1=%0d",
                           $signed(w[11:0]), $signed(w[23:12]), $signed(op[11:0]), $signed(op[23:12]));
            4'd5:  $fwrite(ss_fd, "SET_STEP_ROW  du=%0d/2048 dv=%0d/2048", $signed(op[31:16]), $signed(op[15:0]));
            4'd6:  $fwrite(ss_fd, "SET_TEXBOX    tw=%0d th=%0d", w[11:0], w[23:12]);
            4'd7:  begin
                     $fwrite(ss_fd, "SET_GRAD      en=%0d n=%0d axis=%0d step=%0d", w[17], w[11:0], w[12], $signed(w[16:13]));
                     if (w[18]) $fwrite(ss_fd, " RGB");
                   end
            4'd8:  $fwrite(ss_fd, "SET_ALPHA     en=%0d a=%0d", w[8], w[7:0]);
            4'd9:  $fwrite(ss_fd, "SET_V0        x=%0d/16 y=%0d/16", $signed(op[15:0]), $signed(op[31:16]));
            4'd10: $fwrite(ss_fd, "SET_V1        x=%0d/16 y=%0d/16", $signed(op[15:0]), $signed(op[31:16]));
            4'd11: $fwrite(ss_fd, "SET_V2        x=%0d/16 y=%0d/16", $signed(op[15:0]), $signed(op[31:16]));
            4'd12: $fwrite(ss_fd, "SET_GRAD_RGB  dr=%0d/64 dg=%0d/64 db=%0d/64",
                           $signed(op[29:20]), $signed(op[19:10]), $signed(op[9:0]));
            4'd13:
              case (w[23:20])
                4'd0:    $fwrite(ss_fd, "SET_AUX       REMAP_TABLE addr=0x%h", op);
                4'd1:    $fwrite(ss_fd, "SET_AUX       MASK_PLANE inv=%0d pitch=%0d addr=0x%h", w[16], w[15:0], op);
                default: $fwrite(ss_fd, "SET_AUX       sel=%0d", w[23:20]);
              endcase
            4'd15: begin
                     $fwrite(ss_fd, "SET_EXT2      ");
                     case (w[23:16])
                       8'h01:   $fwrite(ss_fd, "WAIT_REFR_DONE ");
                       8'h02:   $fwrite(ss_fd, "RESET_STATE ");
                       default: ;
                     endcase
                     $fwrite(ss_fd, "code=0x%h imm=0x%h", w[23:16], w[15:0]);
                   end
            default: $fwrite(ss_fd, "SET_EXT       sub=%0d", w[27:24]);
          endcase
        4'h7: $fwrite(ss_fd, "CALL          n=%0d addr=0x%h", w[23:0], op[23:0]);
        4'h8: begin
                $fwrite(ss_fd, "EXEC_FILL     #%0d rop=", id); ss_rop(w[3:0]);
                $fwrite(ss_fd, " dsw=%b", w[6:4]);
                if (w[7]) $fwrite(ss_fd, " TRI");
                if (w[13:12] != 2'd0) $fwrite(ss_fd, " remap=%0d", w[13:12]);
              end
        4'h9: begin
                $fwrite(ss_fd, "EXEC_COPY     #%0d rop=", id); ss_rop(w[3:0]);
                $fwrite(ss_fd, " dsw=%b ssw=%b", w[6:4], w[10:8]);
                if (w[11]) $fwrite(ss_fd, " MPLANE");
                if (w[13:12] != 2'd0) $fwrite(ss_fd, " remap=%0d", w[13:12]);
              end
        4'hA: begin
                $fwrite(ss_fd, "EXEC_COPYT    #%0d rop=", id); ss_rop(w[3:0]);
                $fwrite(ss_fd, " dsw=%b ssw=%b", w[6:4], w[10:8]);
                if (w[11]) $fwrite(ss_fd, " MPLANE");
                if (w[13:12] != 2'd0) $fwrite(ss_fd, " remap=%0d", w[13:12]);
              end
        4'hB: $fwrite(ss_fd, "EXEC_SPAN     #%0d w=%0d delta=%0d", id, w[13:0], $signed(w[27:14]));
        4'hC: begin
                $fwrite(ss_fd, "EXEC_EXPAND   #%0d", id);
                if (w[2]) $fwrite(ss_fd, " OPAQUE");
                if (w[3]) $fwrite(ss_fd, " MASK");
                $fwrite(ss_fd, " dsw=%b delta=%0d", w[6:4], $signed(w[27:14]));
                if (w[13:12] != 2'd0) $fwrite(ss_fd, " remap=%0d", w[13:12]);
              end
        4'hD: $fwrite(ss_fd, "EXEC_TEXSPAN  #%0d n=%0d delta=%0d", id, w[13:0], $signed(w[27:14]));
        4'hE: begin
                $fwrite(ss_fd, "EXEC_TEXRECT  #%0d delta=%0d", id, $signed(w[27:14]));
                if (w[7]) $fwrite(ss_fd, " TRI");
              end
        4'hF: begin
                $fwrite(ss_fd, "FENCE         tag=0x%h", w[23:0]);
                if (w[24]) $fwrite(ss_fd, " IRQ");
                if (w[25]) $fwrite(ss_fd, " AUTO");
              end
        default: $fwrite(ss_fd, "INVALID");
      endcase
    end
  endtask


  task ss_err_name;
    input [2:0] c;
    case (c)
      3'd1: $fwrite(ss_fd, "invalid");
      3'd2: $fwrite(ss_fd, "absent");
      3'd3: $fwrite(ss_fd, "format");
      3'd4: $fwrite(ss_fd, "list_cut");
      3'd5: $fwrite(ss_fd, "rect_past_vram");
      3'd6: $fwrite(ss_fd, "call_past_vram");
      default: $fwrite(ss_fd, "?");
    endcase
  endtask

  //--------------------------------------------------------------------------
  // Tracer
  //--------------------------------------------------------------------------
  generate
    if (GPU_EN != 0) begin : G_SS

      localparam [3:0] TGT_SKIP = 4'd12;

      // Command with its operand pending
      reg         op_v;
      reg  [31:0] op_word;
      reg         op_lst;
      reg  [31:0] op_ptr;

      // Primitives: one in the set-up, one in the engine
      reg  [31:0] next_id;
      reg         s_v;
      reg  [31:0] s_id, s_word;
      reg  [63:0] s_t0;
      reg         e_v;
      reg  [31:0] e_id, e_word;
      reg  [63:0] e_t0, e_tgo;
      reg  [31:0] e_px, e_rd, e_wr, e_wait, e_wbk, e_wwin;
      reg  [31:0] e_w, e_h;
      reg         e_cut;
      reg  [8*5-1:0] e_how;

      // Command list
      reg         l_v;
      reg  [31:0] l_words, l_rd;

      reg         gpu_en_q, freeze_q, flush_q;

      reg  [31:0] d_head, d_ptr, id_now, d_wdata;
      reg         d_lst;

      // Words written to GPU_CMD: w = their number (accepted or dropped);
      // the FIFO holds the numbers and push cycles of the words it keeps
      localparam integer PQ_N = 1024;
      reg  [31:0] w_cnt;
      reg  [31:0] pq_w [0:PQ_N-1];
      reg  [63:0] pq_c [0:PQ_N-1];
      integer     pq_hd, pq_tl;
      reg  [31:0] d_w, op_w, call_w;
      reg  [63:0] d_pc, op_pc;
      reg         busy_q;
      reg         wait_q;
      reg  [31:0] frm_n;

      // Word source: FIFO (w: its number, q: cycles in the FIFO), or the list
      // word address (w: the CALL's number)
      task ss_src;
        input        lst;
        input [31:0] ptr;
        input [31:0] w;
        input [63:0] pc;
        if (lst) $fwrite(ss_fd, "L:0x%h  w=%-7d q=-      ", ptr[23:0], call_w);
        else     $fwrite(ss_fd, "FIFO        w=%-7d q=%-6d ", w, ss_cycle - pc);
      endtask

      initial begin
        op_v = 1'b0; s_v = 1'b0; e_v = 1'b0; e_cut = 1'b0; l_v = 1'b0; next_id = 0;
        w_cnt = 0; pq_hd = 0; pq_tl = 0; call_w = 0; busy_q = 1'b0; wait_q = 1'b0; frm_n = 0;
        gpu_en_q = 1'b0; freeze_q = 1'b0; flush_q = 1'b0;
      end

      task ss_end;
        input [31:0] id;
        input [31:0] word;
        input [63:0] t0;
        input [63:0] tgo;
        input        drew;
        input [8*5-1:0] how;
        begin
          if (ss_fd != 0) begin
            $fwrite(ss_fd, "%12d  END  #%-6d ", ss_cycle, id);
            ss_kind(word);
            $fwrite(ss_fd, "  %0s  total=%0d", how, ss_cycle - t0);
            if (drew)
              $fwrite(ss_fd, " draw=%0d px=%0d rd=%0d wr=%0d wait=%0d wbk=%0d wwin=%0d",
                      ss_cycle - tgo, e_px, e_rd, e_wr, e_wait, e_wbk, e_wwin);
            $fwrite(ss_fd, "\n");
          end
        end
      endtask

      always @(posedge `SS_GPU.hclk_i) if (ss_on && (`BLNS_INST.hresetn_i === 1'b1)) begin
        d_head = `SS_DEC.head;
        d_lst  = `SS_DEC.list_active_i;
        d_ptr  = 32'd0;
        d_ptr[0 +: 24] = `SS_GPU.list_ptr;

        // Command list: starts, ends (a flush the cycle before: cut)
        if (l_v && (`SS_GPU.list_active !== 1'b1)) begin
          if (ss_fd != 0)
            $fwrite(ss_fd, "%12d  LST  %0s  words=%0d rd=%0d\n", ss_cycle,
                    flush_q ? "flush" : "end  ", l_words, l_rd);
          l_v = 1'b0;
        end
        if ((`SS_GPU.list_active === 1'b1) && !l_v) begin
          l_v = 1'b1; l_words = 0; l_rd = 0;
        end

        // Engine counters (the cycle's accesses belong to the primitive drawing)
        if (e_v) begin
          if (`SS_GPU.dma_vgnt === 1'b1) begin
            if (`SS_GPU.dma_vwe === 1'b1) e_wr = e_wr + 1;
            else                          e_rd = e_rd + 1;
          end
          if ((`SS_GPU.dma_vreq === 1'b1) && (`SS_GPU.dma_vgnt !== 1'b1)) begin
            e_wait = e_wait + 1;
            if (`SS_ARB.gnt_o[SS_RQ_BK] === 1'b1)                                          e_wbk   = e_wbk + 1;
            if ((`SS_ARB.gnt_o[SS_RQ_WIN] === 1'b1) || (`SS_ARB.gnt_o[SS_RQ_WP] === 1'b1)) e_wwin  = e_wwin + 1;
          end
          if (`SS_GPU.u_px.u_px_a.a_emit === 1'b1) e_px = e_px + `SS_GPU.u_px.u_px_a.a_n;
        end
        if (l_v && (`SS_GPU.list_vgnt === 1'b1)) l_rd = l_rd + 1;

        // Control
        if (ss_fd != 0) begin
          if (`SS_GPU.gpu_en_i !== gpu_en_q)
            $fwrite(ss_fd, "%12d  CTL  GPU_EN=%0d\n", ss_cycle, `SS_GPU.gpu_en_i);
          if (`SS_GPU.clear_err === 1'b1) $fwrite(ss_fd, "%12d  CTL  CLEAR_ERR\n", ss_cycle);
          if (`SS_GPU.abort === 1'b1)     $fwrite(ss_fd, "%12d  CTL  ABORT\n", ss_cycle);
          if (`SS_GPU.discard === 1'b1)   $fwrite(ss_fd, "%12d  CTL  DISCARD\n", ss_cycle);
          if (`SS_GPU.busy_o !== busy_q)
            $fwrite(ss_fd, "%12d  %0s\n", ss_cycle, (`SS_GPU.busy_o === 1'b1) ? "BSY" : "IDL");
          if ((`SS_DEC.refr_wait_o === 1'b1) && !wait_q)
            $fwrite(ss_fd, "%12d  WAI  start\n", ss_cycle);
          if ((`SS_DEC.refr_wait_o !== 1'b1) && wait_q)
            $fwrite(ss_fd, "%12d  WAI  end  %0s\n", ss_cycle, (`SS_DEC.refr_seen === 1'b1) ? "frame" : "flush");
          if (`SS_RFR.refr_start_evt_o === 1'b1) begin
            $fwrite(ss_fd, "%12d  FRM  start  n=%0d\n", ss_cycle, frm_n);
            frm_n = frm_n + 1;
          end
          if (`SS_RFR.refr_done_evt_o === 1'b1)
            $fwrite(ss_fd, "%12d  FRM  done\n", ss_cycle);
          if (`SS_GPU.freeze_i !== freeze_q)
            if (`SS_GPU.freeze_i === 1'b1) $fwrite(ss_fd, "%12d  CTL  FREEZE\n", ss_cycle);
            else                           $fwrite(ss_fd, "%12d  CTL  RELEASE\n", ss_cycle);
        end
        busy_q   = (`SS_GPU.busy_o === 1'b1);
        wait_q   = (`SS_DEC.refr_wait_o === 1'b1);
        gpu_en_q = `SS_GPU.gpu_en_i;
        freeze_q = `SS_GPU.freeze_i;

        // Primitive in the engine: done; abandoned, closed once the engine has
        // written its buffer
        if (e_v && e_cut) begin
          if (`SS_GPU.px_busy !== 1'b1) begin
            ss_end(e_id, e_word, e_t0, e_tgo, 1'b1, e_how); e_v = 1'b0;
          end
        end else if (e_v) begin
          if (`SS_GPU.dma_done === 1'b1) begin
            ss_end(e_id, e_word, e_t0, e_tgo, 1'b1, "done "); e_v = 1'b0;
          end else if (`SS_GPU.bound_err === 1'b1) begin
            e_cut = 1'b1; e_how = "bound";
          end else if (`SS_GPU.px_abort === 1'b1) begin          // (a DISCARD marker's too)
            e_cut = 1'b1; e_how = "abort";
          end
        end

        // Primitive in the set-up: to the engine, nothing to draw, dropped
        if (s_v) begin
          if (`SS_GPU.setup_go === 1'b1) begin
            if (e_v) begin
              ss_end(e_id, e_word, e_t0, e_tgo, 1'b1, e_cut ? e_how : "lost "); e_v = 1'b0;
            end
            e_v = 1'b1; e_cut = 1'b0; e_id = s_id; e_word = s_word; e_t0 = s_t0; e_tgo = ss_cycle;
            e_px = 0; e_rd = 0; e_wr = 0; e_wait = 0; e_wbk = 0; e_wwin = 0;
            e_w = `SS_GPU.su_w; e_h = `SS_GPU.su_h;
            s_v = 1'b0;
            if (ss_fd != 0) begin
              $fwrite(ss_fd, "%12d  GO   #%-6d ", ss_cycle, e_id);
              ss_kind(e_word);
              $fwrite(ss_fd, "  %0dx%0d  setup=%0d\n", e_w, e_h, ss_cycle - e_t0);
            end
          end else if (`SS_GPU.setup_empty === 1'b1) begin
            ss_end(s_id, s_word, s_t0, s_t0, 1'b0, "empty"); s_v = 1'b0;
          end else if (`SS_GPU.setup_abort === 1'b1) begin
            ss_end(s_id, s_word, s_t0, s_t0, 1'b0, "drop "); s_v = 1'b0;
          end
        end

        // The FIFO word at the head: its number and push cycle
        d_w = 32'd0; d_pc = 64'd0;
        if ((`SS_DEC.pop_o === 1'b1) && (pq_hd != pq_tl)) begin
          d_w  = pq_w[pq_hd % PQ_N];
          d_pc = pq_c[pq_hd % PQ_N];
          pq_hd = pq_hd + 1;
        end

        // Decoder: a primitive enters the set-up
        id_now = next_id;
        if (`SS_DEC.exec_start_o === 1'b1) begin
          if (s_v) ss_end(s_id, s_word, s_t0, s_t0, 1'b0, "lost ");
          // a two-word EXEC (LINE) starts at its operand: its command word is op_word
          s_v = 1'b1; s_id = next_id; s_word = op_v ? op_word : d_head; s_t0 = ss_cycle;
          next_id = next_id + 1;
        end

        // Decoder: words
        if (`SS_DEC.cmd_pop === 1'b1) begin
          if (`SS_DEC.has_opnd === 1'b1) begin
            op_v = 1'b1; op_word = d_head; op_lst = d_lst; op_ptr = d_ptr; op_w = d_w; op_pc = d_pc;
          end else if (ss_fd != 0) begin
            $fwrite(ss_fd, "%12d  CMD  ", ss_cycle);
            ss_src(d_lst, d_ptr, d_w, d_pc);
            $fwrite(ss_fd, "%h            ", d_head);
            ss_cmd(d_head, 32'd0, id_now);
            $fwrite(ss_fd, "\n");
          end
          if (d_lst) l_words = l_words + 1;
        end
        if (`SS_DEC.opnd_pop === 1'b1) begin
          if (ss_fd != 0) begin
            if (`SS_DEC.tgt == TGT_SKIP) begin
              $fwrite(ss_fd, "%12d  CMD  ", ss_cycle);
              ss_src(d_lst, d_ptr, d_w, d_pc);
              $fwrite(ss_fd, "%h            (operand of a flushed command: discarded)\n", d_head);
            end else begin
              $fwrite(ss_fd, "%12d  CMD  ", ss_cycle);
              ss_src(op_lst, op_ptr, op_w, op_pc);
              $fwrite(ss_fd, "%h %h   ", op_word, d_head);
              ss_cmd(op_word, d_head, id_now);
              $fwrite(ss_fd, "\n");
            end
          end
          if ((`SS_DEC.tgt != TGT_SKIP) && (op_word[31:28] == 4'h7)) call_w = op_w;
          op_v = 1'b0;
          if (d_lst) l_words = l_words + 1;
        end
        // A DISCARD marker reached
        if ((`SS_DEC.mrk_pop === 1'b1) && (ss_fd != 0))
          $fwrite(ss_fd, "%12d  CTL  MARK done\n", ss_cycle);
        // A command whose operand never came
        if (op_v && ((`SS_DEC.flush_go === 1'b1) || (`SS_GPU.gpu_en_i !== 1'b1) || (`SS_DEC.err_go === 1'b1) ||
                     (`SS_DEC.mrk_pop === 1'b1))) begin
          if (ss_fd != 0) begin
            $fwrite(ss_fd, "%12d  CMD  ", ss_cycle);
            ss_src(op_lst, op_ptr, op_w, op_pc);
            $fwrite(ss_fd, "%h            ", op_word);
            ss_cmd(op_word, 32'd0, id_now);
            $fwrite(ss_fd, "  (cut: no operand)\n");
          end
          op_v = 1'b0;
        end

        // Errors
        if ((`SS_GPU.err_evt_o === 1'b1) && (ss_fd != 0)) begin
          $fwrite(ss_fd, "%12d  ERR  cause=%0d ", ss_cycle, `SS_DEC.cause_nxt);
          ss_err_name(`SS_DEC.cause_nxt);
          $fwrite(ss_fd, "  word=0x%h\n",
                  (`SS_DEC.bound_evt === 1'b1) ? `SS_DEC.bound_word_i : d_head);
        end

        // Words written to GPU_CMD
        if (`SS_GPU.cmd_wr === 1'b1) begin
          d_wdata = `SS_GPU.rb_wdata_i;
          if (`SS_GPU.push === 1'b1) begin
            pq_w[pq_tl % PQ_N] = w_cnt;
            pq_c[pq_tl % PQ_N] = ss_cycle;
            pq_tl = pq_tl + 1;
            if (ss_fd != 0) begin
              $fwrite(ss_fd, "%12d  PSH  w=%-7d ", ss_cycle, w_cnt);
              $fwrite(ss_fd, "%s  used=%0d\n", ss_hex8(d_wdata), pq_tl - pq_hd);
            end
          end else if (ss_fd != 0) begin
            $fwrite(ss_fd, "%12d  PSH  w=%-7d ", ss_cycle, w_cnt);
            if (`SS_GPU.gpu_en_i === 1'b1) $fwrite(ss_fd, "%s  DROP full\n", ss_hex8(d_wdata));
            else                           $fwrite(ss_fd, "%s  DROP GPU_EN=0\n", ss_hex8(d_wdata));
          end
          w_cnt = w_cnt + 1;
        end
        // A DISCARD marker enters the FIFO (in the write's cycle, or pending
        // until there is room): a FIFO word of its own
        if (`SS_GPU.mrk_ins === 1'b1) begin
          pq_w[pq_tl % PQ_N] = 32'hFFFF_FFFF;
          pq_c[pq_tl % PQ_N] = ss_cycle;
          pq_tl = pq_tl + 1;
          if (ss_fd != 0) $fwrite(ss_fd, "%12d  CTL  MARK  used=%0d\n", ss_cycle, pq_tl - pq_hd);
        end
        // A flush empties the FIFO
        if (`SS_GPU.flush === 1'b1) begin
          if ((pq_tl != pq_hd) && (ss_fd != 0))
            $fwrite(ss_fd, "%12d  CTL  FLUSHED %0d words  w=%0d..%0d\n", ss_cycle, pq_tl - pq_hd,
                    pq_w[pq_hd % PQ_N], pq_w[(pq_tl - 1) % PQ_N]);
          pq_hd = pq_tl;
        end

        flush_q = (`SS_GPU.flush === 1'b1);
      end

    end
  endgenerate

`undef SS_RFR
`undef SS_ARB
`undef SS_DEC
`undef SS_GPU

endmodule

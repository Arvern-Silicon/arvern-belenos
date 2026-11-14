//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    gpu_inv_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_inv_check.v
// Module Description : Always-on GPU invariant monitors (`included into
//                      tb_belenos, GPU builds). The GPU keeps no copy, no
//                      bit or no state that these invariants make redundant;
//                      each is checked on every GPU clock edge out of reset
//                      (model_on), whatever test runs:
//                        - the decoder's EXEC fields the set-up reads (start
//                          addresses, (u, v), size, gradient) do not change
//                          from S_LAT while the set-up is busy, nor (without
//                          run-ahead) while the engine draws: the set-up's
//                          start values are those fields without x/y;
//                        - the engine's fill colour does not change while it
//                          is busy (not carried with the tokens without
//                          gradient and lines);
//                        - the set-up never enters a state of a feature not
//                          built (those decodes are tied to 0);
//                        - set-up value ranges where they are read: a
//                          non-empty box's walk offsets fit OFF_W bits
//                          (unsigned, a triangle's signed), its first pixel
//                          the 12-bit clip window; S_BOX with x/y is a box;
//                          the shared multiplier's operands fit MA_W / MB_W
//                          bits signed; the gradient remainder is below N
//                          (own divider);
//                        - the pixel engine: a one-pixel source token's
//                          rotation is a multiple of the source pixel size, a
//                          destination pixel's bit offset (DST remap) of the
//                          pixel size, a word the cache loads is below
//                          2^VRAM_AW;
//                        - the list's request equals the one of a words-to-
//                          read counter (start N, -1 per grant, 0 at a
//                          flush), the decoder's destination pitch the one of
//                          a SET_DST pitch register;
//                        - the GPU_FIFO_LOW event equals a reference: FREE
//                          (the FIFO count, 0 with a pending DISCARD marker)
//                          rising above THRESH (the GPU_FIFO_LOW writes,
//                          saturated at the depth; a write re-arms);
//                        - a pending DISCARD marker reads FREE 0 and FULL,
//                          and no push enters the FIFO meanwhile;
//                        - a bound error raised by an F read (source, mask,
//                          A8, bilinear tap) or by the immediate index
//                          abandons no older pixel: W
//                          holds none it does not take that cycle, L none;
//                        - the pixel engine's colour depth register is
//                          one-hot, and a line is never a texture (the
//                          decoder's LINE and kind[2], and what the engine
//                          reads: ln_i, kind_i[2]); the bilinear tap alpha
//                          (blns_gpu_px_fw f_tal, the key applied after the
//                          multiply) relies on both, and the Formality run
//                          of the bilinear builds assumes them.
//                      A violation prints an ERROR line (the first GIC_SHOW
//                      of each check) and counts in the bench's error count.
//                      gpu_inv_check_report prints the counts.
//----------------------------------------------------------------------------

localparam GIC_SHOW = 5;                 // ERROR lines printed per check
localparam GIC_N    = 17;                // checks

integer gic_viol [0:GIC_N-1];
integer gic_k;
initial for (gic_k = 0; gic_k < GIC_N; gic_k = gic_k + 1) gic_viol[gic_k] = 0;

task gic_fail;
   input integer    kind;
   input [72*8-1:0] what;
   begin
      error           = error + 1;
      gic_viol[kind]  = gic_viol[kind] + 1;
      if (gic_viol[kind] <= GIC_SHOW)
        $display("ERROR: gpu invariant -- %0s %t", what, $time);
   end
endtask

task gpu_inv_check_report;
   integer n;
   begin
      n = 0;
      for (gic_k = 0; gic_k < GIC_N; gic_k = gic_k + 1) n = n + gic_viol[gic_k];
      $display("GPU INVARIANTS: %0d violations", n);
   end
endtask

`define GIC_GPU dut.u_core.G_GPU.u_gpu
`define GIC_SU  `GIC_GPU.u_setup
`define GIC_FW  `GIC_GPU.u_px.u_px_fw
`define GIC_DEC `GIC_GPU.u_dec
`define GIC_LST `GIC_GPU.u_list
`define GIC_PA  `GIC_GPU.u_px.u_px_a

localparam GIC_XY   = (GPU_XY_EN != 0);
localparam GIC_TRI  = (GPU_TRI_EN != 0) && GIC_XY;
localparam GIC_LINE = (GPU_LINE_EN != 0) && GIC_XY;
localparam GIC_GRAD = (GPU_GRAD_EN != 0);
localparam GIC_AA   = GIC_LINE && (GPU_BLEND_EN != 0);
localparam GIC_OFFW = GIC_TRI ? 17 : DIM_W;
localparam GIC_MAW  = (GIC_TRI || GIC_AA) ? 18 : ((DIM_W + 1 > 13) ? (DIM_W + 1) : 13);
localparam GIC_MBW  = GIC_TRI ? 18 : 17;
localparam GIC_PAW  = VRAM_AW + 5;
localparam GIC_FW_W = 2*GIC_PAW + 82 + 2*DIM_W;  // the set-up's decoder fields below

// An n-bit signed value in 18 bits: bits 17 to n - 1 equal
function gic_fits18;
   input [17:0] v;
   input integer n;
   reg   [17:0] hi;
   begin
      hi         = v >> (n - 1);
      gic_fits18 = (hi == 18'd0) || (hi == (18'h3FFFF >> (n - 1)));
   end
endfunction

generate
   if (GPU_EN != 0) begin : G_GIC
      wire                gic_clk  = `GIC_GPU.hclk_i;

      // Decoder fields stable from S_LAT: while the set-up is busy, and
      // without run-ahead while the engine draws
      wire [GIC_FW_W-1:0] su_f     = {`GIC_SU.dst_base_i, `GIC_SU.src_base_i, `GIC_SU.imm_i, `GIC_SU.tex_uv_i,
                                      `GIC_SU.width_i, `GIC_SU.height_i, `GIC_SU.grad_i};
      wire                su_win   = (`GIC_SU.st_idle !== 1'b1) |
                                     ((GPU_RUNAHEAD_EN == 0) & (`GIC_FW.a_idle !== 1'b1));
      reg  [GIC_FW_W-1:0] su_f_q;
      reg                 su_win_q;
      // The engine's fill colour while it is busy
      wire         [15:0] px_fill  = `GIC_GPU.u_px.fill_i;
      wire                px_busy  = (`GIC_FW.a_idle === 1'b0);
      reg          [15:0] px_fill_q;
      reg                 px_busy_q;
      // The words-to-read counter of the list, the SET_DST pitch register
      integer             lst_left;
      reg          [15:0] dec_pitch;
      wire          [4:0] su_st    = `GIC_SU.state;
      reg           [4:0] bpp_m;
      reg           [4:0] sbpp_m;
      // GPU_FIFO_LOW: the reference THRESH and "above"; FREE as GPU_STAT reads it
      integer             thr_ref;
      reg                 above_ref;
      wire                mrk_pend = (`GIC_GPU.mrk_pend === 1'b1);
      integer             free_ref;
      always @(*) free_ref = mrk_pend ? 0 : (GPU_FIFO_DEPTH - `GIC_GPU.fifo_count);
      wire         [31:0] thr_wd   = `GIC_GPU.rb_wdata_i & 32'h1FFFF;
      initial begin su_win_q = 1'b0; px_busy_q = 1'b0; lst_left = 0; dec_pitch = 16'h0000; end
      initial begin thr_ref = GPU_FIFO_DEPTH / 2; above_ref = 1'b1; end

      always @(*) begin
         bpp_m  = `GIC_FW.bpp[4] ? 5'd15 : `GIC_FW.bpp[3] ? 5'd7 : `GIC_FW.bpp[2] ? 5'd3 : `GIC_FW.bpp[1] ? 5'd1 : 5'd0;
         sbpp_m = `GIC_FW.src_bpp[4] ? 5'd15 : `GIC_FW.src_bpp[3] ? 5'd7 : `GIC_FW.src_bpp[2] ? 5'd3 :
                  `GIC_FW.src_bpp[1] ? 5'd1 : 5'd0;
      end

      always @(posedge gic_clk) begin
         if (model_on) begin
            // (0) set-up fields
            if (su_win_q && su_win && (su_f !== su_f_q))
              gic_fail(0, "a decoder field read by the set-up changed from S_LAT");
            // (1) fill colour
            if (px_busy_q && px_busy && (px_fill !== px_fill_q))
              gic_fail(1, "the engine's fill colour changed while it is busy");
            // (2) set-up states of features not built
            if ((!GIC_XY && ((su_st == 5'd2) || (su_st == 5'd3) || (su_st == 5'd4) || (su_st == 5'd5) ||
                             (su_st == 5'd6) || (su_st == 5'd11) || (su_st == 5'd13))) ||
                (!(GIC_XY && GIC_GRAD) && ((su_st == 5'd7) || (su_st == 5'd8) || (su_st == 5'd14) || (su_st == 5'd15))) ||
                (!GIC_TRI && (su_st == 5'd12)) ||
                (!GIC_LINE && ((su_st == 5'd16) || (su_st == 5'd19) || (su_st == 5'd20))) ||
                (!GIC_AA && ((su_st == 5'd17) || (su_st == 5'd18))))
              gic_fail(2, "the set-up entered a state of a feature not built");
            // (3) walk offsets of a box that is not empty (a rectangle's, a
            // textured triangle's), x axis (S_LAT) and both as registered
            if ((`GIC_SU.st_lat === 1'b1) && (`GIC_SU.box_on === 1'b1) && (`GIC_SU.a_empty === 1'b0) &&
                ((`GIC_SU.trim_on === 1'b1) || (`GIC_SU.tex_tri === 1'b1)) &&
                (GIC_TRI ? !gic_fits18(`GIC_SU.a_off, GIC_OFFW) : ((`GIC_SU.a_off >> GIC_OFFW) != 18'd0)))
              gic_fail(3, "a non-empty box's x walk offset does not fit OFF_W bits");
            if ((`GIC_SU.box_lat === 1'b1) && (`GIC_SU.box_on === 1'b1) && (`GIC_SU.empty === 1'b0) &&
                (GIC_TRI ? (!gic_fits18(`GIC_SU.col_off, GIC_OFFW) || !gic_fits18(`GIC_SU.row_off, GIC_OFFW)) :
                           (((`GIC_SU.col_off >> GIC_OFFW) != 18'd0) || ((`GIC_SU.row_off >> GIC_OFFW) != 18'd0))))
              gic_fail(3, "a non-empty box's walk offsets do not fit OFF_W bits");
            // (4) first pixel of a box that is not empty: in the clip window
            if ((((`GIC_SU.st_lat === 1'b1) && (`GIC_SU.a_empty === 1'b0)) ||
                 ((`GIC_SU.box_lat === 1'b1) && (`GIC_SU.empty === 1'b0))) && (`GIC_SU.box_on === 1'b1) &&
                !gic_fits18(`GIC_SU.a_f, 12))
              gic_fail(4, "a non-empty box's first pixel is outside 12 bits signed");
            if ((`GIC_SU.st_box === 1'b1) && (`GIC_SU.xy_on === 1'b1) && (`GIC_SU.box_on !== 1'b1))
              gic_fail(4, "S_BOX in x/y mode without a box");
            // (5) multiplier operands
            if (!gic_fits18(`GIC_SU.mul_a, GIC_MAW) || !gic_fits18(`GIC_SU.mul_b, GIC_MBW))
              gic_fail(5, "a shared multiplier operand does not fit MA_W / MB_W bits");
            // (6) gradient remainder below N
            if (!GIC_TRI && (`GIC_SU.st_gv === 1'b1) && (`GIC_SU.d_rem >= {6'h00, `GIC_SU.grad_n}))
              gic_fail(6, "the gradient remainder is not below N");
            // (7) one-pixel source token: rotation a multiple of the pixel size
            if ((`GIC_FW.f_take === 1'b1) && (`GIC_FW.t1_word === 1'b0) && (`GIC_FW.t1_sneed === 1'b1) &&
                ((`GIC_FW.t1_rot & sbpp_m) != 5'd0))
              gic_fail(7, "a one-pixel token's source rotation is not pixel-aligned");
            // (8) DST remap: the destination pixel's offset is pixel-aligned
            if ((`GIC_FW.r_dcap === 1'b1) && ((`GIC_FW.t2_dboff & bpp_m) != 5'd0))
              gic_fail(8, "a DST remap pixel's bit offset is not pixel-aligned");
            // (9) the cache's word below 2^VRAM_AW
            if (((`GIC_FW.f_rd_gnt === 1'b1) || (`GIC_FW.c_promo === 1'b1) || (`GIC_FW.i_ld === 1'b1)) &&
                (`GIC_FW.c_wa_d[VRAM_AW] !== 1'b0))
              gic_fail(9, "the cache loads a word at or past 2^VRAM_AW");
            // (10) list request: words to read = start N, -1 per grant
            if (`GIC_LST.vreq_o !== (((lst_left != 0) && (`GIC_LST.room === 1'b1) && (`GIC_LST.rd_free === 1'b1) &&
                                     (`GIC_LST.freeze_i === 1'b0)) ? 1'b1 : 1'b0))
              gic_fail(10, "the list's request differs from its words-to-read count");
            // (11) destination pitch: the SET_DST pitch in address mode
            if (`GIC_DEC.dst_pitch_o !== ((`GIC_DEC.xy_mode === 1'b1) ? `GIC_DEC.xy_pitch_q : dec_pitch))
              gic_fail(11, "the decoder's destination pitch differs from the SET_DST pitch");
            // (12) GPU_FIFO_LOW: FREE from <= THRESH to > THRESH
            if ((`GIC_GPU.fifo_low_evt_o === 1'b1) !== ((free_ref > thr_ref) && !above_ref))
              gic_fail(12, "the GPU_FIFO_LOW event differs from FREE crossing THRESH");
            // (13) a pending marker holds the room
            if (mrk_pend && ((`GIC_GPU.gpu_stat[7:0] !== 8'h00) || (`GIC_GPU.gpu_stat[17] !== 1'b1) ||
                             (`GIC_GPU.push === 1'b1)))
              gic_fail(13, "a pending DISCARD marker with FREE not 0, FULL clear or a push taken");
            // (14) a bound error raised by an F read (source, mask, A8, tap)
            // or by the immediate index abandons no older pixel: W holds none
            // it does not take this cycle, L none (the pixels before the
            // faulting one are drawn)
            if ((`GIC_FW.bound === 1'b1) && (`GIC_FW.w_slot !== 1'b1) && (`GIC_FW.f_slot === 1'b1) &&
                (((`GIC_FW.t2_v === 1'b1) && (`GIC_FW.w_take !== 1'b1)) || (`GIC_FW.l_busy === 1'b1)))
              gic_fail(14, "an F read past the VRAM abandons an older pixel still to be merged");
            if ((`GIC_FW.bound === 1'b1) && (`GIC_FW.i_oob === 1'b1) &&
                !((`GIC_FW.p_want === 1'b1) && (`GIC_FW.p_oob === 1'b1)) &&
                (((`GIC_FW.t2_v === 1'b1) && (`GIC_FW.w_take !== 1'b1)) || (`GIC_FW.l_busy === 1'b1)))
              gic_fail(14, "an immediate index past the VRAM abandons an older pixel still to be merged");
            // (15) the engine's colour depth: one-hot {16, 8, 4, 2, 1} bpp
            if ((^`GIC_PA.bpp === 1'bx) || (`GIC_PA.bpp == 5'd0) || ((`GIC_PA.bpp & (`GIC_PA.bpp - 5'd1)) != 5'd0))
              gic_fail(15, "the pixel engine's colour depth register is not one-hot");
            // (16) a line is a FILL: never with a texture kind (the decoder's
            // registers, and the engine's inputs: with run-ahead the copy)
            if (((`GIC_DEC.line === 1'b1) && (`GIC_DEC.kind[2] === 1'b1)) ||
                ((`GIC_PA.ln_i === 1'b1) && (`GIC_PA.kind_i[2] === 1'b1)))
              gic_fail(16, "a line with a texture kind (LINE and kind[2] both set)");
         end
         su_f_q    <= su_f;
         su_win_q  <= su_win & model_on;
         px_fill_q <= px_fill;
         px_busy_q <= px_busy & model_on;
         // The models reset with the DUT (sampled: sync or async alike).
         // Priority: reset > flush > start > grant
         if (`GIC_GPU.hresetn_i === 1'b0)      lst_left <= 0;
         else if (`GIC_LST.flush_i === 1'b1)   lst_left <= 0;
         else if (`GIC_LST.start_i === 1'b1)   lst_left <= `GIC_LST.start_n;
         else if (`GIC_LST.vgnt_i === 1'b1)    lst_left <= lst_left - 1;
         if (`GIC_GPU.hresetn_i === 1'b0) begin
           thr_ref   <= GPU_FIFO_DEPTH / 2;
           above_ref <= 1'b1;
         end else begin
           above_ref <= (free_ref > thr_ref) && (`GIC_GPU.thr_wr !== 1'b1);
           if (`GIC_GPU.thr_wr === 1'b1)
             thr_ref <= (thr_wd >= GPU_FIFO_DEPTH) ? GPU_FIFO_DEPTH : thr_wd;
         end
         if (`GIC_GPU.hresetn_i === 1'b0)
           dec_pitch <= 16'h0000;
         else if ((`GIC_DEC.rst_go === 1'b1) || ((`GIC_DEC.cmd_pop === 1'b1) && (`GIC_DEC.is_dst === 1'b1)))
           dec_pitch <= (`GIC_DEC.rst_sel === 1'b1) ? 16'h0000 : `GIC_DEC.head[15:0];
      end
   end
endgenerate

//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    cover_monitor
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cover_monitor.v
// Module Description : Homegrown functional-coverage monitor (`included into
//                      tb_belenos). Each bin is a sticky flag raised the first
//                      time its condition is observed; cover_report emits one
//                      "COVERAGE HIT: <bin>" line per raised bin at the end of
//                      the simulation, and run_sweep.py fails the sweep if a
//                      bin of sim_configs.MANDATORY_COVER_BINS was never hit.
//                      Bins use === compares so an X never raises one.
//----------------------------------------------------------------------------

reg cov_r_okay;
reg cov_r_wait_state;
reg cov_r_hresp_err;
reg cov_v_byte;
reg cov_v_half;
reg cov_v_word;
reg cov_v_wait_state;
reg cov_v_pf_hit;
reg cov_v_pbm_next;
reg cov_v_pbm_same;
reg cov_v_hresp_err;
reg cov_v_wb_post;
reg cov_r_vw_hold;
reg cov_vram_write;
reg cov_vram_read;
reg cov_lut_write;
reg cov_lut_read;
reg cov_hclk_en_hi;
reg cov_hclk_en_lo;
reg cov_gpu_nw_rd;
reg cov_gpu_wait_rel;
reg cov_gpu_wait_flush;
reg cov_gpu_rst_state;
reg cov_gpu_grgb_sat;
reg cov_gpu_ra_kill;
reg cov_arb_gpu_first;
reg cov_arb_bk_urgent;
reg cov_dpi_underflow;
reg cov_cur_ret;
reg cov_cur_cl;
reg cov_cur_wait;
reg cov_cur_urgent;

initial begin
   cov_r_okay       = 1'b0;
   cov_r_wait_state = 1'b0;
   cov_r_hresp_err  = 1'b0;
   cov_v_byte       = 1'b0;
   cov_v_half       = 1'b0;
   cov_v_word       = 1'b0;
   cov_v_wait_state = 1'b0;
   cov_v_pf_hit     = 1'b0;
   cov_v_wb_post    = 1'b0;
   cov_r_vw_hold    = 1'b0;
   cov_v_pbm_next   = 1'b0;
   cov_v_pbm_same   = 1'b0;
   cov_v_hresp_err  = 1'b0;
   cov_vram_write   = 1'b0;
   cov_vram_read    = 1'b0;
   cov_lut_write    = 1'b0;
   cov_lut_read     = 1'b0;
   cov_hclk_en_hi   = 1'b0;
   cov_hclk_en_lo   = 1'b0;
   cov_gpu_nw_rd    = 1'b0;
   cov_gpu_wait_rel   = 1'b0;
   cov_gpu_wait_flush = 1'b0;
   cov_gpu_rst_state  = 1'b0;
   cov_gpu_grgb_sat   = 1'b0;
   cov_gpu_ra_kill  = 1'b0;
   cov_arb_gpu_first = 1'b0;
   cov_arb_bk_urgent = 1'b0;
   cov_dpi_underflow = 1'b0;
   cov_cur_ret      = 1'b0;
   cov_cur_cl       = 1'b0;
   cov_cur_wait     = 1'b0;
   cov_cur_urgent   = 1'b0;
end

// Called by ahb_xfer at the end of every transfer. The ERROR bins (r_hresp_err,
// v_hresp_err) are raised by contract_check.v, on a well-formed two-cycle ERROR.
task cover_ahb;
   input         port;
   input   [1:0] size;
   input         resp;
   input integer waits;
   begin
      if (port == PORT_R) begin
         if (resp === 1'b0) cov_r_okay      = 1'b1;
         if ((resp === 1'b0) && (waits > 0)) cov_r_wait_state = 1'b1;
      end else begin
         if (resp === 1'b0) begin
            if (size == SZ_B) cov_v_byte = 1'b1;
            if (size == SZ_H) cov_v_half = 1'b1;
            if (size == SZ_W) cov_v_word = 1'b1;
            if (waits > 0)    cov_v_wait_state = 1'b1;
         end
      end
   end
endtask

// The window's read-ahead buffer. A bench back-door write to vram_mem (no
// macro access) is invisible to it: the bench drops the buffer then, as no
// real master can write the VRAM that way. A buffered word that differs from
// the VRAM after a macro write to it, made since the read that loaded it was
// granted, is the RTL's to drop: a read served after it is an error (below).
`define BLNS_PB dut.u_core.u_ahb_vram
reg               pb_mwritten;                           // a macro write hit the buffered word since its read's grant
reg [VRAM_AW-1:0] pb_mw_addr;
reg               pb_ra_mw;                              // ... the read ahead's word since its grant
reg [VRAM_AW-1:0] pb_ra_addr;
reg               pb_dm_mw;                              // ... the demand read's word since its grant
reg [VRAM_AW-1:0] pb_dm_addr;
initial begin
   pb_mwritten = 1'b0;
   pb_ra_mw    = 1'b0;
   pb_dm_mw    = 1'b0;
end
always @(posedge hclk)
  if (model_on) begin
     if ((vram_cen === 1'b0) && (vram_wen !== 4'hF)) begin
        if (vram_addr == pb_ra_addr) pb_ra_mw = 1'b1;
        if (vram_addr == pb_dm_addr) pb_dm_mw = 1'b1;
        if (vram_addr == `BLNS_PB.pb_addr) begin
           pb_mwritten = 1'b1;
           pb_mw_addr  = vram_addr;
        end
     end
     if (`BLNS_PB.pb_data_en === 1'b1) begin             // the buffer loads: from the demand read or the read ahead
        pb_mw_addr  = (`BLNS_PB.retarget === 1'b1) ? `BLNS_PB.pb_addr_nxt : `BLNS_PB.pb_addr;
        pb_mwritten = ((`BLNS_PB.retarget === 1'b1) && (`BLNS_PB.keep_now === 1'b1)) ?
                      ((pb_dm_addr == pb_mw_addr) & pb_dm_mw) : ((pb_ra_addr == pb_mw_addr) & pb_ra_mw);
     end
     if (`BLNS_PB.wp_vgnt_i === 1'b1) begin
        pb_ra_addr = `BLNS_PB.wp_vaddr_o;
        pb_ra_mw   = 1'b0;
     end
     if ((`BLNS_PB.vgnt_i === 1'b1) && (`BLNS_PB.dph_write !== 1'b1)) begin
        pb_dm_addr = `BLNS_PB.dph_addr;
        pb_dm_mw   = 1'b0;
     end
  end
always @(negedge free_clk) begin                         // hclk may be gated off meanwhile
  if ((`BLNS_PB.pb_v !== 1'b1) || (`BLNS_PB.pb_addr != pb_mw_addr))
     pb_mwritten = 1'b0;
  if (model_on && (`BLNS_PB.pb_v === 1'b1) && !pb_mwritten &&
      (vram_mem[`BLNS_PB.pb_addr] !== `BLNS_PB.pb_data))
     `BLNS_PB.u_pb_flags.q_o[3] = 1'b0;                  // back-door write: drop the buffer
end

// A read served by the buffer returns the word the VRAM holds; the model is
// read before this edge's write lands
always @(posedge hclk)
  if (model_on && (dut.u_core.u_ahb_vram.pb_hit === 1'b1)) begin
     cov_v_pf_hit = 1'b1;
     if (dut.u_core.u_ahb_vram.pb_data !== vram_mem[dut.u_core.u_ahb_vram.pb_addr]) begin
        $display("ERROR: VRAM window read-ahead buffer -- word 0x%h holds 0x%h, the VRAM 0x%h %t",
                 dut.u_core.u_ahb_vram.pb_addr, dut.u_core.u_ahb_vram.pb_data,
                 vram_mem[dut.u_core.u_ahb_vram.pb_addr], $time);
        error = error + 1;
     end
  end

// The registered read-ahead match (u_pb_match) equals the address compare it
// stands for in every cycle it is used; bins for its two retarget cases
always @(posedge hclk)
  if (model_on) begin
     if ((dut.u_core.u_ahb_vram.rd_xfer === 1'b1) && (dut.u_core.u_ahb_vram.rd_wait !== 1'b1) &&
         (dut.u_core.u_ahb_vram.pb_match !== (dut.u_core.u_ahb_vram.dph_addr == dut.u_core.u_ahb_vram.pb_addr))) begin
        $display("ERROR: VRAM window read-ahead -- registered match differs from the address compare %t", $time);
        error = error + 1;
     end
     if ((dut.u_core.u_ahb_vram.dph_en === 1'b1) && (dut.u_core.u_ahb_vram.retarget === 1'b1) &&
         (dut.u_core.u_ahb_vram.aph_valid === 1'b1)) begin
        if (dut.u_core.u_ahb_vram.go_next === 1'b1) cov_v_pbm_next = 1'b1;
        else                                         cov_v_pbm_same = 1'b1;
     end
  end

// The window's registered HREADYOUT equals, in every cycle, the ready decoded
// from the same cycle's state (a write with the posted entry empty, a read
// served by the buffer, by its landed data or by the returning data, the
// ERROR response); a posted write is made before any other window access.
wire pb_xfer      = `BLNS_PB.dph_valid & ~`BLNS_PB.dph_err;
wire pb_hready_ref = `BLNS_PB.error_resp ? `BLNS_PB.error_resp_done :
                     ~(pb_xfer & ~(`BLNS_PB.dph_write ? ~`BLNS_PB.wb_v : `BLNS_PB.rd_cmp));
always @(posedge hclk)
  if (model_on && (dut.u_core.hresetn_i === 1'b1)) begin
     if (`BLNS_PB.hreadyout_o !== pb_hready_ref) begin
        $display("ERROR: VRAM window -- registered HREADYOUT %b, the same-cycle ready %b %t",
                 `BLNS_PB.hreadyout_o, pb_hready_ref, $time);
        error = error + 1;
     end
     if ((`BLNS_PB.wb_v === 1'b1) && (`BLNS_PB.vreq_o !== 1'b1 || `BLNS_PB.vwe_o !== 1'b1 ||
                                      `BLNS_PB.vaddr_o !== `BLNS_PB.wb_addr))
       begin
        $display("ERROR: VRAM window -- a posted write is not the window's request %t", $time);
        error = error + 1;
     end
     if (`BLNS_PB.wb_v === 1'b1) cov_v_wb_post = 1'b1;
  end

// The register port's registered HREADYOUT equals, in every cycle, the ready
// decoded from the same cycle's state it stands for (the slaves' same-cycle
// readies, a transfer not started behind a posted window write, the ERROR
// response), so it inserts exactly the same wait states; the backend's LUT
// request one cycle ahead is the next cycle's request.
`define BLNS_RP dut.u_core.u_ahb_reg
reg rp_lreq_nxt_q;
initial rp_lreq_nxt_q = 1'b0;
wire rp_dec_any   = `BLNS_RP.dec_regs | `BLNS_RP.dec_gpu | `BLNS_RP.dec_bdi | `BLNS_RP.dec_lut;
wire rp_sel_ready = (`BLNS_RP.dec_regs & dut.u_core.rb_ready_regs  ) |
                    (`BLNS_RP.dec_gpu  & dut.u_core.rb_ready_gpu   ) |
                    (`BLNS_RP.dec_bdi  & dut.u_core.bdi_reg_ready_i) |
                    (`BLNS_RP.dec_lut  & dut.u_core.rb_ready_lut   ) |
                    ~rp_dec_any;
wire rp_hold      = `BLNS_RP.dph_valid & ~`BLNS_RP.dph_err & ~`BLNS_RP.rb_go;
wire rp_hready_ref = `BLNS_RP.error_resp ? `BLNS_RP.error_resp_done :
                     ~(rp_hold | (`BLNS_RP.rb_valid_o & ~rp_sel_ready));
always @(posedge hclk) begin
  if (model_on && (dut.u_core.hresetn_i === 1'b1)) begin
     if (`BLNS_RP.hreadyout_o !== rp_hready_ref) begin
        $display("ERROR: register port -- registered HREADYOUT %b, the same-cycle ready %b %t",
                 `BLNS_RP.hreadyout_o, rp_hready_ref, $time);
        error = error + 1;
     end
     if (rp_hold === 1'b1) cov_r_vw_hold = 1'b1;
     if (dut.u_core.bk_lreq !== rp_lreq_nxt_q) begin
        $display("ERROR: backend -- LUT request %b, predicted %b one cycle ahead %t",
                 dut.u_core.bk_lreq, rp_lreq_nxt_q, $time);
        error = error + 1;
     end
  end
  rp_lreq_nxt_q = (dut.u_core.hresetn_i === 1'b1) & (dut.u_core.bk_lreq_nxt === 1'b1);
end

always @(posedge hclk)
  if (model_on) begin
   if (vram_cen === 1'b0 && vram_wen !== 4'hF) cov_vram_write = 1'b1;
   if (vram_cen === 1'b0 && vram_wen === 4'hF) cov_vram_read  = 1'b1;
   if (lut_cen  === 1'b0 && lut_wen  === 1'b0) cov_lut_write  = 1'b1;
   if (lut_cen  === 1'b0 && lut_wen  === 1'b1) cov_lut_read   = 1'b1;
  end

// GPU source read ahead with the registered read data: a read of the word after
// the next token's, an entry dropped by a merge into its word
generate
   if ((VRAM_RD_LAT + VRAM_RD_REG_EN > 1) && (GPU_EN != 0)) begin : G_COV_NW
      always @(posedge hclk)
        if (model_on) begin
           if ((dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.la_gnt === 1'b1) &&
               (dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.la_want !== 1'b1))         cov_gpu_nw_rd    = 1'b1;
           if (((dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.pf_kill0 === 1'b1) &&
                (dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.pf_v === 1'b1)) ||
               ((dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.g_ra2.pf_kill1 === 1'b1) &&
                (dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.pf1_v === 1'b1)))          cov_gpu_ra_kill  = 1'b1;
        end
   end
endgenerate

// SET_EXT2 and the RGB gradient: a WAIT_REFR_DONE released by a frame end, one
// ended by a flush, RESET_STATE executed, an RGB channel saturated
`define COV_DEC dut.u_core.G_GPU.u_gpu.u_dec
`define COV_PX  dut.u_core.G_GPU.u_gpu.u_px.u_px_a
generate
   if (GPU_EN != 0) begin : G_COV_X2
      wire [8:0] cr = {4'h0, `COV_PX.fill_i[15:11]} + {`COV_PX.grad_val[41], `COV_PX.grad_val[41:34]};
      wire [8:0] cg = {3'h0, `COV_PX.fill_i[10:5]}  + {`COV_PX.grad_val[27], `COV_PX.grad_val[27:20]};
      wire [8:0] cb = {4'h0, `COV_PX.fill_i[4:0]}   + {`COV_PX.grad_val[13], `COV_PX.grad_val[13:6]};
      always @(posedge hclk)
        if (model_on) begin
           if ((`COV_DEC.cmd_pop === 1'b1) && (`COV_DEC.is_wait === 1'b1))                     cov_gpu_wait_rel   = 1'b1;
           if ((`COV_DEC.refr_armed === 1'b1) && (`COV_DEC.wait_clr === 1'b1) &&
               (`COV_DEC.cmd_pop !== 1'b1))                                                     cov_gpu_wait_flush = 1'b1;
           if (`COV_DEC.rst_go === 1'b1)                                                        cov_gpu_rst_state  = 1'b1;
           if ((`COV_PX.grad_en === 1'b1) && (`COV_PX.grad_rgb === 1'b1) && (`COV_PX.a_emit === 1'b1) &&
               (cr[8] | (cr[7:5] != 3'b000) | cg[8] | (cg[7:6] != 2'b00) | cb[8] | (cb[7:5] != 3'b000)))
                                                                                                cov_gpu_grgb_sat   = 1'b1;
        end
   end
endgenerate

// Lines: each octant (axis and signs) walked, an exact Bresenham tie, the
// early exit past the window, the set-up's box test, the pattern phase
// wrapping at LEN
reg [7:0] cov_line_oct;
reg       cov_line_tie, cov_line_exit, cov_line_reject, cov_line_wrap;
integer   cov_i;
initial begin cov_line_oct = 8'h00; cov_line_tie = 1'b0; cov_line_exit = 1'b0; cov_line_reject = 1'b0; cov_line_wrap = 1'b0; end
`define COV_LW dut.u_core.G_GPU.u_gpu.u_px.u_px_a.g_lwalk
`define COV_SU dut.u_core.G_GPU.u_gpu.u_setup
generate
   if ((GPU_EN != 0) && (GPU_LINE_EN != 0) && (GPU_XY_EN != 0)) begin : G_COV_LINE
      always @(posedge hclk)
        if (model_on && (`COV_LW.lw_step === 1'b1)) begin
           cov_line_oct[{`COV_LW.lw_xm, `COV_LW.lw_sm, `COV_LW.lw_sn} & 3'h7] = 1'b1;
           if ((`COV_LW.lw_aa === 1'b0) && (`COV_LW.dg_z === 1'b1))                   cov_line_tie    = 1'b1;
           if (`COV_LW.lw_ex === 1'b1)                                                  cov_line_exit   = 1'b1;
           if ((`COV_LW.ph_wrap === 1'b1) && (`COV_LW.aa_h0 === 1'b0) && (dut.u_core.G_GPU.u_gpu.u_px.u_px_a.ln_len_i !== 5'd0))
                                                                                         cov_line_wrap   = 1'b1;
        end
      always @(posedge hclk)
        if (model_on && (`COV_SU.l_lat === 1'b1) && (`COV_SU.c_rej === 1'b1) && (`COV_SU.xy_on === 1'b1))
           cov_line_reject = 1'b1;
   end
endgenerate

// RGB565A8 (blending): an A8 pixel's factor 0 (skipped), 256 (opaque) and
// between at W, its A8 word from the read-ahead entry, the holder refilled
// for an A8 copy. Bilinear: 1 / 2 / 3 / 4 taps a pixel, a tap dropped for its
// weight and one for the box (TBORDER) (1, 2 or 4 taps: the drops are
// per row and per column), each tap-cache entry hit and missed,
// a companion straddling two A8 words (a read filling one byte), an entry
// dropped by a W write, alpha256 0 / 256 / between
reg       cov_a8_m0, cov_a8_m32, cov_a8_mid, cov_a8_rahit, cov_a8_refill;
reg [3:0] cov_bil_ntap;
reg       cov_bil_dropw, cov_bil_dropb, cov_bil_straddle, cov_bil_wdrop, cov_bil_a0, cov_bil_a256, cov_bil_amid;
reg [3:0] cov_bil_hit, cov_bil_miss;
integer   cov_bil_k;
initial begin
   cov_a8_m0 = 1'b0; cov_a8_m32 = 1'b0; cov_a8_mid = 1'b0; cov_a8_rahit = 1'b0; cov_a8_refill = 1'b0;
   cov_bil_ntap = 4'h0; cov_bil_dropw = 1'b0; cov_bil_dropb = 1'b0; cov_bil_straddle = 1'b0; cov_bil_wdrop = 1'b0;
   cov_bil_a0 = 1'b0; cov_bil_a256 = 1'b0; cov_bil_amid = 1'b0; cov_bil_hit = 4'h0; cov_bil_miss = 4'h0; cov_bil_k = 0;
end
`define COV_FW dut.u_core.G_GPU.u_gpu.u_px.u_px_fw
`define COV_PA dut.u_core.G_GPU.u_gpu.u_px.u_px_a
generate
   if ((GPU_EN != 0) && (GPU_BLEND_EN != 0)) begin : G_COV_A8
      always @(posedge hclk)
        if (model_on && (`COV_FW.a8_on === 1'b1) && (`COV_FW.bil_on === 1'b0)) begin
           if ((`COV_FW.t2_v === 1'b1) && (`COV_FW.w_take === 1'b1) && (`COV_FW.t2_skip === 1'b0)) begin
              if (({`COV_FW.t2_a9, `COV_FW.t2_alpha} === 9'd0) && (`COV_FW.mix5 === 1'b1))   cov_a8_m0  = 1'b1;
              if ((`COV_FW.t2_a9 === 1'b1) || ((`COV_FW.mix5 === 1'b0) && (`COV_FW.t2_alpha === 8'hFF))) cov_a8_m32 = 1'b1;
              else if (`COV_FW.t2_alpha !== 8'h00)                                             cov_a8_mid = 1'b1;
           end
           if ((`COV_FW.f_take === 1'b1) && (`COV_FW.m_hit_a === 1'b1))                       cov_a8_rahit  = 1'b1;
           if (`COV_FW.m_rd_gnt === 1'b1)                                                      cov_a8_refill = 1'b1;
        end
   end
   if ((GPU_EN != 0) && (GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0)) begin : G_COV_BIL
      always @(posedge hclk)
        if (model_on && (`COV_PA.bil_on === 1'b1)) begin
           if (`COV_PA.a_tok === 1'b1) begin
              if (`COV_PA.tap_end === 1'b1) begin
                 if ((`COV_PA.bil_skip === 1'b0) && (cov_bil_k < 4)) cov_bil_ntap[cov_bil_k] = 1'b1;
                 if (`COV_PA.bil_skip === 1'b0) begin
                    if ((`COV_PA.g_bil.b_fx == 6'd0) || (`COV_PA.g_bil.b_fx == 6'd32) ||
                        (`COV_PA.g_bil.b_fy == 6'd0) || (`COV_PA.g_bil.b_fy == 6'd32))       cov_bil_dropw = 1'b1;
                    else if (`COV_PA.g_bil.b_tm !== 4'hF)                                    cov_bil_dropb = 1'b1;
                 end
                 cov_bil_k = 0;
              end else
                 cov_bil_k = cov_bil_k + 1;
           end
        end
      always @(posedge hclk)
        if (model_on && (`COV_FW.bil_on === 1'b1)) begin
           if ((`COV_FW.f_take === 1'b1) && (`COV_FW.t1_skip === 1'b0) && (`COV_FW.g_bil.b_hit === 1'b1))
              cov_bil_hit[`COV_FW.g_bil.u_px_tc.lk_e] = 1'b1;
           if (`COV_FW.g_bil.b_cgnt === 1'b1) cov_bil_miss[`COV_FW.g_bil.u_px_tc.lk_e] = 1'b1;
           if ((`COV_FW.g_bil.b_agnt === 1'b1) && (`COV_FW.g_bil.a_part === 1'b0)) cov_bil_straddle = 1'b1;
           if (((`COV_FW.g_bil.u_px_tc.g_ent[0].drop & `COV_FW.g_bil.u_px_tc.e_v[0]) |
                (`COV_FW.g_bil.u_px_tc.g_ent[1].drop & `COV_FW.g_bil.u_px_tc.e_v[1]) |
                (`COV_FW.g_bil.u_px_tc.g_ent[2].drop & `COV_FW.g_bil.u_px_tc.e_v[2]) |
                (`COV_FW.g_bil.u_px_tc.g_ent[3].drop & `COV_FW.g_bil.u_px_tc.e_v[3])) === 1'b1) cov_bil_wdrop = 1'b1;
           if (`COV_FW.l_out === 1'b1) begin
              if ((`COV_FW.l_a256 === 9'd0) && (GPU_BLEND_EN != 0)) cov_bil_a0   = 1'b1;
              else if (`COV_FW.l_a256 === 9'h100)                   cov_bil_a256 = 1'b1;
              else if (GPU_BLEND_EN != 0)                           cov_bil_amid = 1'b1;
           end
        end
   end
endgenerate

// VRAM arbiter: the GPU's starvation bound taken, an urgent refresh granted
// over a waiting window
always @(posedge hclk)
  if (model_on) begin
     if (dut.u_core.u_vram_arb.age_first === 1'b1)                                   cov_arb_gpu_first = 1'b1;
     if ((dut.u_core.u_vram_arb.urg_any === 1'b1) && (dut.u_core.u_vram_arb.host_req === 1'b1))
                                                                                       cov_arb_bk_urgent = 1'b1;
  end

// Hardware cursor: a cursor word returned (tagged) and one with CL swap (the
// column copy), the walk held for a cursor line, a cursor read granted urgent
generate
   if (CURSOR_EN != 0) begin : G_COV_CUR
      always @(posedge hclk)
        if (model_on) begin
           if ((dut.u_core.v_rvalid[VRQ_BK] === 1'b1) && (dut.u_core.v_rtag === 1'b1)) begin
              cov_cur_ret = 1'b1;
              if (dut.u_core.u_backend.cfg_swap[0] === 1'b1) cov_cur_cl = 1'b1;
           end
           if ((dut.u_core.u_backend.cur_wait === 1'b1) && (dut.u_core.u_backend.run === 1'b1)) cov_cur_wait = 1'b1;
           if ((dut.u_core.v_gnt[VRQ_BK] === 1'b1) && (dut.u_core.v_tag[VRQ_BK] === 1'b1) &&
               (dut.u_core.v_urgent[VRQ_BK] === 1'b1))                                         cov_cur_urgent = 1'b1;
        end
   end
endgenerate

// DPI: an underflow event (the line buffers ran dry in a frame)
generate
   if (HAS_DPI) begin : G_COV_DPI
      reg uf_q;
      initial uf_q = 1'b0;
      always @(posedge hclk) begin
         if (model_on && (dut.G_DPI.u_dpi.uf_p !== uf_q) && (uf_q !== 1'bx)) cov_dpi_underflow = 1'b1;
         uf_q = dut.G_DPI.u_dpi.uf_p;
      end
   end
endgenerate

always @(negedge free_clk)
  if (hresetn === 1'b1) begin
     if (hclk_en === 1'b1) cov_hclk_en_hi = 1'b1;
     if (hclk_en === 1'b0) cov_hclk_en_lo = 1'b1;
  end

task cover_report;
   begin
      if (cov_r_okay)              $display("COVERAGE HIT: r_okay");
      if (cov_r_wait_state)        $display("COVERAGE HIT: r_wait_state");
      if (cov_r_hresp_err)         $display("COVERAGE HIT: r_hresp_err");
      if (cov_v_byte)              $display("COVERAGE HIT: v_byte");
      if (cov_v_half)              $display("COVERAGE HIT: v_half");
      if (cov_v_word)              $display("COVERAGE HIT: v_word");
      if (cov_v_wait_state)        $display("COVERAGE HIT: v_wait_state");
      if (cov_v_pf_hit)            $display("COVERAGE HIT: v_pf_hit");
      if (cov_v_wb_post)           $display("COVERAGE HIT: v_wb_post");
      if (cov_r_vw_hold)           $display("COVERAGE HIT: r_vw_hold");
      if (cov_v_pbm_next)          $display("COVERAGE HIT: v_pbm_next");
      if (cov_v_pbm_same)          $display("COVERAGE HIT: v_pbm_same");
      if (cov_v_hresp_err)         $display("COVERAGE HIT: v_hresp_err");
      if (cov_vram_write)          $display("COVERAGE HIT: vram_write");
      if (cov_vram_read)           $display("COVERAGE HIT: vram_read");
      if (cov_lut_write)           $display("COVERAGE HIT: lut_write");
      if (cov_lut_read)            $display("COVERAGE HIT: lut_read");
      if (cov_gpu_nw_rd)           $display("COVERAGE HIT: gpu_nw_rd");
      if (cov_gpu_ra_kill)         $display("COVERAGE HIT: gpu_ra_kill");
      if (cov_gpu_wait_rel)        $display("COVERAGE HIT: gpu_wait_rel");
      if (cov_gpu_wait_flush)      $display("COVERAGE HIT: gpu_wait_flush");
      if (cov_gpu_rst_state)       $display("COVERAGE HIT: gpu_rst_state");
      if (cov_gpu_grgb_sat)        $display("COVERAGE HIT: gpu_grgb_sat");
      for (cov_i = 0; cov_i < 8; cov_i = cov_i + 1)
         if (cov_line_oct[cov_i])  $display("COVERAGE HIT: gpu_line_oct%0d", cov_i);
      if (cov_line_tie)            $display("COVERAGE HIT: gpu_line_tie");
      if (cov_line_exit)           $display("COVERAGE HIT: gpu_line_exit");
      if (cov_line_reject)         $display("COVERAGE HIT: gpu_line_reject");
      if (cov_line_wrap)           $display("COVERAGE HIT: gpu_line_wrap");
      if (u_lcd8080.px_count > 0)  $display("COVERAGE HIT: dbi_8080_pixel");
      if (u_lcdspi.px_count  > 0)  $display("COVERAGE HIT: dbi_spi_pixel");
      if (cov_hclk_en_hi)          $display("COVERAGE HIT: hclk_en_hi");
      if (cov_hclk_en_lo)          $display("COVERAGE HIT: hclk_en_lo");
      if (cov_a8_m0)               $display("COVERAGE HIT: gpu_a8_m0");
      if (cov_a8_m32)              $display("COVERAGE HIT: gpu_a8_m32");
      if (cov_a8_mid)              $display("COVERAGE HIT: gpu_a8_mid");
      if (cov_a8_rahit)            $display("COVERAGE HIT: gpu_a8_rahit");
      if (cov_a8_refill)           $display("COVERAGE HIT: gpu_a8_refill");
      for (cov_i = 0; cov_i < 4; cov_i = cov_i + 1) begin
         if (cov_bil_ntap[cov_i] && (cov_i != 2)) $display("COVERAGE HIT: gpu_bil_tap%0d", cov_i + 1);   // (3: never, separable drops)
         if (cov_bil_hit[cov_i])   $display("COVERAGE HIT: gpu_bil_hit%0d", cov_i);
         if (cov_bil_miss[cov_i])  $display("COVERAGE HIT: gpu_bil_miss%0d", cov_i);
      end
      if (cov_bil_dropw)           $display("COVERAGE HIT: gpu_bil_dropw");
      if (cov_bil_dropb)           $display("COVERAGE HIT: gpu_bil_dropb");
      if (cov_bil_straddle)        $display("COVERAGE HIT: gpu_bil_straddle");
      if (cov_bil_wdrop)           $display("COVERAGE HIT: gpu_bil_wdrop");
      if (cov_bil_a0)              $display("COVERAGE HIT: gpu_bil_a0");
      if (cov_bil_a256)            $display("COVERAGE HIT: gpu_bil_a256");
      if (cov_bil_amid)            $display("COVERAGE HIT: gpu_bil_amid");
      if (cov_arb_gpu_first)       $display("COVERAGE HIT: arb_gpu_first");
      if (cov_arb_bk_urgent)       $display("COVERAGE HIT: arb_bk_urgent");
      if (cov_dpi_underflow)       $display("COVERAGE HIT: dpi_underflow");
      if (cov_cur_ret)             $display("COVERAGE HIT: cur_ret");
      if (cov_cur_cl)              $display("COVERAGE HIT: cur_cl");
      if (cov_cur_wait)            $display("COVERAGE HIT: cur_wait");
      if (cov_cur_urgent)          $display("COVERAGE HIT: cur_urgent");
      if (u_dpipanel.frames > 0)   $display("COVERAGE HIT: dpi_frame");
      if (g_tmdsrx.u_tmdsrx.vlines_hdmi > 0) $display("COVERAGE HIT: hdmi_vline");
      if (g_tmdsrx.u_tmdsrx.vlines_dvi  > 0) $display("COVERAGE HIT: dvi_vline");
      if (g_tmdsrx.u_tmdsrx.n_avi > 0) $display("COVERAGE HIT: hdmi_avi");
      if (g_tmdsrx.u_tmdsrx.n_acr > 0) $display("COVERAGE HIT: hdmi_acr");
      if (g_tmdsrx.u_tmdsrx.n_asp > 0) $display("COVERAGE HIT: hdmi_asp");
      if (g_tmdsrx.u_tmdsrx.n_aif > 0) $display("COVERAGE HIT: hdmi_aif");
      if (g_tmdsrx.u_tmdsrx.isl2  > 0) $display("COVERAGE HIT: hdmi_island2");
   end
endtask

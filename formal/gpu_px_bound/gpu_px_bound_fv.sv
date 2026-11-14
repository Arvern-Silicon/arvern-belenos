//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    gpu_px_bound_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of blns_gpu_px_fw (stages F and W, the VRAM port), built
// without blending and bilinear sampling, with the mask plane, the palette
// remap and the immediate source: a free stage A (a token appears while A
// runs, is held with its fields until F takes it, is dropped by an abort),
// a free VRAM port (a grant only while requested, the read data exactly
// RD_LAT cycles after a read grant, free data), the rectangle's operation
// decoded as blns_gpu_px_a does from a free kind, raster op, depth, remap
// mode and mask plane (constant over the run).
//
// Property: a bound error not raised by W itself (its read, or the slot's
// write, past the VRAM) leaves no older pixel behind: W takes its token in
// that cycle and L holds none (a_no_drop): ERR_CAUSE 5 by an F read or an
// immediate index past VRAM_WORDS keeps the pixels before the faulting one.
//----------------------------------------------------------------------------
`default_nettype none
module gpu_px_bound_fv #(parameter VRAM_AW = 4, parameter VRAM_WORDS = 12, parameter RD_LAT = 1,
                     parameter MPLANE = 1, parameter REMAP = 1, parameter IMM = 1) (
    input wire clk, input wire rst_n,
    input wire abort, input wire freeze, input wire start, input wire last_emit,
    input wire [8:0] alpha, input wire [15:0] transp, input wire [31:0] imm_word, input wire imm_avail, input wire imm_short,
    input wire t1_v, input wire [VRAM_AW:0] t1_dwa, input wire [4:0] t1_dboff, input wire [5:0] t1_nbits,
    input wire [VRAM_AW:0] t1_swa, input wire [4:0] t1_rot, input wire t1_word, input wire t1_mir, input wire t1_skip,
    input wire [15:0] t1_fill, input wire [VRAM_AW-1:0] t1_mwa, input wire [4:0] t1_mrot,
    input wire nx_on, input wire nx_skip, input wire [VRAM_AW:0] nx_dwa, input wire [VRAM_AW:0] nx_swa,
    input wire nw_ok, input wire [VRAM_AW:0] nw_wa,
    input wire vgnt, input wire [31:0] vrdata
);
localparam RB_W = (VRAM_AW > 6) ? (VRAM_AW - 6) : 1;
(* anyconst *) wire [2:0] bsel;                // depth 1..16 bpp
(* anyconst *) wire [3:0] px_op_c;
wire [3:0] px_op = (kind == 3'd0 || kind[2]) ? ((kind[2]) ? 4'd0 : px_op_c) : px_op_c;
// the operation decoded as blns_gpu_px_a does (no blending)
(* anyconst *) wire [2:0] kind;            // 0 FILL 1 COPY 2 COPY_TRANSP 3 EXPAND 4/5 textures
(* anyconst *) wire [1:0] rmp_mode;
(* anyconst *) wire exp_opaque, mpl, msk_inv, imm, tex_tr_en;
always @(*) assume (kind <= 3'd5 && rmp_mode != 2'd3);
always @(*) if (imm) assume ((kind == 3'd1) || (kind == 3'd2) || (kind == 3'd3));
wire is_copy  = |kind;
wire is_tex   = kind[2];
wire is_exp   = (kind == 3'd3);
wire is_copyt = (kind == 3'd2);
wire bpp_lt8  = bpp[0] | bpp[1] | bpp[2];
wire op_hi    = (px_op == 4'd13) | (px_op == 4'd14) | (px_op == 4'd15);
wire op_no_d  = (px_op == 4'd0) | (px_op == 4'd1) | op_hi;
wire need_src = is_copy & ((px_op != 4'd2) | is_copyt | is_exp);
wire rmp_on   = REMAP & (rmp_mode != 2'd0) & ~bpp[4] & (px_op != 4'd2) & ~op_hi;
wire rmp_dst  = rmp_on & rmp_mode[1];
wire mp_on    = MPLANE & mpl & ~kind[2] & (kind[1] ^ kind[0]);
wire need_dst = bpp_lt8 | ~op_no_d | rmp_dst;
wire transp_chk = is_copyt | (op_hi & ~is_exp);
(* anyconst *) wire [7:0] shade;
(* anyconst *) wire [RB_W-1:0] rmp_base;
wire [4:0] bpp = (bsel == 0) ? 5'b00001 : (bsel == 1) ? 5'b00010 : (bsel == 2) ? 5'b00100 : (bsel == 3) ? 5'b01000 : 5'b10000;
always @(*) if ($initstate) assume (!rst_n);

wire f_take, vreq, vwe, busy, done, held, bound, go, a_init, a_run, a_abort;
wire [3:0] vbe; wire [VRAM_AW-1:0] vaddr, vwaddr; wire [31:0] vwdata;
// The read data exactly RD_LAT cycles after a read grant
reg [RD_LAT-1:0] rsh;
always @(posedge clk) if (!rst_n) rsh <= 0; else rsh <= {rsh, vgnt & vreq & ~vwe};   // (truncated: a shift)
wire vrvalid = rsh[RD_LAT-1];
always @(*) if (!vreq) assume (!vgnt);
// A: a token is held until F takes it, dropped by an abort; it appears only while A runs
reg t1_vq, f_take_q, abort_q, a_abort_q, a_run_q;
reg [VRAM_AW:0] dwa_q, swa_q; reg [4:0] dboff_q, rot_q, mrot_q; reg [5:0] nbits_q; reg word_q, mir_q, skip_q; reg [15:0] fill_q; reg [VRAM_AW-1:0] mwa_q;
always @(posedge clk) begin
    t1_vq <= t1_v; f_take_q <= f_take; abort_q <= abort; a_abort_q <= a_abort; a_run_q <= a_run;
    dwa_q <= t1_dwa; swa_q <= t1_swa; dboff_q <= t1_dboff; nbits_q <= t1_nbits; rot_q <= t1_rot; word_q <= t1_word;
    mir_q <= t1_mir; skip_q <= t1_skip; fill_q <= t1_fill; mwa_q <= t1_mwa; mrot_q <= t1_mrot;
end
always @(*) if (rst_n && !$initstate) begin
    if (t1_vq && !f_take_q && !abort_q && !a_abort_q) begin
        assume (t1_v);
        assume (t1_dwa == dwa_q && t1_swa == swa_q && t1_dboff == dboff_q && t1_nbits == nbits_q && t1_rot == rot_q &&
                t1_word == word_q && t1_mir == mir_q && t1_skip == skip_q && t1_fill == fill_q && t1_mwa == mwa_q && t1_mrot == mrot_q);
    end
    if (t1_v && !(t1_vq && !f_take_q)) assume (a_run_q && !abort_q);
end

blns_gpu_px_fw #(.RD_REG_EN(RD_LAT > 1), .RD_LAT(RD_LAT), .VRAM_WORDS(VRAM_WORDS), .VRAM_AW(VRAM_AW), .RB_W(RB_W),
                 .GPU_BLEND_EN(0), .GPU_REMAP_EN(REMAP), .GPU_MPLANE_EN(MPLANE), .GPU_IMM_EN(IMM), .BIL_USE(1'b0),
                 .FILL_PIPE(1), .ASYNC_RST_EN(1)) u_dut (
    .hclk_i(clk), .hresetn_i(rst_n), .abort_i(abort), .freeze_i(freeze), .start_i(start),
    .go_o(go), .a_init_o(a_init), .a_run_o(a_run), .a_abort_o(a_abort), .a_last_emit_i(last_emit),
    .exp_opaque_i(exp_opaque), .alpha_i(alpha), .mix5_i(1'b0), .tex_tr_en_i(tex_tr_en), .tex_shade_i(shade), .transp_i(transp),
    .rmp_base_i(rmp_base), .msk_inv_i(msk_inv), .imm_i(imm), .imm_word_i(imm_word), .imm_avail_i(imm_avail), .imm_short_i(imm_short),
    .imm_pop_o(),
    .bpp_i(bpp), .src_bpp_i(bpp), .is_copy_i(is_copy), .is_tex_i(is_tex), .is_exp_i(is_exp), .mask_on_i(1'b0), .blend_on_i(1'b0),
    .px_op_i(px_op), .blk_op_i(2'b00), .op_no_d_i(op_no_d), .need_src_i(need_src), .need_dst_i(need_dst), .transp_chk_i(transp_chk),
    .rmp_on_i(rmp_on), .rmp_dst_i(rmp_dst), .mp_on_i(mp_on), .aa_on_i(1'b0), .a8_on_i(1'b0), .bil_on_i(1'b0),
    .t1_v_i(t1_v), .t1_dwa_i(t1_dwa), .t1_dboff_i(t1_dboff), .t1_nbits_i(t1_nbits), .t1_swa_i(t1_swa), .t1_rot_i(t1_rot),
    .t1_word_i(t1_word), .t1_mir_i(t1_mir), .t1_skip_i(t1_skip), .t1_fill_i(t1_fill), .t1_mwa_i(t1_mwa), .t1_mhi_i(1'b0),
    .t1_mrot_i(t1_mrot), .t1_cov_i(8'h00), .t1_k_i(11'd0), .t1_tlast_i(1'b1), .t1_ypar_i(1'b0), .f_take_o(f_take),
    .nx_on_i(nx_on), .nx_skip_i(nx_skip), .nx_dwa_i(nx_dwa), .nx_swa_i(nx_swa), .nw_ok_i(nw_ok), .nw_wa_i(nw_wa),
    .nx_mwa_i({VRAM_AW{1'b0}}), .nx_mhi_i(1'b0),
    .vreq_o(vreq), .vwe_o(vwe), .vbe_o(vbe), .vaddr_o(vaddr), .vwaddr_o(vwaddr), .vwdata_o(vwdata),
    .vgnt_i(vgnt), .vrvalid_i(vrvalid), .vrdata_i(vrdata),
    .busy_o(busy), .done_o(done), .held_o(held), .bound_o(bound));

wire p_w_slot, p_f_slot, p_t2_v, p_w_take, p_f_oob, p_wb_sel, p_i_oob, p_l_busy, p_w_oob, p_wb_oob;
// the bound raised by F alone: not by W's own read nor the slot's write
wire f_cause = !((p_w_slot && p_w_oob) || (!p_w_slot && p_wb_sel && p_wb_oob));
always @(*) if (rst_n) a_no_drop: assert (!(bound && f_cause && ((p_t2_v && !p_w_take) || p_l_busy)));
always @(posedge clk) if (rst_n) c_bound: cover (bound && p_f_slot && !p_w_slot);
endmodule
`default_nettype wire

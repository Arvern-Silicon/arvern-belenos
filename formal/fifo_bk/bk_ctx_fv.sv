//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    bk_ctx_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// The backend FIFOs in their context: blns_backend with a free display
// driver (refresh_active_i, px_ready_i), free configuration and a VRAM and
// LUT that follow the arbiter's contract (a grant only with a request; read
// data valid exactly RD_LAT cycles after a VRAM grant, one cycle after a LUT
// grant; the data free). Proves the rule blns_bk_fifo relies on: the fetch
// never pushes into a full raw FIFO, the colour stage never pushes into a
// full output queue, and neither FIFO is popped when empty (outside a
// flush, which wins over both); the pixel credit never exceeds the raw
// FIFO's depth (RD_LAT + 4, PX_DEPTH in blns_backend). The
// fixed-latency contract the backend relies on without masking it: a token
// that fetched its word meets the word's read data valid at stage B, and a
// LUT pixel in stage C meets its LUT read data valid.
// The hardware cursor (CURSOR_EN, free cursor registers) shares the VRAM
// slot with a read tag: the slot's request is held with its address and tag
// until granted (outside the cycles a frame ends in); a pixel grant always
// issues its pixel (no read whose word would overwrite the word buffer under
// the tokens behind it); a tagged return never loads the word buffer, never
// meets a pixel token that fetched, and never comes while a cursor-box token
// is in stage B (the line buffer is not loaded under it). The LUT request
// one cycle ahead (lreq_nxt_o, for the register port's registered HREADYOUT)
// is the next cycle's request in every cycle.
// The start address: the walker starts every frame that runs at
// base + (X ? W'-1 : 0) + (Y ? (H'-1) x P : 0) of the latched frame (mod
// 2^9), the shift-add offset being that product while the requests may be
// raised (go), whatever the configuration did before or during the frame.
//----------------------------------------------------------------------------
`default_nettype none
module bk_ctx_fv #(
    parameter RD_LAT       = 1,
    parameter LUT_EN       = 1,
    parameter CURSOR_EN    = 1,
    parameter ASYNC_RST_EN = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire  [2:0] gfx_mode,
    input  wire  [3:0] disp_w,
    input  wire  [3:0] disp_h,
    input  wire  [2:0] disp_cfg,
    input  wire        pix_double,
    input  wire  [8:0] frame_base,
    input  wire [15:0] pitch,
    input  wire        sw_lut_en,
    input  wire        refr_bank,
    input  wire  [2:0] hw_palette,
    input  wire  [3:0] hw_bg,
    input  wire  [3:0] hw_fg,
    input  wire [23:0] lut_rot,
    input  wire        cur_en,
    input  wire  [9:0] cur_hot,
    input  wire [31:0] cur_pos,
    input  wire  [3:0] cur_addr,
    input  wire [23:0] cur_col1,
    input  wire [23:0] cur_col2,
    input  wire [23:0] cur_col3,
    input  wire        vgnt,
    input  wire [31:0] vrdata,
    input  wire        lgnt,
    input  wire [23:0] lrdata,
    input  wire        px_ready,
    input  wire        refresh_active
);

localparam PXD = RD_LAT + 4;                 // blns_backend's PX_DEPTH
localparam PCW = $clog2(PXD + 1);            // its credit and raw count width

wire        vreq;
wire        vurgent;
wire  [3:0] vaddr;
wire        vtag;
wire        lreq;
wire        lreq_nxt;
wire  [8:0] laddr;
wire        px_valid;
wire [23:0] px_data;
wire        px_last;
reg  [RD_LAT-1:0] v_sh;
reg  [RD_LAT-1:0] t_sh;         // the tag of each read in flight
reg         lrvalid;

blns_backend #(.VRAM_AW(4), .DIM_W(4), .LUT_EN(LUT_EN), .LUT_BANKS(2), .CURSOR_EN(CURSOR_EN), .RD_LAT(RD_LAT),
               .ASYNC_RST_EN(ASYNC_RST_EN)) u_dut (
    .hclk_i(clk), .hresetn_i(rst_n), .gfx_mode_i(gfx_mode), .disp_width_i(disp_w), .disp_height_i(disp_h),
    .disp_cfg_i(disp_cfg), .pix_double_i(pix_double), .frame_base_i(frame_base), .pitch_i(pitch),
    .sw_lut_en_i(sw_lut_en), .refr_bank_i(refr_bank), .hw_palette_i(hw_palette), .hw_bg_i(hw_bg),
    .hw_fg_i(hw_fg), .lut_rot_i(lut_rot), .cur_en_i(cur_en), .cur_hot_i(cur_hot), .cur_pos_i(cur_pos),
    .cur_addr_i(cur_addr), .cur_col1_i(cur_col1), .cur_col2_i(cur_col2), .cur_col3_i(cur_col3),
    .vreq_o(vreq), .vurgent_o(vurgent), .vaddr_o(vaddr), .vtag_o(vtag),
    .vgnt_i(vgnt), .vrvalid_i(v_sh[RD_LAT-1]), .vrtag_i(t_sh[RD_LAT-1]), .vrdata_i(vrdata), .lreq_o(lreq), .lreq_nxt_o(lreq_nxt), .laddr_o(laddr),
    .lgnt_i(lgnt), .lrvalid_i(lrvalid), .lrdata_i(lrdata), .px_valid_o(px_valid), .px_data_o(px_data),
    .px_last_o(px_last), .px_ready_i(px_ready), .refresh_active_i(refresh_active));

// Probes (connected by the driver)
wire        p_flush;
wire        p_fetch_push;
wire        p_raw_pop;
wire [PCW-1:0] p_raw_cnt;
wire        p_color_push;
wire  [1:0] p_oq_cnt;
wire        p_px_take;
wire [PCW-1:0] p_credit;
wire        p_b_valid;
wire        p_b_new;
wire        p_c_lut;
wire        p_active_dly;
wire        p_issue;
wire        p_cur_sel;
wire        p_b_fetch;
wire        p_b_cur;
wire        p_cur_wait;          // the cursor (CURSOR_EN tasks only)
wire        p_in_box;
wire        p_bv;
wire        p_bt;
wire        p_cur_term = p_in_box & ~(p_bv & ~p_bt);    // cur_wait unregistered
wire        p_go;                // the start offset is done (the request enable)
wire  [8:0] p_pa;                // the walker's pixel address
wire  [8:0] p_yofs;
wire  [8:0] p_cfg_base;          // the latched frame
wire  [3:0] p_cfg_sw;
wire  [3:0] p_cfg_sh;
wire [15:0] p_cfg_pitch;
wire  [2:0] p_cfg_swap;

// Environment
always @(*) begin
    if ($initstate) assume (!rst_n);
    assume (!vgnt || vreq);
    assume (!lgnt || lreq);
    assume (disp_w != 4'd0 && disp_h != 4'd0);       // DISP_SIZE is never 0 (blns_regs)
    if (!rst_n) assume (!vgnt && !lgnt);
end

always @(posedge clk) begin
    v_sh    <= rst_n ? {v_sh, vgnt} : {RD_LAT{1'b0}};
    t_sh    <= {t_sh, vtag};
    lrvalid <= rst_n & lgnt;
end

// The LUT request one cycle ahead, registered (0 out of reset: the request
// needs active_dly, which resets to 0)
reg         lreq_nxt_q = 1'b0;
always @(posedge clk)
    lreq_nxt_q <= rst_n & lreq_nxt;

always @(*)
    if (rst_n)
        a_lreq_nxt:    assert (lreq == lreq_nxt_q);

// The slot's request last cycle, not granted, with its address and tag
reg         pend_q = 1'b0;
reg   [3:0] pend_a;
reg         pend_t;
always @(posedge clk) begin
    pend_q <= rst_n & vreq & ~vgnt;
    pend_a <= vaddr;
    pend_t <= vtag;
end
wire        ret_tag = v_sh[RD_LAT-1] & t_sh[RD_LAT-1];

always @(*)
    if (rst_n && !p_flush) begin
        a_raw_no_ovfl: assert (!(p_fetch_push && p_raw_cnt == PXD));
        a_raw_no_udfl: assert (!(p_raw_pop && p_raw_cnt == 0));
        a_credit:      assert (p_credit <= PXD);
        a_word_data:   assert (!(p_b_valid && p_b_new) || (v_sh[RD_LAT-1] && !t_sh[RD_LAT-1]));
        // A pixel grant issues its pixel; a tagged return never loads the word
        // buffer nor meets a cursor-box token in stage B
        a_pgnt_issue:  assert (!(vgnt && !p_cur_sel) || p_issue);
        a_tag_wbuf:    assert (!(p_b_fetch && ret_tag));
        a_cur_ret:     assert (!(p_b_valid && p_b_cur && ret_tag));
        if (CURSOR_EN != 0)
            a_cur_wait: assert (p_cur_wait == p_cur_term);   // the registered copy is exact
        if (LUT_EN != 0) begin
            a_oq_no_ovfl: assert (!(p_color_push && p_oq_cnt == 2'd3));
            a_oq_no_udfl: assert (!(p_px_take && p_oq_cnt == 2'd0));
            a_lut_data:   assert (!p_c_lut || lrvalid);
        end
    end

// The start address of every frame that runs, in its first running cycle
// (go rising), and the offset while go is set
reg         go_q = 1'b0;
always @(posedge clk)
    go_q <= rst_n & p_go;
wire [19:0] ref_yofs = {16'h0000, p_cfg_sh - 4'd1} * {4'h0, p_cfg_pitch};
wire  [8:0] ref_pa   = p_cfg_base + ({9{p_cfg_swap[2]}} & {5'd0, p_cfg_sw - 4'd1})
                                  + ({9{p_cfg_swap[1]}} & ref_yofs[8:0]);
always @(*)
    if (rst_n && p_go) begin
        a_yofs:        assert (p_yofs == ref_yofs[8:0]);
        if (!go_q && refresh_active)
            a_start_pa: assert (p_pa == ref_pa);
    end

// The request is held with its address and tag until granted while the
// requests may be raised (active_dly: through the cycle a frame ends)
always @(*)
    if (rst_n && pend_q && p_active_dly)
        a_slot_hold:   assert (vreq && (vaddr == pend_a) && (vtag == pend_t));

always @(posedge clk)
    if (rst_n && !p_flush) begin
        c_raw_full:  cover (p_raw_cnt == PXD);
        if (CURSOR_EN != 0) begin
            c_cur_px:    cover (p_b_valid && p_b_cur && (px_data != 24'd0));
            c_cur_ret:   cover (ret_tag);
            c_cur_wait:  cover (vreq && vtag && !vgnt);
        end
        c_raw_pop:   cover (p_raw_pop && p_raw_cnt == 4'd1);
        if (LUT_EN != 0) begin
            c_oq_full:   cover (p_oq_cnt == 2'd3);
            c_lut_px:    cover (p_color_push && lrvalid);
        end
    end

// The requests come from flops (the second and later cycles of a frame, and
// the cycle it ends): a grant in the cycle refresh_active falls is wasted,
// and the assertions above hold through it
always @(posedge clk)
    if (rst_n && p_flush && !refresh_active) begin
        c_vgnt_end: cover (vgnt);
        if (LUT_EN != 0)
            c_lgnt_end: cover (lgnt);
    end

endmodule

`default_nettype wire

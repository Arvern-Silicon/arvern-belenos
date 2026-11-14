//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    ahb_reg_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of the register port's registered HREADYOUT: blns_ahb_reg
// with the LUT window (blns_lut) behind it, an AHB-Lite manager with free
// transfers, a backend LUT requester whose request is the one it announced
// one cycle ahead (bk_lreq_nxt free: the backend's contract, proved in
// fifo_bk a_lreq_nxt), and the other windows as in belenos_core (the
// register and GPU windows ready with the transfer; the BDI window too with
// a built-in driver, free with an external one, BDI_EXT_EN), and the VRAM
// window's posted-write flag the registered copy of its free next state
// (blns_ahb_vram's side of the contract is ahb_vram a_wb_nxt).
//
// Properties: HREADYOUT equals, in every cycle, the ready decoded from the
// same cycle's state (the selected window's same-cycle ready, the two-cycle
// ERROR, a transfer held behind a posted window write), so the registered
// HREADYOUT inserts exactly the wait states of a combinational one; with the
// AHB-Lite fabric, a LUT write is never completed without its macro write;
// no transfer starts on the register bus while a window write is posted, and
// one started runs to its end.
//----------------------------------------------------------------------------
`default_nettype none
module ahb_reg_fv #(
    parameter LUT_BANKS     = 2,
    parameter BDI_EXT_EN    = 0,
    parameter PRIV_CHECK_EN = 0,
    parameter FREE_HREADY   = 0,        // 1: HREADY free (not the AHB-Lite fabric's)
    parameter ASYNC_RST_EN  = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    // AHB manager
    input  wire        hsel,
    input  wire [11:0] haddr,
    input  wire  [1:0] htrans,
    input  wire        hwrite,
    input  wire  [2:0] hsize,
    input  wire  [3:0] hprot,
    input  wire        hready_other,    // HREADY while another subordinate has the data phase
    input  wire [31:0] hwdata,
    // external BDI driver (BDI_EXT_EN)
    input  wire        bdi_ready,
    // backend LUT requester
    input  wire        bk_lreq_nxt,
    input  wire  [8:0] bk_laddr,
    // LUT macro
    input  wire [23:0] lut_dout,
    // VRAM window: the posted write's next state
    input  wire        vw_pend_nxt
);

// The window's flag: the registered copy of its next state (0 out of reset)
reg         vw_pend = 1'b0;
always @(posedge clk)
    vw_pend <= rst_n & vw_pend_nxt;

wire [31:0] hrdata;
wire        hreadyout;
wire        hresp;
wire        active;
wire        rb_valid;
wire        rb_wr;
wire [11:2] rb_addr;
wire [31:0] rb_wdata;
wire        rb_wr_nxt;
wire [11:2] rb_addr_nxt;
wire        sel_regs, sel_gpu, sel_bdi, sel_lut;
wire [31:0] lut_rdata;
wire        lut_ready;
wire        lut_ready_nxt;
wire        bk_lgnt;
wire        bk_lrvalid;
wire        lut_cen, lut_wen;
wire  [8:0] lut_addr;
wire [23:0] lut_din;

// The fabric: HREADY is this port's HREADYOUT while it has the data phase
reg         dph_ours = 1'b0;
wire        hready = (FREE_HREADY != 0) ? hready_other : (dph_ours ? hreadyout : hready_other);
always @(posedge clk)
    if (!rst_n)      dph_ours <= 1'b0;
    else if (hready) dph_ours <= hsel & htrans[1];

// The backend's request: the one announced one cycle ahead (0 out of reset)
reg         bk_lreq = 1'b0;
always @(posedge clk)
    bk_lreq <= rst_n & bk_lreq_nxt;

// Built-in windows: ready with the transfer (blns_regs, blns_gpu, blns_dbi / blns_dpi_regs)
wire        rdy_regs = rb_valid & sel_regs;
wire        rdy_gpu  = rb_valid & sel_gpu;
wire        rdy_bdi  = (BDI_EXT_EN != 0) ? bdi_ready : (rb_valid & sel_bdi);

blns_ahb_reg #(.GPU_EN(1), .LUT_EN(1), .PRIV_CHECK_EN(PRIV_CHECK_EN), .BDI_EXT_EN(BDI_EXT_EN),
               .ASYNC_RST_EN(ASYNC_RST_EN)) u_reg (
    .hclk_i(clk), .hresetn_i(rst_n), .hsel_i(hsel), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
    .hsize_i(hsize), .hprot_i(hprot), .hsmode_i(1'b0), .hready_i(hready), .hwdata_i(hwdata),
    .hrdata_o(hrdata), .hreadyout_o(hreadyout), .hresp_o(hresp), .active_o(active),
    .vw_pend_i(vw_pend), .vw_pend_nxt_i(vw_pend_nxt),
    .rb_valid_o(rb_valid), .rb_wr_o(rb_wr), .rb_addr_o(rb_addr), .rb_wdata_o(rb_wdata),
    .rb_wr_nxt_o(rb_wr_nxt), .rb_addr_nxt_o(rb_addr_nxt),
    .rb_sel_regs_o(sel_regs), .rb_sel_gpu_o(sel_gpu), .rb_sel_bdi_o(sel_bdi), .rb_sel_lut_o(sel_lut),
    .rb_rdata_regs_i(32'h0), .rb_rdata_gpu_i(32'h0), .rb_rdata_bdi_i(32'h0), .rb_ready_bdi_i(rdy_bdi),
    .rb_rdata_lut_i(lut_rdata), .rb_ready_nxt_lut_i(lut_ready_nxt));

blns_lut #(.LUT_BANKS(LUT_BANKS), .ASYNC_RST_EN(ASYNC_RST_EN)) u_lut (
    .hclk_i(clk), .hresetn_i(rst_n), .rb_valid_i(rb_valid), .rb_sel_i(sel_lut), .rb_wr_i(rb_wr),
    .rb_addr_i(rb_addr[10:2]), .rb_wdata_i(rb_wdata), .rb_rdata_o(lut_rdata), .rb_ready_o(lut_ready),
    .rb_wr_nxt_i(rb_wr_nxt), .rb_bank_nxt_i(rb_addr_nxt[10]), .rb_ready_nxt_o(lut_ready_nxt),
    .bk_lreq_i(bk_lreq), .bk_lreq_nxt_i(bk_lreq_nxt), .bk_laddr_i(bk_laddr), .bk_lgnt_o(bk_lgnt),
    .bk_lrvalid_o(bk_lrvalid), .lut_cen_o(lut_cen), .lut_wen_o(lut_wen), .lut_addr_o(lut_addr),
    .lut_din_o(lut_din), .lut_dout_i(lut_dout));

// Probes (connected by the driver)
wire        p_err_done;                 // ERROR second cycle
wire        p_rb_first;                 // the LUT window takes the macro over the backend
wire        p_rd_pend;                  // a LUT window read granted, its data due
wire        p_dph_valid;                // the port's data phase
wire        p_dph_go;                   // the port's transfer has started

// A transfer started on the register bus, its data phase not yet over
reg         st_q = 1'b0;
always @(posedge clk)
    st_q <= rst_n & ~hready & (st_q | rb_valid);
wire        hold_ref  = p_dph_valid & ~hresp & vw_pend & ~st_q;

// The same-cycle ready (a combinational HREADYOUT)
wire        dec_any   = sel_regs | sel_gpu | sel_bdi | sel_lut;
wire        sel_ready = (sel_regs & rdy_regs) | (sel_gpu & rdy_gpu) | (sel_bdi & rdy_bdi) |
                        (sel_lut & lut_ready) | ~dec_any;
wire        ready_ref = hresp ? p_err_done : ~(hold_ref | (rb_valid & ~sel_ready));

wire        lut_hole  = (LUT_BANKS == 1) & rb_addr[10];
wire        lut_wr    = rb_valid & sel_lut & rb_wr & ~lut_hole;

always @(*) begin
    if ($initstate) assume (!rst_n);
end

always @(*)
    if (rst_n) begin
        a_hready:  assert (hreadyout == ready_ref);
        a_vw_start: assert (!(rb_valid && vw_pend && !st_q));
        a_vw_cont:  assert (!st_q || rb_valid || !p_dph_valid);
        h_go:       assert (st_q == p_dph_go);
        // With the fabric's HREADY: a granted read holds its data phase until
        // its data (lemmas for the induction)
        if (FREE_HREADY == 0) begin
            a_lut_wr:  assert (!(lut_wr && hreadyout) || (!lut_cen && !lut_wen));
            h_dph:     assert (dph_ours == p_dph_valid);
            h_rd_pend: assert (!p_rd_pend || (rb_valid && sel_lut && !rb_wr));
        end
    end

always @(posedge clk)
    if (rst_n) begin
        c_lut_wr_wait:  cover (lut_wr && !hreadyout);
        c_lut_wr_first: cover (lut_wr && p_rb_first && hreadyout);
        c_lut_wr_free:  cover (lut_wr && hreadyout && !p_rb_first);
        c_lut_rd:       cover (rb_valid && sel_lut && !rb_wr && hreadyout && hready);
        c_lut_rd_b2b:   cover (rb_valid && sel_lut && hreadyout && hready && hsel && htrans[1] && haddr[11]);
        c_err:          cover (hresp && hreadyout && hready);
        c_vw_hold:      cover (hold_ref && !vw_pend_nxt);
        c_vw_cont:      cover (st_q && vw_pend && rb_valid && hreadyout);
        if (BDI_EXT_EN != 0)
            c_bdi_wait: cover (rb_valid && sel_bdi && !hreadyout);
    end

endmodule

`default_nettype wire

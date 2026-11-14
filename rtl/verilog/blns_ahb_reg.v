//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_ahb_reg
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_ahb_reg.v
// Module Description : Register-port AHB-Lite subordinate: word-only access,
//                      optional privilege check, decode onto the internal
//                      register bus (valid held until the selected slave is
//                      ready), HREADYOUT from a flop. A transfer starts on the
//                      register bus only once the VRAM window's posted write
//                      is made (vw_pend_i): every register effect follows the
//                      window writes before it.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_ahb_reg #(
    parameter               GPU_EN           = 1,       // GPU present
    parameter               LUT_EN           = 1,       // programmable LUT present
    parameter               PRIV_CHECK_EN    = 0,       // deny U-mode accesses
    parameter               BDI_EXT_EN       = 0,       // BDI window answered by an external driver (DIF_TYPE = 0)
    parameter               ASYNC_RST_EN     = 1'b1     // 1=async active-low reset, 0=synchronous reset
) (
    input  wire             hclk_i,                     // clock
    input  wire             hresetn_i,                  // active-low reset

// AHB-Lite subordinate
    input  wire             hsel_i,                     // select
    input  wire      [11:0] haddr_i,                    // byte address (4 KB window)
    input  wire       [1:0] htrans_i,                   // transfer type
    input  wire             hwrite_i,                   // write
    input  wire       [2:0] hsize_i,                    // transfer size
    input  wire       [3:0] hprot_i,                    // protection (hprot[1] = privileged)
    input  wire             hsmode_i,                   // aRVern S-mode sideband
    input  wire             hready_i,                   // bus ready in
    input  wire      [31:0] hwdata_i,                   // write data
    output wire      [31:0] hrdata_o,                   // read data
    output wire             hreadyout_o,                // ready out
    output wire             hresp_o,                    // response (1 = ERROR)
    output wire             active_o,                   // address or data phase in progress

// VRAM window's posted write (blns_ahb_vram)
    input  wire             vw_pend_i,                  // a window write posted, not yet made
    input  wire             vw_pend_nxt_i,              // next cycle's vw_pend_i

// Internal register bus (common)
    output wire             rb_valid_o,                 // transfer pending
    output wire             rb_wr_o,                    // 1 = write
    output wire      [11:2] rb_addr_o,                  // word address
    output wire      [31:0] rb_wdata_o,                 // write data
    output wire             rb_wr_nxt_o,                // next cycle's rb_wr_o
    output wire      [11:2] rb_addr_nxt_o,              // next cycle's rb_addr_o

// Internal register bus (per slave)
    output wire             rb_sel_regs_o,              // 0x000-0x07C
    output wire             rb_sel_gpu_o,               // 0x100-0x11C (0x11C reads 0 in blns_gpu)
    output wire             rb_sel_bdi_o,               // 0x180-0x27C, two 32-word pages
    output wire             rb_sel_lut_o,               // 0x800-0xFFC
// (the register, GPU and built-in BDI windows complete in the first data-phase
// cycle: no ready input)
    input  wire      [31:0] rb_rdata_regs_i,
    input  wire      [31:0] rb_rdata_gpu_i,
    input  wire      [31:0] rb_rdata_bdi_i,
    input  wire             rb_ready_bdi_i,             // used with BDI_EXT_EN = 1 only
    input  wire      [31:0] rb_rdata_lut_i,
    input  wire             rb_ready_nxt_lut_i          // next cycle's LUT ready, for a LUT transfer then
);


//=============================================================================
// 1)  ADDRESS PHASE
//=============================================================================

localparam        [2:0] HSIZE_WORD = 3'b010;

wire                    aph_valid  =  hsel_i & hready_i & htrans_i[1];
wire                    aph_err    =  (hsize_i != HSIZE_WORD) | ((PRIV_CHECK_EN != 0) & ~hprot_i[1]);


//=============================================================================
// 2)  DATA PHASE
//=============================================================================

// Load on an address phase, clear when the bus moves on without one, hold
// while the bus is stalled (aph_valid includes hready_i).
wire                    dph_en     =  hready_i;

wire                    dph_valid;
wire                    dph_write;
wire                    dph_err;
wire             [11:2] dph_addr;

arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_dph_valid (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(aph_valid),                  .q_o(dph_valid));
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_dph_write (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(aph_valid & hwrite_i),       .q_o(dph_write));
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_dph_err (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(aph_valid & aph_err),        .q_o(dph_err));
arv_ipdff #(.WIDTH(10), .ARST_EN(ASYNC_RST_EN)) u_dph_addr (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(haddr_i[11:2] & {10{aph_valid}}), .q_o(dph_addr));

// The same flops one cycle ahead (their next state), for the registered
// HREADYOUT
wire                    dph_valid_nxt = dph_en ?  aph_valid                     : dph_valid;
wire                    dph_write_nxt = dph_en ? (aph_valid & hwrite_i)         : dph_write;
wire                    dph_err_nxt   = dph_en ? (aph_valid & aph_err)          : dph_err;
wire             [11:2] dph_addr_nxt  = dph_en ? (haddr_i[11:2] & {10{aph_valid}}) : dph_addr;

// A transfer starts on the register bus once no window write is posted, then
// runs to its end (an external BDI driver's or the LUT's handshake is never
// interrupted): dph_go, the data phase has started and not ended.
wire                    dph_go;
wire                    rb_go      =  ~vw_pend_i | dph_go;

// Clock request: a presented transfer counts even while the fabric holds
// hready low, keeping hready off the clock-gate enable path.
assign                  active_o   =  (hsel_i & htrans_i[1]) | dph_valid;


//=============================================================================
// 3)  DECODE
//=============================================================================

wire                    dec_regs   =  (dph_addr[11:7] == 5'b00000);
wire                    dec_gpu    =  (dph_addr[11:5] == 7'h08) & (GPU_EN  != 0);
wire                    dec_bdi    =  (dph_addr[11:7] == 5'b00011) | (dph_addr[11:7] == 5'b00100);   // 0x180-0x27C, two pages
wire                    dec_lut    =   dph_addr[11]             & (LUT_EN  != 0);

assign                  rb_valid_o    =  dph_valid & ~dph_err & rb_go;

wire                    dph_go_nxt    = ~dph_en & rb_valid_o;
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_dph_go (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(dph_go_nxt), .q_o(dph_go));
assign                  rb_wr_o       =  dph_write;
assign                  rb_addr_o     =  dph_addr;
assign                  rb_wdata_o    =  hwdata_i;

assign                  rb_sel_regs_o =  dec_regs;
assign                  rb_sel_gpu_o  =  dec_gpu;
assign                  rb_sel_bdi_o  =  dec_bdi;
assign                  rb_sel_lut_o  =  dec_lut;

assign                  rb_wr_nxt_o   =  dph_write_nxt;
assign                  rb_addr_nxt_o =  dph_addr_nxt;

assign                  hrdata_o   =  ({32{dec_regs }} & rb_rdata_regs_i ) |
                                      ({32{dec_gpu  }} & rb_rdata_gpu_i  ) |
                                      ({32{dec_bdi  }} & rb_rdata_bdi_i  ) |
                                      ({32{dec_lut  }} & rb_rdata_lut_i  );


//=============================================================================
// 4)  RESPONSE
//=============================================================================

// Two-cycle ERROR: HREADYOUT low then high, HRESP high for both cycles.
wire                    error_resp      =  dph_valid & dph_err;
wire                    error_resp_done;
wire                    error_resp_done_nxt = error_resp & ~error_resp_done;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_error_resp_done (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(error_resp_done_nxt), .q_o(error_resp_done));

// HREADYOUT is a flop, loaded with the ready of the next cycle's data phase
// decoded from the next state of the flops that ready depends on: the same
// wait states as a ready decoded in its own cycle. The register, GPU and
// built-in BDI windows complete in their first cycle, the LUT window when
// blns_lut says so (rb_ready_nxt_lut_i: the LUT arbiter's next state and the
// backend's next request), an ERROR in its second cycle. With an external BDI
// driver (BDI_EXT_EN), bdi_reg_ready_i answers the BDI window in its own
// cycle, selected by a flop. A transfer not started, a window write being
// posted, waits.
wire                    error_resp_nxt = dph_valid_nxt & dph_err_nxt;
wire                    rb_pend_nxt    = dph_valid_nxt & ~dph_err_nxt;
wire                    rb_hold_nxt    = rb_pend_nxt & vw_pend_nxt_i & ~dph_go_nxt;
wire                    rb_valid_nxt   = rb_pend_nxt & ~rb_hold_nxt;
wire                    dec_lut_nxt    =  dph_addr_nxt[11]            & (LUT_EN != 0);
wire                    lut_wait_nxt   =  rb_valid_nxt & dec_lut_nxt & ~rb_ready_nxt_lut_i;
wire                    hready_nxt     =  error_resp_nxt ? error_resp_done_nxt : ~(lut_wait_nxt | rb_hold_nxt);
wire                    hready_q;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_hready (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(hready_nxt), .q_o(hready_q));

generate
    if (BDI_EXT_EN != 0) begin : g_bdi_ext
        wire            dec_bdi_nxt = (dph_addr_nxt[11:7] == 5'b00011) | (dph_addr_nxt[11:7] == 5'b00100);
        wire            bdi_ext_nxt = rb_valid_nxt & dec_bdi_nxt;
        wire            bdi_ext;
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_bdi_ext (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(bdi_ext_nxt), .q_o(bdi_ext));
        assign          hreadyout_o = bdi_ext ? rb_ready_bdi_i : hready_q;
    end else begin : g_bdi_int
        assign          hreadyout_o = hready_q;
        wire            rb_ready_bdi_unused = rb_ready_bdi_i;
    end
endgenerate

assign                  hresp_o     =  error_resp;


//=============================================================================
// 5)  UNUSED INPUTS
//=============================================================================

// Word-only port: the byte offset is irrelevant once hsize is checked; the
// privilege check needs only hprot[1] (U-mode or not), so hsmode is unused.
wire              [1:0] haddr_unused  = haddr_i[1:0];
wire                    htrans_unused = htrans_i[0];
wire              [3:0] hprot_unused  = hprot_i;          // hprot[1] is only read with PRIV_CHECK_EN = 1
wire                    hsmode_unused = hsmode_i;

endmodule // blns_ahb_reg

`default_nettype wire

//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_port
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_port.v
// Module Description : Register-port AHB front end:
//                      - every non-word size (byte at each lane, half-word,
//                        hsize 3..7) in every region gets the two-cycle ERROR
//                        (hreadyout 0 then 1, hresp 1 both cycles) with no
//                        side effect (no register change, no GPU push, no LUT
//                        or VRAM macro access, no BDI register select);
//                      - PRIV_CHECK_EN: U-mode (hprot[1] = 0, with or
//                        without hsmode) gets the ERROR everywhere, S/M OKAY;
//                        without it U-mode works;
//                      - unmapped offsets (reserved ranges, absent GPU / LUT,
//                        the GPU's reserved 0x11C): OKAY, zero wait, read 0,
//                        no macro / BDI / GPU access, every known register
//                        value intact afterwards (no decode aliasing);
//                      - pipelined back-to-back transfers (write -> read of
//                        the same register, LUT and BDI wait states, ERROR
//                        followed by a kept or a cancelled transfer);
//                      - htrans IDLE / BUSY and hsel = 0 ignored; an address
//                        phase held under fabric wait states is taken once;
//                      - DIF_TYPE = 0: the RB protocol on the BDI window seen
//                        directly (select in the data phase, address / write
//                        / data stable until ready, one completion, hreadyout
//                        low exactly while pending, read data returned);
//                      - address bits [1:0] ignored: a word access at
//                        +1..+3 reaches the aligned word (OKAY, zero wait),
//                        on global registers, the LUT and the BDI window;
//                      - every global register answers with zero wait
//                        states.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

integer     p_i, p_k, p_n0, p_err0;
reg  [31:0] p_rd, p_v;
reg  [31:0] p_regions [0:31];
integer     p_nreg;
reg  [31:0] k_addr [0:63];
reg  [31:0] k_exp  [0:63];
integer     k_n;
localparam [31:0] P_PA_MASK = ((VRAM_AW + 5) >= 32) ? 32'hFFFF_FFFF : ((32'h1 << (VRAM_AW + 5)) - 1);

// Load a known value into a register and remember its expected read-back
task k_put;
   input [31:0] addr;
   input [31:0] wval;
   input [31:0] exp;
   begin
      reg_wr(addr, wval);
      k_addr[k_n] = addr; k_exp[k_n] = exp; k_n = k_n + 1;
   end
endtask

// Macro / slave activity monitors
integer     p_lut_acc;      // LUT macro accesses
integer     p_vram_acc;     // VRAM macro accesses
always @(posedge hclk) if (hresetn_d === 1'b1) begin
   if (lut_cen  === 1'b0) p_lut_acc  = p_lut_acc + 1;
   if (vram_cen === 1'b0) p_vram_acc = p_vram_acc + 1;
end

// BDI register-window slave model (DIF_TYPE = 0)
integer     bs_wait;        // wait states inserted per transfer
integer     bs_cnt;
integer     bs_done;        // completions
integer     bs_unstable;    // addr / wr / wdata changed while pending
integer     bs_sel_cycles;
reg   [4:0] bs_addr  [0:63];
reg         bs_wr    [0:63];
reg  [31:0] bs_wdata [0:63];
reg   [4:0] bs_a0;
reg         bs_w0;
reg  [31:0] bs_d0;
reg         bs_pend;
initial begin
   p_lut_acc = 0; p_vram_acc = 0;
   bs_wait = 0; bs_cnt = 0; bs_done = 0; bs_unstable = 0; bs_sel_cycles = 0; bs_pend = 1'b0;
end

function [31:0] bs_rdata;
   input [4:0] a;
   begin
      // every bit of bdi_reg_rdata_i takes both values over the offsets used
      bs_rdata = ({27'h0, a} + 32'h1) * 32'h9E37_79B9 ^ {a, 2'b01, ~a, a, 3'b110, ~a, a, 2'b10};
   end
endfunction

always @(posedge hclk)
  if ((hresetn_d === 1'b1) && (DIF_TYPE == 0)) begin
     if (bdi_reg_sel === 1'b1) begin
        bs_sel_cycles = bs_sel_cycles + 1;
        if (!bs_pend) begin
           bs_pend = 1'b1; bs_a0 = bdi_reg_addr; bs_w0 = bdi_reg_wr; bs_d0 = bdi_reg_wdata;
        end else if ((bdi_reg_addr !== bs_a0) || (bdi_reg_wr !== bs_w0) || (bs_w0 && (bdi_reg_wdata !== bs_d0)))
           bs_unstable = bs_unstable + 1;
        if (bdi_reg_ready_d === 1'b1) begin
           if (bs_done < 64) begin
              bs_addr[bs_done] = bs_a0; bs_wr[bs_done] = bs_w0; bs_wdata[bs_done] = bs_d0;
           end
           bs_done = bs_done + 1;
           bs_pend = 1'b0;
           bs_cnt  = 0;
           bdi_reg_ready_drv <= (bs_wait == 0);
        end else begin
           bs_cnt = bs_cnt + 1;
           if (bs_cnt >= bs_wait) begin
              bdi_reg_ready_drv <= 1'b1;
              bdi_reg_rdata_drv <= bs_rdata(bs_a0);
           end
        end
     end else if (bs_wait == 0) begin
        bdi_reg_ready_drv <= 1'b1;
     end
  end

// rdata for a zero-wait transfer must be valid in the first cycle: drive it
// from the live address
always @(bdi_reg_addr or bdi_reg_sel)
  if ((DIF_TYPE == 0) && (bs_wait == 0)) bdi_reg_rdata_drv = bs_rdata(bdi_reg_addr);

initial
   begin
      $display(" ===============================================");
      $display("|          REGS: REGISTER PORT PROTOCOL         |");
      $display(" ===============================================");
      @(posedge reset_done);

      //------------------------------------------------------------------
      // Known state: values that an erroneous access would corrupt
      //------------------------------------------------------------------
      reg_wr(CTRL,      (GPU_EN != 0) ? 32'h0000_0013 : 32'h0000_0003);
      reg_wr(IRQ_EN,    32'h0000_00A5);
      reg_wr(DISP_SIZE, 32'h0004_0008);
      if (LUT_EN != 0) begin
         reg_wr(LUT_BASE + 4*3,   32'h0012_3456);
         reg_wr(LUT_BASE + 32'h400 + 4*3, 32'h0065_4321);
      end
      if (HAS_8080 || HAS_SPI) reg_wr(DIF_SYNC, 32'h0001_0123);

      p_regions[0]  = 32'h000; p_regions[1]  = CTRL;    p_regions[2]  = IRQ_FLAG; p_regions[3]  = 32'h07C;
      p_regions[4]  = 32'h080; p_regions[5]  = 32'h08C; p_regions[6]  = 32'h0A0;  p_regions[7]  = 32'h0A4;
      p_regions[8]  = 32'h0C0; p_regions[9]  = 32'h100; p_regions[10] = 32'h104;  p_regions[11] = 32'h108;
      p_regions[12] = 32'h120; p_regions[13] = 32'h17C; p_regions[14] = 32'h180;  p_regions[15] = 32'h184;
      p_regions[16] = 32'h1FC; p_regions[17] = 32'h200; p_regions[18] = 32'h7FC;  p_regions[19] = 32'h800;
      p_regions[20] = 32'h80C; p_regions[21] = 32'hC0C; p_regions[22] = 32'hFFC;  p_regions[23] = 32'h020;
      p_nreg = 24;

      //------------------------------------------------------------------
      // Non-word sizes: two-cycle ERROR in every region, no side effect
      //------------------------------------------------------------------
      repeat (3) @(posedge free_clk);
      p_lut_acc = 0; p_vram_acc = 0; p_n0 = bs_done; p_err0 = bs_sel_cycles;
      for (p_k = 0; p_k < 2; p_k = p_k + 1) begin            // pass 0: reads, pass 1: writes
         rp_clear;
         for (p_i = 0; p_i < p_nreg; p_i = p_i + 1) begin
            rp_add(p_regions[p_i] + 0, p_k, 3'b000, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
            rp_add(p_regions[p_i] + 1, p_k, 3'b000, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 1);
            rp_add(p_regions[p_i] + 2, p_k, 3'b000, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
            rp_add(p_regions[p_i] + 3, p_k, 3'b000, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
            rp_add(p_regions[p_i] + 0, p_k, 3'b001, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 2);
            rp_add(p_regions[p_i] + 2, p_k, 3'b001, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
            rp_add(p_regions[p_i] + 0, p_k, 3'b011, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
            rp_add(p_regions[p_i] + 0, p_k, 3'b100, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 1);
            rp_add(p_regions[p_i] + 0, p_k, 3'b101, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b11, 0);
            rp_add(p_regions[p_i] + 0, p_k, 3'b110, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
            rp_add(p_regions[p_i] + 0, p_k, 3'b111, 32'hFFFF_FFFF, SUPERVISOR, HART_MASTER, 2'b10, 0);
         end
         rp_run;
         for (p_i = 0; p_i < rp_n; p_i = p_i + 1)
            rp_chk(p_i, ERROR, 32'h0, 32'h0, 1);
      end
      repeat (3) @(posedge free_clk);
      if (p_lut_acc  != 0) tb_error("LUT macro accessed by an ERROR transfer");
      if (p_vram_acc != 0) tb_error("VRAM macro accessed by an ERROR transfer");
      if ((DIF_TYPE == 0) && ((bs_done != p_n0) || (bs_sel_cycles != p_err0)))
         tb_error("bdi_reg_sel_o asserted by an ERROR transfer");
      // no side effect
      reg_rd(CTRL,      (GPU_EN != 0) ? 32'h0000_0013 : 32'h0000_0003);
      reg_rd(IRQ_EN,    32'h0000_00A5);
      reg_rd(IRQ_FLAG,  32'h0);
      reg_rd(DISP_SIZE, 32'h0004_0008);
      if (GPU_EN != 0)  reg_rd_mask(GPU_STAT, 32'h0001_0000, 32'h00C3_FF00);   // EMPTY, USED 0, no ERR
      if (LUT_EN != 0) begin
         reg_rd(LUT_BASE + 4*3, 32'h0012_3456);
         if (LUT_BANKS == 2) reg_rd(LUT_BASE + 32'h400 + 4*3, 32'h0065_4321);
      end
      if (HAS_8080 || HAS_SPI) reg_rd(DIF_SYNC, 32'h0001_0123);
      $display("OK:    non-word accesses: ERROR in every region, no side effect");

      //------------------------------------------------------------------
      // Privilege
      //------------------------------------------------------------------
      repeat (3) @(posedge free_clk);
      p_lut_acc = 0; p_vram_acc = 0; p_n0 = bs_done; p_err0 = bs_sel_cycles;
      rp_clear;
      for (p_i = 0; p_i < p_nreg; p_i = p_i + 1) begin
         rp_add(p_regions[p_i], 1'b1, 3'b010, 32'hFFFF_FFFF, USER,  HART_MASTER, 2'b10, 0);
         rp_add(p_regions[p_i], 1'b0, 3'b010, 32'h0,        USER,  HART_MASTER, 2'b10, 0);
         rp_add(p_regions[p_i], 1'b1, 3'b010, 32'hFFFF_FFFF, 2'b10, HART_MASTER, 2'b10, 0);  // hprot[1]=0, hsmode=1
         rp_add(p_regions[p_i], 1'b0, 3'b010, 32'h0,        2'b10, HART_MASTER, 2'b10, 0);
      end
      if (PRIV_CHECK_EN != 0) begin
         rp_run;
         for (p_i = 0; p_i < rp_n; p_i = p_i + 1)
            rp_chk(p_i, ERROR, 32'h0, 32'h0, 1);
         repeat (3) @(posedge free_clk);
         if (p_lut_acc != 0 || p_vram_acc != 0) tb_error("macro accessed by a U-mode ERROR transfer");
         if ((DIF_TYPE == 0) && (bs_sel_cycles != p_err0)) tb_error("bdi_reg_sel_o asserted by a U-mode transfer");
         reg_rd(CTRL,      (GPU_EN != 0) ? 32'h0000_0013 : 32'h0000_0003);
         reg_rd(IRQ_EN,    32'h0000_00A5);
         reg_rd(DISP_SIZE, 32'h0004_0008);
         if (GPU_EN != 0)  reg_rd_mask(GPU_STAT, 32'h0001_0000, 32'h00C3_FF00);
         if (LUT_EN != 0)  reg_rd(LUT_BASE + 4*3, 32'h0012_3456);
         if (HAS_8080 || HAS_SPI) reg_rd(DIF_SYNC, 32'h0001_0123);
         // S and M allowed, U still refused on a mix
         rp_clear;
         rp_add(CTRL, 1'b1, 3'b010, 32'h0000_0001, SUPERVISOR, HART_MASTER, 2'b10, 0);
         rp_add(CTRL, 1'b0, 3'b010, 32'h0,         MACHINE,    HART_MASTER, 2'b10, 0);
         rp_add(CTRL, 1'b1, 3'b010, 32'h0000_0002, USER,       HART_MASTER, 2'b10, 0);
         rp_add(CTRL, 1'b0, 3'b010, 32'h0,         SUPERVISOR, HART_MASTER, 2'b10, 0);
         rp_run;
         rp_chk(0, OK,    32'h0, 32'h0, -1);
         rp_chk(1, OK,    32'h0000_0001, 32'hFFFF_FFFF, -1);
         rp_chk(2, ERROR, 32'h0, 32'h0, 1);
         rp_chk(3, OK,    32'h0000_0001, 32'hFFFF_FFFF, -1);
      end else begin
         rp_clear;
         rp_add(CTRL, 1'b1, 3'b010, 32'h0000_0001, USER, HART_MASTER, 2'b10, 0);
         rp_add(CTRL, 1'b0, 3'b010, 32'h0,         USER, HART_MASTER, 2'b10, 0);
         rp_add(IRQ_EN, 1'b0, 3'b010, 32'h0,       2'b10, HART_MASTER, 2'b10, 0);
         rp_run;
         rp_chk(0, OK, 32'h0, 32'h0, -1);
         rp_chk(1, OK, 32'h0000_0001, 32'hFFFF_FFFF, -1);
         rp_chk(2, OK, 32'h0000_00A5, 32'hFFFF_FFFF, -1);
      end
      reg_wr(CTRL, (GPU_EN != 0) ? 32'h0000_0013 : 32'h0000_0003);
      $display("OK:    privilege checks done (PRIV_CHECK_EN = %0d)", PRIV_CHECK_EN);

      //------------------------------------------------------------------
      // Unmapped offsets: OKAY, zero wait, read 0, write ignored
      //------------------------------------------------------------------
      // known non-reset values everywhere, re-read after the sweeps (aliasing)
      k_n = 0;
      k_put(CTRL,       (GPU_EN != 0) ? 32'h0000_0013 : 32'h0000_0003, (GPU_EN != 0) ? 32'h0000_0013 : 32'h0000_0003);
      k_put(IRQ_EN,     32'h0000_00A5, 32'h0000_00A5);
      k_put(DISP_SIZE,  32'h0004_0008, 32'h0004_0008);
      k_put(DISP_CFG,   32'h0000_0005, 32'h0000_0005);
      k_put(FRAME_CNT,  32'h0000_1357, 32'h0000_1357);
      k_put(REFRESH,    32'h0000_ABC0, 32'h0000_ABC0);
      k_put(FRAME_SEL,  32'h0000_0001, (FRAME_NR > 1) ? 32'h11 : 32'h0);   // [5:4]: latched (no refresh)
      k_put(DBG_CTRL,   32'h0000_0002, 32'h0000_0002);
      for (p_i = 0; p_i < 4; p_i = p_i + 1)
         k_put(FRAME0_PTR + 4*p_i, 32'h0111_1111 * (p_i + 1), (p_i < FRAME_NR) ? ((32'h0111_1111 * (p_i + 1)) & P_PA_MASK) : 32'h0);
      k_put(LUT_CFG,    32'h0000_5A30, 32'h0000_5A30);
      if (LUT_EN != 0) begin
         k_put(LUT_BASE + 4*0,   32'h0010_2030, 32'h0010_2030);
         k_put(LUT_BASE + 4*255, 32'h0040_5060, 32'h0040_5060);
         k_put(LUT_BASE + 4*256, 32'h0070_8090, (LUT_BANKS == 2) ? 32'h0070_8090 : 32'h0);
         k_put(LUT_BASE + 4*511, 32'h00A0_B0C0, (LUT_BANKS == 2) ? 32'h00A0_B0C0 : 32'h0);
      end
      if (HAS_8080 || HAS_SPI) k_put(DIF_SYNC, 32'h0001_0123, 32'h0001_0123);
      if (GPU_EN != 0) k_put(GPU_FIFO_LOW, 32'h0000_0003, 32'h0000_0003);
      for (p_i = 0; p_i < k_n; p_i = p_i + 1) reg_rd(k_addr[p_i], k_exp[p_i]);

      repeat (3) @(posedge free_clk);
      p_lut_acc = 0; p_vram_acc = 0; p_n0 = bs_done;
      rp_clear;
      p_i = 32'h0C0; while (p_i < 32'h100) begin rp_w(p_i, 32'hFFFF_FFFF, 0); rp_r(p_i, 0); p_i = p_i + 4; end
      p_i = 32'h120; while (p_i < 32'h180) begin rp_w(p_i, 32'hFFFF_FFFF, 0); rp_r(p_i, 0); p_i = p_i + 4; end
      // (0x200-0x27C is the display driver's second page: dbi_regs / dpi_regs)
      p_i = 32'h280; while (p_i < 32'h400) begin rp_w(p_i, 32'hFFFF_FFFF, 0); rp_r(p_i, 0); p_i = p_i + 4; end
      rp_run;
      for (p_i = 0; p_i < rp_n; p_i = p_i + 1) rp_chk(p_i, OK, 32'h0, rp_wr[p_i] ? 32'h0 : 32'hFFFF_FFFF, 0);
      rp_clear;
      p_i = 32'h400; while (p_i < 32'h800) begin rp_w(p_i, 32'hFFFF_FFFF, 0); rp_r(p_i, 0); p_i = p_i + 8; end
      // reserved for new blocks 0x080-0x0BC; the GPU's reserved 0x11C,
      // or its whole page without a GPU
      for (p_i = 32'h080; p_i < 32'h0C0; p_i = p_i + 4) begin rp_w(p_i, 32'hFFFF_FFFF, 0); rp_r(p_i, 0); end
      for (p_i = (GPU_EN == 0) ? 32'h100 : 32'h11C; p_i < 32'h120; p_i = p_i + 4) begin rp_w(p_i, 32'hFFFF_FFFF, 0); rp_r(p_i, 0); end
      rp_run;
      for (p_i = 0; p_i < rp_n; p_i = p_i + 1) rp_chk(p_i, OK, 32'h0, rp_wr[p_i] ? 32'h0 : 32'hFFFF_FFFF, 0);
      if (LUT_EN == 0) begin
         for (p_k = 0; p_k < 2; p_k = p_k + 1) begin
            rp_clear;
            p_i = 32'h800 + 32'h400*p_k;
            while (p_i < 32'hC00 + 32'h400*p_k) begin rp_w(p_i, 32'hFFFF_FFFF, 0); rp_r(p_i, 0); p_i = p_i + 4; end
            rp_run;
            for (p_i = 0; p_i < rp_n; p_i = p_i + 1) rp_chk(p_i, OK, 32'h0, rp_wr[p_i] ? 32'h0 : 32'hFFFF_FFFF, 0);
         end
         repeat (3) @(posedge free_clk);
         if (p_lut_acc != 0) tb_error("LUT macro accessed with LUT_EN = 0");
      end
      repeat (3) @(posedge free_clk);
      if (p_lut_acc != 0)  tb_error("LUT macro accessed by an unmapped-offset sweep");
      if (p_vram_acc != 0) tb_error("VRAM macro accessed by an unmapped-offset sweep");
      if ((DIF_TYPE == 0) && (bs_done != p_n0)) tb_error("BDI window selected by an unmapped-offset sweep");
      if (GPU_EN != 0) reg_rd_mask(GPU_STAT, 32'h0001_0000, 32'h0041_FF00);
      for (p_i = 0; p_i < k_n; p_i = p_i + 1) reg_rd(k_addr[p_i], k_exp[p_i]);
      reg_wr(REFRESH, 32'h0);
      reg_wr(DBG_CTRL, 32'h0);
      $display("OK:    unmapped offsets RAZ/WI with zero wait, no aliasing");

      //------------------------------------------------------------------
      // Pipelined back-to-back transfers
      //------------------------------------------------------------------
      rp_clear;
      rp_w(CTRL,      32'h0000_0002, 0);           // 0
      rp_r(CTRL,      0);                          // 1  write -> read same register
      rp_w(DISP_CFG,  32'h0000_0005, 0);           // 2
      rp_w(FRAME_CNT, 32'h0000_1234, 0);           // 3  write -> write
      rp_r(DISP_CFG,  0);                          // 4
      rp_r(FRAME_CNT, 0);                          // 5  read -> read
      rp_w(FRAME_CNT, 32'h0000_4321, 0);           // 6  read -> write
      rp_r(FRAME_CNT, 0);                          // 7
      rp_add(CTRL, 1'b1, 3'b000, 32'h0000_0007, MACHINE, HART_MASTER, 2'b10, 0);  // 8 ERROR
      rp_w(DISP_CFG,  32'h0000_0003, 0);           // 9  kept after ERROR
      rp_r(DISP_CFG,  0);                          // 10
      rp_add(CTRL, 1'b0, 3'b001, 32'h0, MACHINE, HART_MASTER, 2'b10, 0);          // 11 ERROR
      rp_add(CTRL, 1'b1, 3'b001, 32'h7, MACHINE, HART_MASTER, 2'b10, 0);          // 12 ERROR after ERROR
      rp_r(CTRL,      0);                          // 13
      rp_add(CTRL, 1'b1, 3'b010, 32'h0000_0007, MACHINE, HART_MASTER, 2'b00, 0);  // 14 IDLE (hsel=1): ignored
      rp_add(CTRL, 1'b1, 3'b010, 32'h0000_0006, MACHINE, HART_MASTER, 2'b01, 0);  // 15 BUSY: ignored
      rp_r(CTRL,      0);                          // 16
      rp_add(CTRL, 1'b1, 3'b010, 32'h0000_0001, MACHINE, HART_MASTER, 2'b11, 0);  // 17 SEQ: a transfer
      rp_r(CTRL,      0);                          // 18
      rp_run;
      // global registers: zero wait states, back to back too
      rp_chk(0,  OK, 0, 0, 0);
      rp_chk(1,  OK, 32'h0000_0002, 32'hFFFF_FFEF, 0);
      rp_chk(2,  OK, 0, 0, 0);
      rp_chk(3,  OK, 0, 0, 0);
      rp_chk(4,  OK, 32'h0000_0005, 32'hFFFF_FFFF, 0);
      rp_chk(5,  OK, 32'h0000_1234, 32'hFFFF_FFFF, 0);
      rp_chk(6,  OK, 0, 0, 0);
      rp_chk(7,  OK, 32'h0000_4321, 32'hFFFF_FFFF, 0);
      rp_chk(8,  ERROR, 0, 0, 1);
      rp_chk(9,  OK, 0, 0, -1);
      rp_chk(10, OK, 32'h0000_0003, 32'hFFFF_FFFF, -1);
      rp_chk(11, ERROR, 0, 0, 1);
      rp_chk(12, ERROR, 0, 0, 1);
      rp_chk(13, OK, 32'h0000_0002, 32'hFFFF_FFEF, -1);
      rp_chk(14, OK, 0, 0, 0);
      rp_chk(15, OK, 0, 0, 0);
      rp_chk(16, OK, 32'h0000_0002, 32'hFFFF_FFEF, -1);
      rp_chk(17, OK, 0, 0, -1);
      rp_chk(18, OK, 32'h0000_0001, 32'hFFFF_FFEF, -1);

      // ERROR with the pipelined next transfer cancelled (IDLE in the 2nd cycle)
      rp_cancel_on_err = 1'b1;
      rp_clear;
      rp_w(DISP_CFG, 32'h0000_0000, 0);
      rp_add(DISP_CFG, 1'b1, 3'b000, 32'h0000_0007, MACHINE, HART_MASTER, 2'b10, 0); // ERROR
      rp_w(DISP_CFG, 32'h0000_0006, 0);                                              // cancelled
      rp_r(DISP_CFG, 0);
      rp_run;
      rp_cancel_on_err = 1'b0;
      rp_chk(0, OK, 0, 0, -1);
      rp_chk(1, ERROR, 0, 0, 1);
      if (!rp_cancelled[2]) tb_error("pipelined transfer after an ERROR not cancelled by the manager");
      rp_chk(3, OK, 32'h0, 32'hFFFF_FFFF, -1);

      // LUT (wait-stated) mixed back-to-back with globals
      if (LUT_EN != 0) begin
         rp_clear;
         rp_w(LUT_BASE + 4*5, 32'hAB11_2233, 0);   // 0
         rp_r(LUT_BASE + 4*5, 0);                  // 1  write -> read same entry
         rp_r(CTRL, 0);                            // 2
         rp_w(LUT_BASE + 4*6, 32'h0044_5566, 0);   // 3
         rp_w(LUT_BASE + 4*7, 32'h0077_8899, 0);   // 4
         rp_r(LUT_BASE + 4*6, 0);                  // 5
         rp_r(LUT_BASE + 4*7, 0);                  // 6
         rp_r(LUT_BASE + 4*5, 0);                  // 7
         rp_add(LUT_BASE + 4*5, 1'b1, 3'b000, 32'hFF, MACHINE, HART_MASTER, 2'b10, 0); // 8 ERROR
         rp_r(LUT_BASE + 4*5, 0);                  // 9
         rp_w(DISP_CFG, 32'h1, 0);                 // 10
         rp_r(LUT_BASE + 4*3, 0);                  // 11
         rp_run;
         rp_chk(0, OK, 0, 0, -1);
         rp_chk(1, OK, 32'h0011_2233, 32'hFFFF_FFFF, -1);
         rp_chk(2, OK, 32'h0000_0001, 32'h0000_0007, -1);
         rp_chk(3, OK, 0, 0, -1);
         rp_chk(4, OK, 0, 0, -1);
         rp_chk(5, OK, 32'h0044_5566, 32'hFFFF_FFFF, -1);
         rp_chk(6, OK, 32'h0077_8899, 32'hFFFF_FFFF, -1);
         rp_chk(7, OK, 32'h0011_2233, 32'hFFFF_FFFF, -1);
         rp_chk(8, ERROR, 0, 0, 1);
         rp_chk(9, OK, 32'h0011_2233, 32'hFFFF_FFFF, -1);
         rp_chk(10, OK, 0, 0, -1);
         rp_chk(11, OK, 32'h0012_3456, 32'hFFFF_FFFF, -1);
      end
      $display("OK:    pipelined transfers done");
      reg_wr(CTRL, (GPU_EN != 0) ? 32'h0000_0013 : 32'h0000_0003);

      //------------------------------------------------------------------
      // hsel = 0 with a NONSEQ write: not ours
      //------------------------------------------------------------------
      reg_wr(DISP_CFG, 32'h0000_0002);
      @(negedge free_clk);
      r_hsel = 1'b0; r_haddr = DISP_CFG; r_htrans = 2'b10; r_hwrite = 1'b1; r_hsize = 3'b010; r_hprot = 4'h3;
      @(posedge free_clk);
      r_htrans = 2'b00; r_hwrite = 1'b0; r_hwdata = 32'h0000_0005;
      @(posedge free_clk);
      reg_rd(DISP_CFG, 32'h0000_0002);

      //------------------------------------------------------------------
      // Address phase held under fabric wait states: taken exactly once
      //------------------------------------------------------------------
      if (GPU_EN != 0) begin
         @(negedge free_clk);
         r_force_stall = 1'b1;
         r_hsel = 1'b1; r_haddr = GPU_CMD; r_htrans = 2'b10; r_hwrite = 1'b1; r_hsize = 3'b010;
         r_hprot = 4'h3; r_hsmode = 1'b0; r_hmaster = HART_MASTER;
         repeat (4) @(negedge free_clk);
         r_force_stall = 1'b0;                     // address phase accepted at the next edge
         @(posedge free_clk);
         r_hsel = 1'b0; r_htrans = 2'b00; r_hwrite = 1'b0; r_hwdata = 32'h0000_0000;   // invalid opcode 0
         @(negedge free_clk);
         while (r_hready !== 1'b1) @(negedge free_clk);
         @(posedge free_clk);
         repeat (4) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, 32'h0040_0100, 32'h0040_FF00);       // USED 1, ERR
         reg_wr(GPU_CTRL, 32'h0000_0001);                          // CLEAR_ERR
         reg_rd_mask(GPU_STAT, 32'h0001_0000, 32'h0041_FF00);
      end
      if (DIF_TYPE == 0) begin
         p_n0 = bs_done;
         @(negedge free_clk);
         r_force_stall = 1'b1;
         r_hsel = 1'b1; r_haddr = 32'h1A4; r_htrans = 2'b10; r_hwrite = 1'b1; r_hsize = 3'b010;
         r_hprot = 4'h3; r_hsmode = 1'b0; r_hmaster = HART_MASTER;
         repeat (3) @(negedge free_clk);
         r_force_stall = 1'b0;
         @(posedge free_clk);
         r_hsel = 1'b0; r_htrans = 2'b00; r_hwrite = 1'b0; r_hwdata = 32'hC001_D00D;
         @(negedge free_clk);
         while (r_hready !== 1'b1) @(negedge free_clk);
         @(posedge free_clk);
         repeat (2) @(posedge free_clk);
         if (bs_done != p_n0 + 1) begin
            $display("ERROR: stalled address phase gave %0d BDI completions / expected 1 %t", bs_done - p_n0, $time);
            error = error + 1;
         end else if ((bs_addr[p_n0] !== 5'h09) || (bs_wr[p_n0] !== 1'b1) || (bs_wdata[p_n0] !== 32'hC001_D00D))
            tb_error("stalled BDI write: wrong address / direction / data");
      end

      //------------------------------------------------------------------
      // RB protocol on the BDI window (DIF_TYPE = 0)
      //------------------------------------------------------------------
      if (DIF_TYPE == 0) begin
         for (p_k = 0; p_k < 4; p_k = p_k + 1) begin
            repeat (2) @(negedge free_clk);
            bs_wait = (p_k == 0) ? 0 : (p_k == 1) ? 1 : (p_k == 2) ? 3 : 7;
            bdi_reg_ready_drv = (bs_wait == 0);
            p_n0 = bs_done;
            rp_clear;
            rp_w(32'h180, 32'h1111_0000 + p_k, 0);    // 0
            rp_r(32'h184, 0);                          // 1
            rp_w(32'h1FC, 32'hFFFF_0000 + p_k, 0);    // 2
            rp_r(CTRL, 0);                             // 3
            rp_r(32'h1F8, 0);                          // 4
            rp_w(DISP_CFG, 32'h4, 0);                  // 5
            rp_w(32'h1C0, 32'hA5A5_5A5A, 0);          // 6
            rp_r(32'h1C0, 2);                          // 7
            rp_run;
            repeat (3) @(posedge free_clk);
            rp_chk(0, OK, 0, 0, bs_wait);
            rp_chk(1, OK, bs_rdata(5'h01), 32'hFFFF_FFFF, bs_wait);
            rp_chk(2, OK, 0, 0, bs_wait);
            rp_chk(3, OK, (GPU_EN != 0) ? 32'h13 : 32'h3, 32'hFFFF_FFFF, -1);
            rp_chk(4, OK, bs_rdata(5'h1E), 32'hFFFF_FFFF, bs_wait);
            rp_chk(5, OK, 0, 0, -1);
            rp_chk(6, OK, 0, 0, bs_wait);
            rp_chk(7, OK, bs_rdata(5'h10), 32'hFFFF_FFFF, bs_wait);
            if (bs_done != p_n0 + 6) begin
               $display("ERROR: BDI window: %0d completions / expected 6 (wait %0d) %t", bs_done - p_n0, bs_wait, $time);
               error = error + 1;
            end else begin
               if ((bs_addr[p_n0]   !== 5'h00) || (bs_wr[p_n0]   !== 1'b1) || (bs_wdata[p_n0]   !== (32'h1111_0000 + p_k))) tb_error("BDI completion 0 wrong");
               if ((bs_addr[p_n0+1] !== 5'h01) || (bs_wr[p_n0+1] !== 1'b0))                                            tb_error("BDI completion 1 wrong");
               if ((bs_addr[p_n0+2] !== 5'h1F) || (bs_wr[p_n0+2] !== 1'b1) || (bs_wdata[p_n0+2] !== (32'hFFFF_0000 + p_k))) tb_error("BDI completion 2 wrong");
               if ((bs_addr[p_n0+3] !== 5'h1E) || (bs_wr[p_n0+3] !== 1'b0))                                            tb_error("BDI completion 3 wrong");
               if ((bs_addr[p_n0+4] !== 5'h10) || (bs_wr[p_n0+4] !== 1'b1) || (bs_wdata[p_n0+4] !== 32'hA5A5_5A5A))    tb_error("BDI completion 4 wrong");
               if ((bs_addr[p_n0+5] !== 5'h10) || (bs_wr[p_n0+5] !== 1'b0))                                            tb_error("BDI completion 5 wrong");
            end
            if (bs_unstable != 0) tb_error("BDI window: address / direction / write data changed while pending");
         end
         reg_rd(DISP_CFG, 32'h4);
         bs_wait = 0;
         bdi_reg_ready_drv = 1'b1;
         $display("OK:    RB protocol on the BDI window");
      end

      //------------------------------------------------------------------
      // Address bits [1:0] ignored: a word access at +1..+3 is the aligned
      // word (OKAY, zero wait; the LUT keeps its own wait state)
      //------------------------------------------------------------------
      for (p_k = 1; p_k < 4; p_k = p_k + 1) begin
         rp_clear;
         rp_w(DISP_CFG  + p_k, 32'h0000_0010 + p_k, 0);            // 0
         rp_r(DISP_CFG  + p_k, 0);                                  // 1
         rp_w(FRAME_CNT + p_k, 32'h0000_7700 + p_k, 0);            // 2
         rp_r(FRAME_CNT,       0);                                  // 3 aligned read of the same word
         rp_r(BLNS_ID   + p_k, 0);                                  // 4
         rp_r(DISP_CFG,        0);                                  // 5
         rp_run;
         rp_chk(0, OK, 0, 0, 0);
         rp_chk(1, OK, 32'h0000_0010 | (p_k & 32'h7), 32'hFFFF_FFFF, 0);
         rp_chk(2, OK, 0, 0, 0);
         rp_chk(3, OK, 32'h0000_7700 + p_k, 32'hFFFF_FFFF, 0);
         rp_chk(4, OK, BLNS_VERSION_EXP, 32'hFFFF_FFFF, 0);
         rp_chk(5, OK, 32'h0000_0010 | (p_k & 32'h7), 32'hFFFF_FFFF, 0);
         // neighbours untouched
         reg_rd(FRAME_SEL, (FRAME_NR > 1) ? 32'h11 : 32'h0);
         reg_rd(DISP_SIZE, 32'h0004_0008);
         if (LUT_EN != 0) begin
            rp_clear;
            rp_w(LUT_BASE + 4*9 + p_k, 32'h0099_8870 + p_k, 0);
            rp_r(LUT_BASE + 4*9 + p_k, 0);
            rp_r(LUT_BASE + 4*10,      0);
            rp_run;
            rp_chk(0, OK, 0, 0, -1);
            rp_chk(1, OK, 32'h0099_8870 + p_k, 32'hFFFF_FFFF, -1);
            rp_chk(2, OK, 32'h0, 32'hFFFF_FFFF, -1);
         end
         if (DIF_TYPE == 0) begin
            p_n0 = bs_done;
            rp_clear;
            rp_w(32'h188 + p_k, 32'h5500_0000 + p_k, 0);
            rp_r(32'h18C + p_k, 0);
            rp_run;
            repeat (3) @(posedge free_clk);
            rp_chk(0, OK, 0, 0, 0);
            rp_chk(1, OK, bs_rdata(5'h03), 32'hFFFF_FFFF, 0);
            if (bs_done != p_n0 + 2) tb_error("unaligned BDI window access: wrong completion count");
            else if ((bs_addr[p_n0] !== 5'h02) || (bs_wr[p_n0] !== 1'b1) || (bs_wdata[p_n0] !== (32'h5500_0000 + p_k)) ||
                     (bs_addr[p_n0+1] !== 5'h03) || (bs_wr[p_n0+1] !== 1'b0))
               tb_error("unaligned BDI window access: not forwarded to the aligned word");
         end
      end
      $display("OK:    address bits [1:0] ignored on word accesses");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end

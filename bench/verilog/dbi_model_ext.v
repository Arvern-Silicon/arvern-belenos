//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    dbi_model_ext
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_model_ext.v
// Module Description : DBI driver verification extension (`included by the
//                      dbi_* stimulus files into tb_belenos). Adds, next to
//                      the ILI9341 panel models:
//                       - an 8080 and an SPI protocol monitor sampled on the
//                         falling edge of hclk (cycle counts against dbi_div,
//                         the CLK_DIV the test programmed, and dbi_rdiv, the
//                         read strobe's divider: RD_DIV, or CLK_DIV at 0),
//                       - an item log of everything the panels receive
//                         (phy, command / data / read, value, CS frame id,
//                         cycle), an expected-item builder (exp_*) and a
//                         checker (dbi_check_log),
//                       - scanline stepping: on each Get_Scanline (0x45)
//                         command the 8080 model's scanline takes the next
//                         value of scan_seq[], so the values read by a poll
//                         are stable and known,
//                       - register helpers for the DIF window.
//                      Panel TE is driven through the bench's lcd_te reg.
//                      The panel models hold 320 x 320 pixels (fb[y*W + x]):
//                      a landscape window with end columns >= 256 fits.
//----------------------------------------------------------------------------

localparam integer DBI_LOG_NR  = 65536;
localparam integer DBI_EXP_NR  = 65536;
localparam integer DBI_SEQ_NR  = 64;
localparam integer DBI_POLL_NR = 1024;
localparam integer DBI_MSG_MAX = 40;

localparam [1:0]   K_CMD  = 2'd0;
localparam [1:0]   K_DAT  = 2'd1;
localparam [1:0]   K_RD   = 2'd2;

localparam         PHY_8080 = 1'b0;
localparam         PHY_SPI  = 1'b1;

// DIF_STATUS bits
localparam [31:0]  ST_BUSY        = 32'h0000_0001;
localparam [31:0]  ST_CMD_PEND    = 32'h0000_0002;
localparam [31:0]  ST_PARAM_FULL  = 32'h0000_0004;
localparam [31:0]  ST_REFR_BUSY   = 32'h0000_0008;
localparam [31:0]  ST_WAIT_SYNC   = 32'h0000_0010;
localparam [31:0]  ST_DFILL_BUSY  = 32'h0000_0020;
localparam [31:0]  ST_DFILL_PEND  = 32'h0000_0040;
localparam [31:0]  ST_PARAM_OVFL  = 32'h0000_0080;
localparam [31:0]  ST_LEVEL       = 32'h0000_1F00;

integer            dbi_div;           // CLK_DIV programmed by the test
integer            dbi_rdiv;          // read strobe divider (RD_DIV, or CLK_DIV when 0)
integer            dbi_cyc;           // hclk cycle counter
integer            dbi_msg_nr;        // printed monitor errors

// Item log
reg                lg_phy  [0:DBI_LOG_NR-1];
reg          [1:0] lg_kind [0:DBI_LOG_NR-1];
reg         [15:0] lg_data [0:DBI_LOG_NR-1];
integer            lg_frame[0:DBI_LOG_NR-1];
integer            lg_cyc  [0:DBI_LOG_NR-1];
integer            lg_n;
integer            dbi_frame_id;      // CS falling edges seen on either PHY

// Expected items
reg                ex_phy  [0:DBI_EXP_NR-1];
reg          [1:0] ex_kind [0:DBI_EXP_NR-1];
reg         [15:0] ex_data [0:DBI_EXP_NR-1];
reg         [15:0] ex_mask [0:DBI_EXP_NR-1];
reg                ex_fnew [0:DBI_EXP_NR-1];
integer            ex_n;

// Scanline stepping
reg          [9:0] scan_seq [0:DBI_SEQ_NR-1];
integer            scan_seq_n;
integer            scan_seq_idx;
reg                scan_seq_en;
integer            poll_nr;           // 0x45 commands seen
reg          [9:0] poll_gts [0:DBI_POLL_NR-1];  // GTS read by each poll
integer            poll_rd_idx;
reg          [9:0] poll_cur;

// Statistics the tests read
integer            m8_wr_hi_max;      // longest WR high gap between strobes (cmd/param)
integer            m8_px_gap_bad;     // pixel-to-pixel periods != 2(div+1)
integer            m8_px_pairs;       // pixel-to-pixel periods checked
integer            ms_px_bounds;      // SPI pixel-byte boundaries checked
integer            ms_px_gap_bad;     // SPI pixel-byte bubbles
integer            m8_ta_n;           // read-to-write turnarounds measured
reg                m8_rd_pend;        // a read strobe rose, the bus not driven again yet
integer            m8_cs_lo_cyc;      // cycles with lcd_cs_n low (all time)
integer            ms_cs_lo_cyc;

integer            dbi_ii;

initial
  begin
     dbi_div       = 0;
     dbi_rdiv      = 0;
     dbi_cyc       = 0;
     dbi_msg_nr    = 0;
     lg_n          = 0;
     ex_n          = 0;
     dbi_frame_id  = 0;
     scan_seq_n    = 0;
     scan_seq_idx  = 0;
     scan_seq_en   = 1'b0;
     poll_nr       = 0;
     poll_rd_idx   = 0;
     poll_cur      = 10'd0;
     m8_wr_hi_max  = 0;
     m8_px_gap_bad = 0;
     m8_px_pairs   = 0;
     ms_px_bounds  = 0;
     ms_px_gap_bad = 0;
     m8_cs_lo_cyc  = 0;
     m8_ta_n       = 0;
     m8_rd_pend    = 1'b0;
     ms_cs_lo_cyc  = 0;
  end

task dbi_err;
   input [100*8-1:0] msg;
   begin
      if (dbi_msg_nr < DBI_MSG_MAX)
        $display("ERROR: %0s (cycle %0d) %t", msg, dbi_cyc, $time);
      dbi_msg_nr = dbi_msg_nr + 1;
      error      = error + 1;
   end
endtask

task dbi_log;
   input        phy;
   input  [1:0] kind;
   input [15:0] data;
   begin
      if (lg_n < DBI_LOG_NR) begin
         lg_phy[lg_n]   = phy;
         lg_kind[lg_n]  = kind;
         lg_data[lg_n]  = data;
         lg_frame[lg_n] = dbi_frame_id;
         lg_cyc[lg_n]   = dbi_cyc;
      end
      lg_n = lg_n + 1;
   end
endtask


//============================================================================
// 8080 protocol monitor
//============================================================================
reg                p8_cs, p8_wr, p8_rd, p8_dc, p8_oe;
reg         [15:0] p8_d;
reg         [15:0] p8_rd_val;
reg                m8_init;
integer            m8_lo_cnt;         // current WR / RD low length
integer            m8_last_rise;      // cycle of the last strobe rising edge
integer            m8_last_fall;      // cycle of the last WR falling edge
reg          [1:0] m8_last_kind;      // kind of the last strobe in this frame (3 = none)
reg                m8_last_px;        // last strobe was a RAMWR pixel
reg                m8_rd_oe_seen;     // oe went high since the last RD rise
reg          [7:0] m8_cmd;            // current command byte
integer            m8_cs_fall;
reg                m8_strobe_seen;
reg                m8_wr_dc;
reg         [15:0] m8_wr_d;
integer            m8_px_in_run;      // RAMWR pixels since 0x2C

initial
  begin
     m8_init       = 1'b0;
     m8_lo_cnt     = 0;
     m8_last_rise  = -1000;
     m8_last_fall  = -1000;
     m8_last_kind  = 2'd3;
     m8_last_px    = 1'b0;
     m8_rd_oe_seen = 1'b0;
     m8_cmd        = 8'h00;
     m8_cs_fall    = 0;
     m8_strobe_seen= 1'b0;
     m8_px_in_run  = 0;
  end

// Cycle counter: advanced on the rising edge, stable for both monitors
always @(posedge hclk)
  dbi_cyc <= dbi_cyc + 1;

always @(negedge hclk)
  begin
     if ((hresetn_d !== 1'b1) || (reset_done !== 1'b1))
       m8_init = 1'b0;
     else if (!m8_init) begin
        m8_init = 1'b1;
        p8_cs = lcd_cs_n; p8_wr = lcd_wr_n; p8_rd = lcd_rd_n; p8_dc = lcd_dc; p8_oe = lcd_d_oe; p8_d = lcd_d_out;
     end else begin
        if (lcd_cs_n === 1'b0) m8_cs_lo_cyc = m8_cs_lo_cyc + 1;
        if (spi_cs_n === 1'b0) ms_cs_lo_cyc = ms_cs_lo_cyc + 1;
        if ((lcd_cs_n === 1'b0) && (spi_cs_n === 1'b0))
          dbi_err("both PHYs assert CS at once");
        if (!HAS_8080) begin
           if ((lcd_cs_n !== 1'b1) || (lcd_wr_n !== 1'b1) || (lcd_rd_n !== 1'b1) ||
               (lcd_dc !== 1'b0) || (lcd_d_oe !== 1'b0) || (lcd_d_out !== 16'h0000))
             dbi_err("8080 pins of an absent 8080 PHY not at their idle level");
        end
        if (!HAS_SPI) begin
           if ((spi_cs_n !== 1'b1) || (spi_sck !== 1'b0) || (spi_mosi !== 1'b0) || (spi_dc !== 1'b0))
             dbi_err("SPI pins of an absent SPI PHY not at their idle level");
        end

        // CS edges
        if ((p8_cs === 1'b1) && (lcd_cs_n === 1'b0)) begin
           dbi_frame_id   = dbi_frame_id + 1;
           m8_cs_fall     = dbi_cyc;
           m8_last_kind   = 2'd3;
           m8_last_px     = 1'b0;
           m8_strobe_seen = 1'b0;
           if ((lcd_wr_n !== 1'b1) || (lcd_rd_n !== 1'b1))
             dbi_err("8080: strobe low in the CS falling cycle (no CS set-up)");
        end
        if ((p8_cs === 1'b0) && (lcd_cs_n === 1'b1)) begin
           if ((p8_wr !== 1'b1) || (p8_rd !== 1'b1))
             dbi_err("8080: CS released while a strobe is low");
           else if (m8_strobe_seen && (dbi_cyc - m8_last_rise < 1))
             dbi_err("8080: CS released in the strobe rising cycle (no CS hold)");
        end
        if (lcd_cs_n === 1'b1) begin
           if ((lcd_wr_n !== 1'b1) || (lcd_rd_n !== 1'b1))
             dbi_err("8080: WR or RD low while CS is high");
        end
        if ((lcd_wr_n === 1'b0) && (lcd_rd_n === 1'b0))
          dbi_err("8080: WR and RD low together");

        // WR
        if ((p8_wr === 1'b1) && (lcd_wr_n === 1'b0)) begin
           m8_lo_cnt = 1;
           m8_wr_dc  = lcd_dc;
           m8_wr_d   = lcd_d_out;
           if (lcd_d_oe !== 1'b1) dbi_err("8080: WR low with lcd_d_oe_o = 0");
           if (m8_last_kind == 2'd3) begin
              if (dbi_cyc - m8_cs_fall < dbi_div + 1)
                dbi_err("8080: CS lead before the first WR shorter than CLK_DIV+1");
           end else begin
              if (dbi_cyc - m8_last_rise < dbi_div + 1)
                dbi_err("8080: high phase between strobes shorter than CLK_DIV+1");
              if ((m8_last_kind != K_RD) && (dbi_cyc - m8_last_rise > m8_wr_hi_max) &&
                  !(m8_last_px && (m8_cmd == 8'h2C)))
                m8_wr_hi_max = dbi_cyc - m8_last_rise;
              // pixel to pixel: exact period from the second pixel of a run
              if ((m8_cmd == 8'h2C) && m8_last_px && (lcd_dc === 1'b1))
                m8_px_pairs = m8_px_pairs + 1;
              if ((m8_cmd == 8'h2C) && m8_last_px && (lcd_dc === 1'b1) &&
                  (dbi_cyc - m8_last_fall != 2*(dbi_div + 1))) begin
                 m8_px_gap_bad = m8_px_gap_bad + 1;
                 if (m8_px_gap_bad <= 4)
                   $display("INFO:  8080 pixel period %0d cycles (expected %0d) at cycle %0d",
                            dbi_cyc - m8_last_fall, 2*(dbi_div+1), dbi_cyc);
              end
           end
           m8_last_fall = dbi_cyc;
        end else if ((p8_wr === 1'b0) && (lcd_wr_n === 1'b0)) begin
           m8_lo_cnt = m8_lo_cnt + 1;
           if ((lcd_dc !== m8_wr_dc) || (lcd_d_out !== m8_wr_d))
             dbi_err("8080: D or D/CX changed while WR is low");
           if (lcd_d_oe !== 1'b1) dbi_err("8080: WR low with lcd_d_oe_o = 0");
        end else if ((p8_wr === 1'b0) && (lcd_wr_n === 1'b1)) begin
           if (m8_lo_cnt != dbi_div + 1)
             dbi_err("8080: WR low phase length != CLK_DIV+1");
           m8_last_rise   = dbi_cyc;
           m8_strobe_seen = 1'b1;
           if (m8_wr_dc === 1'b0) begin
              m8_cmd       = m8_wr_d[7:0];
              m8_last_kind = K_CMD;
              m8_last_px   = 1'b0;
              m8_px_in_run = 0;
              dbi_log(PHY_8080, K_CMD, m8_wr_d);
              if (m8_wr_d[7:0] == 8'h45) begin
                 if (scan_seq_en && (scan_seq_n > 0)) begin
                    u_lcd8080.scanline = scan_seq[(scan_seq_idx < scan_seq_n) ? scan_seq_idx : (scan_seq_n - 1)];
                    scan_seq_idx = scan_seq_idx + 1;
                 end
                 poll_rd_idx = 0;
              end
           end else begin
              m8_last_kind = K_DAT;
              m8_last_px   = (m8_cmd == 8'h2C);
              if (m8_cmd == 8'h2C) m8_px_in_run = m8_px_in_run + 1;
              dbi_log(PHY_8080, K_DAT, m8_wr_d);
           end
        end

        // RD
        if ((p8_rd === 1'b1) && (lcd_rd_n === 1'b0)) begin
           if (m8_last_kind == K_RD) begin
              if (dbi_cyc - m8_last_rise != 2*dbi_rdiv + 2)
                dbi_err("8080: RD high phase between reads != 2*RD_DIV+1 plus the turnaround cycle");
              if (m8_rd_oe_seen)
                dbi_err("8080: lcd_d_oe_o high between two reads");
           end else if (m8_last_kind != 2'd3) begin
              if (dbi_cyc - m8_last_rise < dbi_div + 1)
                dbi_err("8080: high phase before a read shorter than CLK_DIV+1");
           end else if (dbi_cyc - m8_cs_fall < dbi_div + 2)
              dbi_err("8080: CS lead before a first read shorter than CLK_DIV+2");
           m8_lo_cnt = 1;
           if (lcd_d_oe !== 1'b0) dbi_err("8080: RD low with lcd_d_oe_o = 1");
           if (p8_oe !== 1'b0) dbi_err("8080: data bus not released one cycle before RD falls");
        end else if ((p8_rd === 1'b0) && (lcd_rd_n === 1'b0)) begin
           m8_lo_cnt = m8_lo_cnt + 1;
           if (lcd_d_oe !== 1'b0) dbi_err("8080: RD low with lcd_d_oe_o = 1");
        end else if ((p8_rd === 1'b0) && (lcd_rd_n === 1'b1)) begin
           if (m8_lo_cnt != 2*dbi_rdiv + 1)
             dbi_err("8080: RD low phase length != 2*RD_DIV+1");
           m8_last_rise   = dbi_cyc;
           m8_last_kind   = K_RD;
           m8_last_px     = 1'b0;
           m8_strobe_seen = 1'b1;
           m8_rd_oe_seen  = 1'b0;
           dbi_log(PHY_8080, K_RD, p8_rd_val);
           if (m8_cmd == 8'h45) begin
              if (poll_rd_idx == 1) poll_cur[9:8] = p8_rd_val[1:0];
              if (poll_rd_idx == 2) begin
                 poll_cur[7:0] = p8_rd_val[7:0];
                 if (poll_nr < DBI_POLL_NR) poll_gts[poll_nr] = poll_cur;
                 poll_nr = poll_nr + 1;
              end
              poll_rd_idx = poll_rd_idx + 1;
           end
        end
        if ((lcd_rd_n === 1'b1) && (lcd_d_oe === 1'b1)) m8_rd_oe_seen = 1'b1;
        if ((p8_rd === 1'b0) && (lcd_rd_n === 1'b1)) m8_rd_pend = 1'b1;
        // Turnaround: the bus driven again exactly 2*RD_DIV+1 cycles after
        // the last RD rises
        if (m8_rd_pend && (lcd_d_oe === 1'b1)) begin
           m8_rd_pend = 1'b0;
           m8_ta_n    = m8_ta_n + 1;
           if (dbi_cyc - m8_last_rise != 2*dbi_rdiv + 1)
             dbi_err("8080: data bus driven again != 2*RD_DIV+1 cycles after the last RD rise");
        end

        p8_cs = lcd_cs_n; p8_wr = lcd_wr_n; p8_rd = lcd_rd_n; p8_dc = lcd_dc; p8_oe = lcd_d_oe; p8_d = lcd_d_out;
        p8_rd_val = lcd_d_in;
     end
  end


//============================================================================
// SPI protocol monitor
//============================================================================
reg                ps_cs, ps_sck, ps_mosi, ps_dc;
reg                ms_init;
integer            ms_hi_cnt;
integer            ms_last_rise;
integer            ms_last_fall;
integer            ms_cs_rise;
integer            ms_cs_rise_div;
integer            ms_bit;
reg          [7:0] ms_shift;
reg                ms_byte_dc;
reg          [7:0] ms_cmd;
reg                ms_last_byte_px;   // the previous byte of this frame was RAMWR data
reg                ms_any_edge;       // an SCK edge inside the current frame
integer            ms_hi_lo_bad;

initial
  begin
     ms_init        = 1'b0;
     ms_hi_cnt      = 0;
     ms_last_rise   = -1000;
     ms_last_fall   = -1000;
     ms_cs_rise     = -1000;
     ms_cs_rise_div = 0;
     ms_bit         = 0;
     ms_shift       = 8'h00;
     ms_cmd         = 8'h00;
     ms_last_byte_px= 1'b0;
     ms_any_edge    = 1'b0;
  end

always @(negedge hclk)
  begin
     if ((hresetn_d !== 1'b1) || (reset_done !== 1'b1))
       ms_init = 1'b0;
     else if (!ms_init) begin
        ms_init = 1'b1;
        ps_cs = spi_cs_n; ps_sck = spi_sck; ps_mosi = spi_mosi; ps_dc = spi_dc;
     end else begin
        // CS edges
        if ((ps_cs === 1'b1) && (spi_cs_n === 1'b0)) begin
           dbi_frame_id    = dbi_frame_id + 1;
           if (dbi_cyc - ms_cs_rise < 2*(ms_cs_rise_div + 1))
             dbi_err("SPI: CS high for less than one SCK period between frames");
           ms_bit          = 0;
           ms_last_byte_px = 1'b0;
           ms_any_edge     = 1'b0;
           if (spi_sck !== 1'b0) dbi_err("SPI: SCK high at the CS falling edge");
        end
        if ((ps_cs === 1'b0) && (spi_cs_n === 1'b1)) begin
           ms_cs_rise     = dbi_cyc;
           ms_cs_rise_div = dbi_div;
           if (ps_sck !== 1'b0)
             dbi_err("SPI: CS released while SCK is high");
           if (ms_bit != 0)
             dbi_err("SPI: CS released inside a byte");
           if (ms_any_edge && (dbi_cyc - ms_last_fall != dbi_div + 1))
             dbi_err("SPI: CS not held exactly one SCK low phase after the last edge");
        end
        if (spi_cs_n === 1'b1) begin
           if (spi_sck !== 1'b0) dbi_err("SPI: SCK not idle low while CS is high");
        end

        // SCK rising: sample (mode 0)
        if ((ps_sck === 1'b0) && (spi_sck === 1'b1) && (spi_cs_n === 1'b0)) begin
           if ((spi_mosi !== ps_mosi) || (spi_dc !== ps_dc))
             dbi_err("SPI: MOSI or DC changed in the SCK rising cycle (no set-up)");
           if (ms_any_edge) begin
              if (dbi_cyc - ms_last_fall < dbi_div + 1)
                dbi_err("SPI: SCK low phase shorter than CLK_DIV+1");
              if ((ms_bit != 0) && (dbi_cyc - ms_last_fall != dbi_div + 1))
                dbi_err("SPI: SCK low phase inside a byte != CLK_DIV+1");
              if ((ms_bit == 0) && ms_last_byte_px && (ms_cmd == 8'h2C) && (spi_dc === 1'b1))
                ms_px_bounds = ms_px_bounds + 1;
              if ((ms_bit == 0) && ms_last_byte_px && (ms_cmd == 8'h2C) && (spi_dc === 1'b1) &&
                  (dbi_cyc - ms_last_fall != dbi_div + 1)) begin
                 ms_px_gap_bad = ms_px_gap_bad + 1;
                 if (ms_px_gap_bad <= 4)
                   $display("INFO:  SPI pixel-byte bubble: low phase %0d cycles (expected %0d) at cycle %0d",
                            dbi_cyc - ms_last_fall, dbi_div+1, dbi_cyc);
              end
           end
           ms_any_edge = 1'b1;
           ms_hi_cnt   = 1;
           if (ms_bit == 0) ms_byte_dc = spi_dc;
           ms_shift    = {ms_shift[6:0], spi_mosi};
           ms_bit      = ms_bit + 1;
           ms_last_rise= dbi_cyc;
           if (ms_bit == 8) begin
              ms_bit = 0;
              if (ms_byte_dc === 1'b0) begin
                 ms_cmd          = ms_shift;
                 ms_last_byte_px = 1'b0;
                 dbi_log(PHY_SPI, K_CMD, {8'h00, ms_shift});
              end else begin
                 ms_last_byte_px = (ms_cmd == 8'h2C);
                 dbi_log(PHY_SPI, K_DAT, {8'h00, ms_shift});
              end
           end
        end else if ((ps_sck === 1'b1) && (spi_sck === 1'b1)) begin
           ms_hi_cnt = ms_hi_cnt + 1;
           if ((spi_mosi !== ps_mosi) || (spi_dc !== ps_dc))
             dbi_err("SPI: MOSI or DC changed while SCK is high");
        end else if ((ps_sck === 1'b1) && (spi_sck === 1'b0)) begin
           if (ms_hi_cnt != dbi_div + 1)
             dbi_err("SPI: SCK high phase != CLK_DIV+1");
           ms_last_fall = dbi_cyc;
        end

        ps_cs = spi_cs_n; ps_sck = spi_sck; ps_mosi = spi_mosi; ps_dc = spi_dc;
     end
  end


//============================================================================
// Expected items and log checker
//============================================================================
task exp_reset;
   begin
      ex_n = 0;
   end
endtask

task exp_item;
   input        phy;
   input  [1:0] kind;
   input [15:0] data;
   input [15:0] mask;
   input        fnew;
   begin
      if (ex_n < DBI_EXP_NR) begin
         ex_phy[ex_n]  = phy;
         ex_kind[ex_n] = kind;
         ex_data[ex_n] = data;
         ex_mask[ex_n] = mask;
         ex_fnew[ex_n] = fnew;
      end
      ex_n = ex_n + 1;
   end
endtask

// Command byte: 8080 {8'h00, cmd} on D[15:0]; SPI one byte with DC = 0
task exp_cmd;
   input        phy;
   input  [7:0] cmd;
   input        fnew;
   begin
      exp_item(phy, K_CMD, {8'h00, cmd}, (phy == PHY_8080) ? 16'hFFFF : 16'h00FF, fnew);
   end
endtask

// Software parameter: 8080 the 16-bit bus value; SPI its low byte
task exp_par;
   input        phy;
   input [15:0] val;
   begin
      if (phy == PHY_8080) exp_item(phy, K_DAT, val, 16'hFFFF, 1'b0);
      else                 exp_item(phy, K_DAT, {8'h00, val[7:0]}, 16'h00FF, 1'b0);
   end
endtask

// Hardware window parameter byte (only the byte lane D[7:0] is defined)
task exp_hwpar;
   input        phy;
   input  [7:0] val;
   begin
      exp_item(phy, K_DAT, {8'h00, val}, 16'h00FF, 1'b0);
   end
endtask

// RGB565 pixel: 8080 one strobe; SPI high byte then low byte
task exp_px;
   input        phy;
   input [15:0] px;
   begin
      if (phy == PHY_8080) exp_item(phy, K_DAT, px, 16'hFFFF, 1'b0);
      else begin
         exp_item(phy, K_DAT, {8'h00, px[15:8]}, 16'h00FF, 1'b0);
         exp_item(phy, K_DAT, {8'h00, px[7:0]},  16'h00FF, 1'b0);
      end
   end
endtask

// CASET (0, w-1) / PASET (0, h-1); SPI: one CS frame each
task exp_window;
   input        phy;
   input integer w;
   input integer h;
   input        fnew;
   reg   [15:0] ec;
   reg   [15:0] ep;
   begin
      ec = w - 1;
      ep = h - 1;
      exp_cmd(phy, 8'h2A, fnew);
      exp_hwpar(phy, 8'h00); exp_hwpar(phy, 8'h00); exp_hwpar(phy, ec[15:8]); exp_hwpar(phy, ec[7:0]);
      exp_cmd(phy, 8'h2B, (phy == PHY_SPI));
      exp_hwpar(phy, 8'h00); exp_hwpar(phy, 8'h00); exp_hwpar(phy, ep[15:8]); exp_hwpar(phy, ep[7:0]);
   end
endtask

// RGB888 -> RGB565 truncation
function [15:0] rgb565;
   input [23:0] rgb;
   begin
      rgb565 = {rgb[23:19], rgb[15:10], rgb[7:3]};
   end
endfunction

// DFILL: [window] 0x2C + w*h pixels of one colour
task exp_dfill;
   input        phy;
   input integer w;
   input integer h;
   input [23:0] rgb;
   input        hw;
   integer      kk;
   begin
      if (hw) exp_window(phy, w, h, 1'b1);
      exp_cmd(phy, 8'h2C, (phy == PHY_SPI) || !hw);
      for (kk = 0; kk < w*h; kk = kk + 1)
        exp_px(phy, rgb565(rgb));
   end
endtask

// Compare the log from index `from` with the expected items. Every logged
// item must match; frame boundaries must be where ex_fnew says.
task dbi_check_log;
   input integer from;
   input [40*8-1:0] what;
   integer      kk;
   integer      bad;
   integer      li;
   reg          is_new;
   begin
      bad = 0;
      tb_checks = tb_checks + 1;
      if (lg_n - from != ex_n) begin
         $display("ERROR: %0s -- panel received %0d items / expected %0d %t", what, lg_n - from, ex_n, $time);
         bad = bad + 1;
      end
      for (kk = 0; (kk < ex_n) && (from + kk < lg_n) && (bad < 6); kk = kk + 1) begin
         li     = from + kk;
         is_new = (li == from) ? 1'b1 : (lg_frame[li] != lg_frame[li-1]);
         if ((lg_phy[li] !== ex_phy[kk]) || (lg_kind[li] !== ex_kind[kk]) ||
             ((lg_data[li] & ex_mask[kk]) !== (ex_data[kk] & ex_mask[kk])) ||
             ((kk > 0) && (is_new !== ex_fnew[kk])) ||
             ((kk == 0) && (from > 0) && ex_fnew[kk] && (lg_frame[li] == lg_frame[li-1]))) begin
            $display("ERROR: %0s -- item %0d: phy %0d kind %0d data 0x%h newframe %0d / expected phy %0d kind %0d data 0x%h (mask 0x%h) newframe %0d %t",
                     what, kk, lg_phy[li], lg_kind[li], lg_data[li], is_new,
                     ex_phy[kk], ex_kind[kk], ex_data[kk], ex_mask[kk], ex_fnew[kk], $time);
            bad = bad + 1;
         end
      end
      if (bad != 0)
        error = error + 1;
      else
        $display("OK:    %0s -- %0d panel items as expected", what, ex_n);
   end
endtask


//============================================================================
// Register helpers
//============================================================================
// DIF_CFG write that also tells the monitors the clock dividers (RD_DIV 0:
// the read strobe follows CLK_DIV)
task dif_cfg_rd;
   input        phy_sel;
   input  [3:0] div;
   input  [3:0] rd_div;
   input        hw_win;
   input        lcd_on;
   input        lcd_rst;
   begin
      dbi_div  = div;
      dbi_rdiv = (rd_div != 4'h0) ? rd_div : div;
      reg_wr(DIF_CFG, {19'h0, hw_win, div, rd_div, 1'b0, phy_sel, lcd_rst, lcd_on});
   end
endtask

task dif_cfg;
   input        phy_sel;
   input  [3:0] div;
   input        hw_win;
   input        lcd_on;
   input        lcd_rst;
   begin
      dif_cfg_rd(phy_sel, div, 4'h0, hw_win, lcd_on, lcd_rst);
   end
endtask

// Wait until the engine is idle with nothing queued
task dif_wait_idle;
   input integer max_reads;
   begin
      repeat(4) @(posedge free_clk);
      reg_poll(DIF_STATUS, ST_BUSY | ST_CMD_PEND | ST_DFILL_PEND, 32'h0, max_reads);
   end
endtask

// Number of CS frames between two log indices [a, b)
function integer frames_in;
   input integer a;
   input integer b;
   integer kk;
   begin
      frames_in = (b > a) ? 1 : 0;
      for (kk = a + 1; kk < b; kk = kk + 1)
        if (lg_frame[kk] != lg_frame[kk-1]) frames_in = frames_in + 1;
   end
endfunction

// Scanline crossing reference (prev < S < cur strictly, with frame wrap)
function crossing;
   input [9:0] prev;
   input [9:0] cur;
   input [9:0] sl;
   begin
      if (prev < cur)      crossing = (prev < sl) && (sl <= cur);
      else if (prev > cur) crossing = (sl > prev) || (sl <= cur);
      else                 crossing = 1'b0;
   end
endfunction

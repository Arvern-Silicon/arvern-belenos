//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    i2s_src_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2s_src_model.v
// Module Description : I2S clock master for the HDMI audio input (Philips
//                      format: LRCK low = left, changes with the falling BCLK
//                      edge one bit before the MSB, data launched on falling
//                      edges). While run is set it sends frames k = 0, 1, ...
//                      of sample(k, 0) (left) and sample(k, 1) (right),
//                      24-bit values MSB first in slots of `slot` bits (the
//                      24 bits then zeros in a longer slot, the top `slot`
//                      bits in a shorter one); half is the BCLK half period
//                      (ns), duty the fraction of the period BCLK is high.
//                      frames counts the frames whose last bit has been sent.
//                      rnd = 1: sample(k, ch) is a full-scale 24-bit value
//                      drawn from k, ch and seed (a hash, so a test computes
//                      the same value), every 16th frame 0x7FFFFF / 0x800000
//                      and the next 0xFFFFFF / 0x000000. hold = 1: the
//                      stream stops (LRCK and SD held) while BCLK runs, and
//                      goes on from where it was when hold clears.
//                      rmode = 1 (random stream, from rseed): every slot has
//                      a length drawn in rl_min..rl_max bits and random bits
//                      in every position (also past 24), every BCLK half
//                      period a duration drawn in rh_min..rh_max ns. Slot j
//                      (even: left, odd: right) logs the sample the receiver
//                      must take, its first min(length, 24) bits MSB-justified
//                      and zero-filled (rs_exp[j % RS_NR]), and rs_last is the
//                      last slot ended: set at the BCLK rising edge that
//                      samples its last bit (the edge where LRCK has changed).
//----------------------------------------------------------------------------

module i2s_src_model (
    output reg         bclk_o,
    output reg         lrck_o,
    output reg         sd_o
);

real     half   = 30.0;
real     duty   = 0.5;
integer  slot   = 32;
reg      run    = 1'b0;
reg      hold   = 1'b0;                   // LRCK and SD held, BCLK running
integer  frames = 0;
integer  n      = 0;                      // bit position since run was set
reg      rnd    = 1'b0;
integer  seed   = 0;

localparam integer RS_NR = 4096;
reg      rmode  = 1'b0;
integer  rseed  = 1;
integer  rl_min = 2;
integer  rl_max = 63;
real     rh_min = 30.0;
real     rh_max = 60.0;
integer  rs_last = -1;                    // last slot ended
integer  rs_cur  = -1;                    // slot of the bit being sent
integer  rs_len, rs_b, rs_k, rs_end;
reg      rs_sd  = 1'b0;                   // bit of the position sent at the next falling edge
reg [63:0] rs_bits;
reg [23:0] rs_exp [0:RS_NR-1];

function real rnd_half;
   input integer dummy;
   integer r;
   begin
      r        = $random(rseed);
      rnd_half = rh_min + (rh_max - rh_min) * ((r & 32'h7FFF) / 32767.0);
   end
endfunction

function [23:0] sample;
   input integer k;
   input integer ch;
   reg   [31:0]  h;
   begin
      h = (2 * k + ch) ^ seed;
      h = h * 32'h9E37_79B1;
      h = h ^ (h >> 15);
      h = h * 32'h85EB_CA77;
      h = h ^ (h >> 13);
      if (!rnd)                sample = {k[15:0], (ch != 0) ? 8'hC3 : 8'h3C};
      else if (k % 16 == 0)    sample = (ch != 0) ? 24'h80_0000 : 24'h7F_FFFF;
      else if (k % 16 == 1)    sample = (ch != 0) ? 24'h00_0000 : 24'hFF_FFFF;
      else                     sample = h[23:0];
   end
endfunction

// Bit b (0 = MSB) of slot number j: frame j / 2, channel j % 2
function slot_bit;
   input integer j;
   input integer b;
   reg   [23:0]  s;
   begin
      s        = sample(j / 2, j % 2);
      slot_bit = (b < 24) ? s[23 - b] : 1'b0;
   end
endfunction

initial begin
   bclk_o = 1'b0; lrck_o = 1'b0; sd_o = 1'b0;
end

always begin
   if (!run) begin
      bclk_o = 1'b0; n = 0;
      rs_cur = -1; rs_last = -1; rs_end = -1; rs_b = 0; rs_len = 0;
      @(posedge run);
   end
   if (rmode) begin
      #(rnd_half(0)) bclk_o = 1'b1;
      if (rs_end >= 0) begin rs_last = rs_end; rs_end = -1; end
      #(rnd_half(0)) bclk_o = 1'b0;
   end else begin
      #(2.0 * half * (1.0 - duty)) bclk_o = 1'b1;
      #(2.0 * half * duty)         bclk_o = 1'b0;
   end
   // Falling edge: position n of the stream
   if (rmode) begin
      if (!hold) begin
         // SD: the bit of the previous position; it ends its slot when the
         // position now starting is a new slot's first
         sd_o = rs_sd;
         if ((rs_cur < 0) || (rs_b == rs_len)) begin
            if (rs_cur >= 0) rs_end = rs_cur;
            rs_cur  = rs_cur + 1;
            rs_len  = rl_min + ({$random(rseed)} % (rl_max - rl_min + 1));
            rs_bits = {$random(rseed), $random(rseed)};
            rs_exp[rs_cur % RS_NR] = 24'h00_0000;
            for (rs_k = 0; (rs_k < rs_len) && (rs_k < 24); rs_k = rs_k + 1)
               rs_exp[rs_cur % RS_NR][23 - rs_k] = rs_bits[63 - rs_k];
            rs_b = 0;
         end
         lrck_o = rs_cur[0];
         rs_sd  = rs_bits[63 - rs_b];
         rs_b   = rs_b + 1;
         n = n + 1;
      end
   end else if (!hold) begin
      lrck_o = ((n / slot) % 2) != 0;
      if (n == 0) sd_o = 1'b0;
      else begin
         sd_o = slot_bit((n - 1) / slot, (n - 1) % slot);
         if (((n - 1) % (2 * slot)) == (2 * slot - 1)) frames = frames + 1;
      end
      n = n + 1;
   end
end

endmodule // i2s_src_model

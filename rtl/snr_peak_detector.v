`timescale 1ns / 1ps
//
// snr_peak_detector.v
//
// Walks one frame of bin powers, keeps the biggest one and the running
// total, and at the end of the frame works out:
//
//   peak       = the largest bin power in the frame
//   noise      = (total - peak) / number of bins, ie the average power of
//                everything that is not the peak
//   snr        = peak in dB minus noise in dB
//
// The original version did this with
//     if (power_in > max_power) max_power <= power_in;
//     else                      noise_sum <= noise_sum + power_in;
// which is not right. Once a big peak has been found every later bin goes
// into the noise sum including any other real target, and any early bin that
// happened to be the running max never gets counted as noise at all. Taking
// the total and subtracting the peak avoids both problems.
//
module snr_peak_detector #(
    parameter integer N = 64
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [31:0]          power_in,
    input  wire                 valid,
    input  wire                 last,       // marks the final bin of a frame

    output reg  [15:0]          peak_bin_power_db,
    output reg  signed [15:0]   snr_db,
    output reg  [$clog2(N)-1:0] peak_bin,
    output reg                  result_valid
);

    localparam integer ADDR_W    = $clog2(N);
    localparam integer HALF      = N/2;          // highest bin we bother with
    localparam integer LOG2_HALF = $clog2(N/2);  // lets us shift instead of divide
    localparam integer SUM_W     = 32 + ADDR_W;  // room to add a frame of bins up

    reg [31:0]       max_power;
    reg [ADDR_W-1:0] max_index;
    reg [SUM_W-1:0]  sum_power;
    reg [ADDR_W-1:0] bin_index;

    // frame result on its way through the dB conversion
    reg [31:0]       frame_peak, frame_noise;
    reg [ADDR_W-1:0] frame_bin, bin_hold;
    reg [9:0]        l2_peak, l2_noise;
    reg              s1, s2;

    // combinational working values, only used inside the always block below
    reg [31:0]       nxt_max;
    reg [ADDR_W-1:0] nxt_idx;
    reg [SUM_W-1:0]  nxt_sum;

    // fft_block ties the imaginary input to zero, so the input is real only
    // and the spectrum comes out mirrored: a tone in bin k shows up again in
    // bin N-k with exactly the same power. If we averaged across all N bins
    // that mirror image would land in the noise estimate and pin the reported
    // SNR at about 18 dB however clean the signal actually was. So we only
    // look at bins 1 to N/2, which is the positive half of the spectrum. Bin
    // 0 is skipped as well because any DC offset on the ADC would otherwise
    // win the peak search every single time.
    wire in_window = (bin_index != 0) && (bin_index <= HALF);

    always @(posedge clk) begin
        if (!rst_n) begin
            max_power         <= 32'd0;
            max_index         <= {ADDR_W{1'b0}};
            sum_power         <= {SUM_W{1'b0}};
            bin_index         <= {ADDR_W{1'b0}};
            frame_peak        <= 32'd0;
            frame_noise       <= 32'd0;
            frame_bin         <= {ADDR_W{1'b0}};
            bin_hold          <= {ADDR_W{1'b0}};
            l2_peak           <= 10'd0;
            l2_noise          <= 10'd0;
            s1                <= 1'b0;
            s2                <= 1'b0;
            peak_bin_power_db <= 16'd0;
            snr_db            <= 16'sd0;
            peak_bin          <= {ADDR_W{1'b0}};
            result_valid      <= 1'b0;
        end else begin
            s1           <= 1'b0;
            s2           <= 1'b0;
            result_valid <= 1'b0;

            // ---------------- accumulate across the frame ----------------
            if (valid) begin
                // Work out what the max and the total look like with this bin
                // already included, then use those values. The old code
                // compared against the register and then read the register
                // again at the frame end, so the final bin never counted.
                if (in_window && (power_in > max_power)) begin
                    nxt_max = power_in;
                    nxt_idx = bin_index;
                end else begin
                    nxt_max = max_power;
                    nxt_idx = max_index;
                end
                nxt_sum = in_window ? (sum_power + power_in) : sum_power;

                if (last) begin
                    frame_peak  <= nxt_max;
                    // Dividing by N/2 instead of N/2-1 saves a real divider
                    // and only costs about 0.14 dB with 32 bins, which is
                    // well inside the accuracy of the log below anyway.
                    frame_noise <= (nxt_sum - nxt_max) >> LOG2_HALF;
                    frame_bin   <= nxt_idx;
                    s1          <= 1'b1;

                    max_power   <= 32'd0;
                    max_index   <= {ADDR_W{1'b0}};
                    sum_power   <= {SUM_W{1'b0}};
                    bin_index   <= {ADDR_W{1'b0}};
                end else begin
                    max_power   <= nxt_max;
                    max_index   <= nxt_idx;
                    sum_power   <= nxt_sum;
                    bin_index   <= bin_index + 1'b1;
                end
            end

            // ------------- two cycle tail to get to dB -------------
            // Split over two clocks so the priority encoder, the barrel shift
            // and the scaling multiply are not all sat in one long path. The
            // frame is 64 clocks long so there is loads of time spare.
            if (s1) begin
                l2_peak  <= log2_q4(frame_peak);
                l2_noise <= log2_q4(frame_noise);
                bin_hold <= frame_bin;
                s2       <= 1'b1;
            end

            if (s2) begin
                peak_bin_power_db <= log2_to_db($signed({2'b00, l2_peak}));
                // Doing the subtraction in the log2 domain first means only
                // one scaling multiply is needed, and it keeps a bit more
                // precision than converting both to dB and then subtracting.
                snr_db            <= log2_to_db($signed({2'b00, l2_peak}) -
                                                $signed({2'b00, l2_noise}));
                peak_bin          <= bin_hold;
                result_valid      <= 1'b1;
            end
        end
    end

    // log2 of a 32 bit value, in sixteenths.
    //
    // Find the top set bit for the whole part, then take the four bits
    // underneath it as a straight line guess at the fraction. Because log2 is
    // a curve and we are approximating it with a chord the answer comes out
    // slightly low, worst case about 0.09 of an octave (roughly a quarter of
    // a dB) when the mantissa is near 1.5. Good enough here, and a chunk of
    // it cancels out anyway because SNR is a difference of two logs.
    function [9:0] log2_q4;
        input [31:0] val;
        reg [4:0] msb;
        reg [4:0] mant;     // the leading 1 plus 4 fraction bits
        integer   i;
        begin
            if (val == 32'd0) begin
                log2_q4 = 10'd0;
            end else begin
                msb = 5'd0;
                for (i = 0; i < 32; i = i + 1)
                    if (val[i]) msb = i;   // last hit wins so this ends up the top bit

                if (msb >= 5'd4)
                    mant = val >> (msb - 5'd4);
                else
                    mant = val << (5'd4 - msb);

                log2_q4 = {msb, mant[3:0]};   // same as msb*16 + fraction
            end
        end
    endfunction

    // Turn a log2 in sixteenths into whole dB.
    // 10*log10(x) is the same as 3.0103*log2(x), and 3.0103/16 = 0.188137,
    // which is within 0.05% of 771/4096. So it is one scale and a shift.
    //
    // The scale is written out as shifts and adds rather than as "* 771" on
    // purpose. 771 is 512+256+2+1 so it costs about four small adders, and it
    // keeps the l2_peak / l2_noise registers above in the fabric where I put
    // them. Written as a plain multiply Vivado infers a DSP48 and then packs
    // those registers into the DSP's own input stage, which quietly removes
    // the pipeline stage, leaves the log2 encoder driving straight into the
    // DSP over a long route, and misses 125 MHz by about 130 ps.
    function signed [15:0] log2_to_db;
        input signed [11:0] l2_q4;
        reg signed [23:0] x, scaled;
        begin
            x          = l2_q4;                                  // sign extend
            scaled     = (x <<< 9) + (x <<< 8) + (x <<< 1) + x;  // times 771
            log2_to_db = scaled >>> 12;
        end
    endfunction

endmodule

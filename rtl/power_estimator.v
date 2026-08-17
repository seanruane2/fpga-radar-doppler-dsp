`timescale 1ns / 1ps
//
// power_estimator.v
//
// power = re^2 + im^2 for each bin.
//
// This is a two stage pipeline, so the valid and last flags get delayed by
// exactly the same two clocks as the data. The old version delayed the data
// by two but the valid by one, which meant the peak detector behind it was
// looking at the wrong bin the whole time.
//
module power_estimator (
    input  wire               clk,
    input  wire               rst_n,

    input  wire signed [15:0] fft_real,
    input  wire signed [15:0] fft_imag,
    input  wire               in_valid,
    input  wire               in_last,

    output reg  [31:0]        power_out,
    output reg                out_valid,
    output reg                out_last
);

    reg [31:0] re_sq, im_sq;
    reg        v1, l1;

    always @(posedge clk) begin
        if (!rst_n) begin
            re_sq     <= 32'd0;
            im_sq     <= 32'd0;
            v1        <= 1'b0;
            l1        <= 1'b0;
            power_out <= 32'd0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
        end else begin
            // Stage 1: the two squares. Both inputs are signed 16 bit so each
            // product needs 32 bits, and a square is never negative so the
            // unsigned result is safe. Vivado maps these onto DSP48 slices.
            re_sq <= fft_real * fft_real;
            im_sq <= fft_imag * fft_imag;
            v1    <= in_valid;
            l1    <= in_last;

            // Stage 2: add them. Worst case is 2 * 2^30 = 2^31, which still
            // fits in 32 bits unsigned, so there is no overflow to handle.
            power_out <= re_sq + im_sq;
            out_valid <= v1;
            out_last  <= l1;
        end
    end

endmodule

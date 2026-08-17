`timescale 1ns / 1ps
//
// top.v
//
// Pulse doppler DSP chain for a PYNQ-Z2.
//
//   adc_in --> sample_buffer --> fft_block --> power_estimator --> snr_peak_detector
//                (64 x 12)      (xfft ip)       (re^2 + im^2)      (peak, noise, dB)
//
// One frame of 64 samples goes in, one set of results comes out with
// result_valid pulsed for a clock.
//
module pulse_doppler_dsp_top #(
    parameter integer N         = 64,   // FFT length, must match the xfft IP config
    parameter integer ADC_WIDTH = 12
)(
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire [ADC_WIDTH-1:0]     adc_in,        // signed, twos complement
    input  wire                     sample_valid,

    output wire [15:0]              peak_bin_power_db,
    output wire signed [15:0]       snr_db,
    output wire [$clog2(N)-1:0]     peak_bin,
    output wire                     result_valid
);

    localparam integer ADDR_W = $clog2(N);

    wire [ADDR_W-1:0]     rd_addr;
    wire [ADC_WIDTH-1:0]  rd_data;
    wire                  frame_ready, frame_taken;

    // Line the ADC word up against the top of the FFT's 16 bit input so we
    // actually use the range of the core instead of rattling around in the
    // bottom 12 bits. Shifting left like this puts the sign bit in bit 15,
    // which is where the FFT expects it. The old top level wired a 12 bit
    // bus straight onto a 16 bit one, so every negative sample turned into a
    // big positive number and the spectrum was junk.
    wire signed [15:0] fft_sample = {rd_data, {(16-ADC_WIDTH){1'b0}}};

    wire signed [15:0] fft_real, fft_imag;
    wire               fft_valid, fft_last;

    wire [31:0]        bin_power;
    wire               power_valid, power_last;

    sample_buffer #(
        .N     (N),
        .WIDTH (ADC_WIDTH)
    ) u_buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_valid (sample_valid),
        .sample_in    (adc_in),
        .rd_addr      (rd_addr),
        .rd_data      (rd_data),
        .frame_ready  (frame_ready),
        .frame_taken  (frame_taken)
    );

    fft_block #(
        .N (N)
    ) u_fft (
        .clk          (clk),
        .rst_n        (rst_n),
        .frame_ready  (frame_ready),
        .frame_taken  (frame_taken),
        .rd_addr      (rd_addr),
        .sample_in    (fft_sample),
        .fft_real_out (fft_real),
        .fft_imag_out (fft_imag),
        .fft_valid    (fft_valid),
        .fft_last     (fft_last)
    );

    power_estimator u_power (
        .clk       (clk),
        .rst_n     (rst_n),
        .fft_real  (fft_real),
        .fft_imag  (fft_imag),
        .in_valid  (fft_valid),
        .in_last   (fft_last),
        .power_out (bin_power),
        .out_valid (power_valid),
        .out_last  (power_last)
    );

    snr_peak_detector #(
        .N (N)
    ) u_snr (
        .clk               (clk),
        .rst_n             (rst_n),
        .power_in          (bin_power),
        .valid             (power_valid),
        .last              (power_last),
        .peak_bin_power_db (peak_bin_power_db),
        .snr_db            (snr_db),
        .peak_bin          (peak_bin),
        .result_valid      (result_valid)
    );

endmodule

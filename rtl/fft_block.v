`timescale 1ns / 1ps
//
// fft_block.v
//
// AXI-Stream wrapper around the Xilinx xfft core. Three jobs:
//
//   1. After reset, write one word to the config channel to set the scaling
//      schedule and pick the forward transform.
//   2. When sample_buffer says it has a frame, walk the buffer and push N
//      samples into the core, respecting s_axis_data_tready.
//   3. Hand the output samples out with a valid and a last flag.
//
// The core is set up for the Non Real Time throttle scheme, which means it
// is allowed to drop TREADY and expects us to hold off. The old version of
// this file ignored TREADY completely and also left m_axis_data_tready
// dangling, so the core never let any output through.
//
module fft_block #(
    parameter integer N = 64        // must match CONFIG.transform_length on the IP
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // sample_buffer side
    input  wire                 frame_ready,
    output reg                  frame_taken,
    output reg  [$clog2(N)-1:0] rd_addr,
    input  wire signed [15:0]   sample_in,

    // results, one bin per clock with last marking the end of the frame
    output reg  signed [15:0]   fft_real_out,
    output reg  signed [15:0]   fft_imag_out,
    output reg                  fft_valid,
    output reg                  fft_last
);

    localparam integer ADDR_W = $clog2(N);

    // Config word layout, confirmed against the demo testbench the IP ships
    // with (see xfft_0/demo_tb):
    //   bit 0    1 = forward transform
    //   bit 6:1  scaling schedule, 2 bits per pair of radix 2 stages
    //   bit 7    padding up to a whole byte
    //
    // The schedule below is the one Xilinx recommend in PG109 for the biggest
    // output magnitude that still cannot overflow: shift 3 in the first pair
    // of stages, then 2 in each pair after that. 64 points is 6 radix 2
    // stages so there are 3 pairs, giving a total shift of 7.
    localparam [5:0] SCALE_SCH  = {2'b10, 2'b10, 2'b11};
    localparam [7:0] FFT_CONFIG = {1'b0, SCALE_SCH, 1'b1};   // 8'h57

    localparam [1:0] S_CFG  = 2'd0,   // send the config word once
                     S_IDLE = 2'd1,   // wait for a frame
                     S_LOAD = 2'd2;   // stream N samples in

    reg [1:0] state;

    // ---------------- input side ----------------
    wire [7:0]  cfg_tdata  = FFT_CONFIG;
    wire        cfg_tvalid = (state == S_CFG);
    wire        cfg_tready;

    // real input only, so the imaginary half of the word is zero
    wire [31:0] din_tdata  = {16'd0, sample_in};
    wire        din_tvalid = (state == S_LOAD);
    wire        din_tlast  = (state == S_LOAD) && (rd_addr == N-1);
    wire        din_tready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_CFG;
            rd_addr     <= {ADDR_W{1'b0}};
            frame_taken <= 1'b0;
        end else begin
            frame_taken <= 1'b0;

            case (state)

            S_CFG: begin
                if (cfg_tready)
                    state <= S_IDLE;
            end

            // frame_taken has to be part of this condition. The buffer does
            // not drop frame_ready until it has seen frame_taken, so without
            // the extra term we would see the old frame_ready still high and
            // send the same frame twice.
            S_IDLE: begin
                if (frame_ready && !frame_taken) begin
                    rd_addr <= {ADDR_W{1'b0}};
                    state   <= S_LOAD;
                end
            end

            S_LOAD: begin
                if (din_tready) begin
                    if (rd_addr == N-1) begin
                        rd_addr     <= {ADDR_W{1'b0}};
                        frame_taken <= 1'b1;
                        state       <= S_IDLE;
                    end else begin
                        rd_addr <= rd_addr + 1'b1;
                    end
                end
            end

            default: state <= S_CFG;

            endcase
        end
    end

    // ---------------- output side ----------------
    wire [31:0] dout_tdata;
    wire        dout_tvalid;
    wire        dout_tlast;

    always @(posedge clk) begin
        if (!rst_n) begin
            fft_real_out <= 16'sd0;
            fft_imag_out <= 16'sd0;
            fft_valid    <= 1'b0;
            fft_last     <= 1'b0;
        end else begin
            fft_valid <= dout_tvalid;
            fft_last  <= dout_tvalid && dout_tlast;
            if (dout_tvalid) begin
                fft_real_out <= dout_tdata[15:0];
                fft_imag_out <= dout_tdata[31:16];
            end
        end
    end

    xfft_0 u_xfft (
        .aclk                        (clk),
        .aresetn                     (rst_n),      // needs CONFIG.aresetn = true
        .s_axis_config_tdata         (cfg_tdata),
        .s_axis_config_tvalid        (cfg_tvalid),
        .s_axis_config_tready        (cfg_tready),
        .s_axis_data_tdata           (din_tdata),
        .s_axis_data_tvalid          (din_tvalid),
        .s_axis_data_tready          (din_tready),
        .s_axis_data_tlast           (din_tlast),
        .m_axis_data_tdata           (dout_tdata),
        .m_axis_data_tvalid          (dout_tvalid),
        // everything downstream of here is a straight pipeline that can
        // never push back, so we are always ready
        .m_axis_data_tready          (1'b1),
        .m_axis_data_tlast           (dout_tlast),
        .event_frame_started         (),
        .event_tlast_unexpected      (),
        .event_tlast_missing         (),
        .event_status_channel_halt   (),
        .event_data_in_channel_halt  (),
        .event_data_out_channel_halt ()
    );

endmodule

`timescale 1ns / 1ps
//
// sample_buffer.v
//
// Collects N samples off the ADC into a small memory and then holds them
// still so fft_block can read them back out one at a time.
//
// The read port is combinational on purpose. 64 x 12 bits is tiny so Vivado
// puts it in LUT RAM, and having no read latency keeps the AXI-Stream
// handshake in fft_block a lot easier to get right.
//
// Note that while a frame is waiting to be read we stop accepting new
// samples, otherwise the frame would get torn up half way through being
// sent to the FFT. Readout only takes N clocks and the ADC is much slower
// than the system clock, so in practice we lose one sample at most between
// frames.
//
module sample_buffer #(
    parameter integer N     = 64,   // samples per frame, must be a power of 2
    parameter integer WIDTH = 12    // ADC width, signed twos complement
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // write side, straight off the ADC
    input  wire                    sample_valid,
    input  wire [WIDTH-1:0]        sample_in,

    // read side, address comes from fft_block
    input  wire [$clog2(N)-1:0]    rd_addr,
    output wire [WIDTH-1:0]        rd_data,

    // handshake with fft_block
    output reg                     frame_ready,   // a whole frame is sat in the memory
    input  wire                    frame_taken    // pulse once the frame has been sent
);

    localparam integer ADDR_W = $clog2(N);

    reg [WIDTH-1:0]  mem [0:N-1];
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W:0]   fill;      // one extra bit so it can count all the way to N

    assign rd_data = mem[rd_addr];

    wire accept = sample_valid && !frame_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr      <= {ADDR_W{1'b0}};
            fill        <= {(ADDR_W+1){1'b0}};
            frame_ready <= 1'b0;
        end else begin
            if (accept) begin
                wr_ptr <= wr_ptr + 1'b1;    // N is a power of 2 so this wraps by itself
                if (fill == N-1) begin
                    fill        <= {(ADDR_W+1){1'b0}};
                    frame_ready <= 1'b1;
                end else begin
                    fill <= fill + 1'b1;
                end
            end
            // frame_taken can never land in the same cycle as accept, because
            // accept is held off whenever frame_ready is high
            if (frame_taken)
                frame_ready <= 1'b0;
        end
    end

    // The array write is kept out of the reset branch. Distributed and block
    // RAM have no reset on the storage itself, so trying to clear it here
    // just stops Vivado inferring a RAM and burns flip flops instead.
    always @(posedge clk) begin
        if (accept)
            mem[wr_ptr] <= sample_in;
    end

endmodule

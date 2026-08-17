`timescale 1ns / 1ps
//
// tb_pulse_doppler_dsp_top.sv
//
// Feeds the DSP chain a synthetic ADC stream and checks the results.
//
// Three cases:
//   1. a clean tone sat exactly in bin 7, so the peak search and the bin
//      numbering can be checked with no noise in the way
//   2. the same idea in bin 20 but with uniform noise added, to see whether
//      the SNR number lands somewhere sensible
//   3. noise on its own, where the reported SNR should collapse to the few
//      dB you get just from the luckiest bin of 32
//
// The tone frequencies are picked to sit exactly on a bin centre so there is
// no leakage into the neighbours, which keeps the expected numbers clean.
//
module tb_pulse_doppler_dsp_top;

    localparam integer N          = 64;
    localparam integer ADC_WIDTH  = 12;
    localparam integer SAMPLE_DIV = 8;      // one ADC sample every 8 clocks
    localparam real    PI         = 3.141592653589793;

    reg                     clk   = 1'b0;
    reg                     rst_n = 1'b0;
    reg  [ADC_WIDTH-1:0]    adc_in = '0;
    reg                     sample_valid = 1'b0;

    wire [15:0]             peak_bin_power_db;
    wire signed [15:0]      snr_db;
    wire [$clog2(N)-1:0]    peak_bin;
    wire                    result_valid;

    // stimulus knobs, the driver below reads these every sample
    int  tone_bin  = 7;
    real tone_amp  = 1000.0;
    real noise_amp = 0.0;

    int  t          = 0;    // ADC sample index, keeps counting the whole run
    int  div_cnt    = 0;
    int  errors     = 0;

    always #4 clk = ~clk;   // 125 MHz, same as the PYNQ-Z2 PL clock

    pulse_doppler_dsp_top #(
        .N         (N),
        .ADC_WIDTH (ADC_WIDTH)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .adc_in            (adc_in),
        .sample_valid      (sample_valid),
        .peak_bin_power_db (peak_bin_power_db),
        .snr_db            (snr_db),
        .peak_bin          (peak_bin),
        .result_valid      (result_valid)
    );

    // ------------------------------------------------------------------
    // ADC model
    // ------------------------------------------------------------------
    function automatic signed [ADC_WIDTH-1:0] make_sample(int idx);
        real s, n;
        int  v;
        begin
            s = tone_amp * $cos(2.0 * PI * real'(tone_bin) * real'(idx) / real'(N));
            if (noise_amp > 0.0)
                n = noise_amp * ((real'($urandom_range(0, 2000)) - 1000.0) / 1000.0);
            else
                n = 0.0;

            v = $rtoi(s + n);
            // clip like a real converter would rather than wrapping round
            if (v >  2047) v =  2047;
            if (v < -2048) v = -2048;
            return v[ADC_WIDTH-1:0];
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt      <= 0;
            sample_valid <= 1'b0;
        end else if (div_cnt == SAMPLE_DIV-1) begin
            div_cnt      <= 0;
            adc_in       <= make_sample(t);
            sample_valid <= 1'b1;
            t            <= t + 1;
        end else begin
            div_cnt      <= div_cnt + 1;
            sample_valid <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Checks
    // ------------------------------------------------------------------
    task automatic wait_frames(int count);
        for (int k = 0; k < count; k++)
            @(posedge clk iff result_valid);
    endtask

    task automatic run_case(input string    name,
                            input int       want_bin,
                            input int       snr_min,
                            input int       snr_max,
                            input bit       check_bin);
        int got_bin, got_snr, got_peak;
        begin
            // let a few frames go by so nothing from the previous case is
            // still in the pipeline
            wait_frames(3);
            @(posedge clk iff result_valid);
            got_bin  = peak_bin;
            got_snr  = snr_db;
            got_peak = peak_bin_power_db;

            $display("");
            $display("  %s", name);
            $display("    peak bin        : %0d", got_bin);
            $display("    peak power      : %0d dB", got_peak);
            $display("    snr             : %0d dB", got_snr);

            if (check_bin && got_bin != want_bin) begin
                $display("    FAIL: expected the peak in bin %0d", want_bin);
                errors++;
            end
            if (got_snr < snr_min || got_snr > snr_max) begin
                $display("    FAIL: snr outside the expected %0d to %0d dB",
                         snr_min, snr_max);
                errors++;
            end
            if (!(check_bin && got_bin != want_bin) &&
                 (got_snr >= snr_min && got_snr <= snr_max))
                $display("    pass");
        end
    endtask

    initial begin
        $display("");
        $display("=== pulse doppler dsp chain, %0d point fft ===", N);

        // the xfft core wants aresetn held low for at least 2 clocks, this is
        // a lot longer than that
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // 1. clean tone. The floor here is set by 12 bit quantisation plus
        //    whatever the FFT rounds away, so it should be well up in the
        //    60s or 70s of dB.
        tone_bin  = 7;
        tone_amp  = 1000.0;
        noise_amp = 0.0;
        run_case("clean tone in bin 7", 7, 40, 120, 1);

        // 2. tone plus noise. Uniform noise of +/-200 LSB against a 1000 LSB
        //    tone is about 16 dB in the time domain, and a 64 point FFT adds
        //    roughly 15 dB of processing gain over the 32 bins we look at, so
        //    somewhere around 30 dB per bin is expected.
        tone_bin  = 20;
        tone_amp  = 1000.0;
        noise_amp = 200.0;
        run_case("tone in bin 20 plus noise", 20, 18, 45, 1);

        // 3. noise only. With 32 bins the biggest one sits about 6 to 10 dB
        //    over the average, so anything much above that means the noise
        //    estimate is broken.
        tone_bin  = 20;
        tone_amp  = 0.0;
        noise_amp = 200.0;
        run_case("noise only, no target", 0, 0, 20, 0);

        $display("");
        if (errors == 0)
            $display("=== all checks passed ===");
        else
            $display("=== %0d check(s) FAILED ===", errors);
        $display("");
        $finish;
    end

    // watchdog, in case the handshaking deadlocks and no results ever appear
    initial begin
        #2000000;
        $display("");
        $display("=== TIMEOUT, no results came out, something is stuck ===");
        $finish;
    end

endmodule

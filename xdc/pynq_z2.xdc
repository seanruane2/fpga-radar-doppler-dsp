## ---------------------------------------------------------------------------
## pynq_z2.xdc
##
## Timing and pin constraints for the PYNQ-Z2 (xc7z020clg400-1).
##
## The clock is the 125 MHz single ended one that comes off the ethernet PHY
## on pin H16, which is the usual choice for a PL only design on this board.
## ---------------------------------------------------------------------------

set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 8.000 -name sys_clk -waveform {0.000 4.000} [get_ports clk]


## ---------------------------------------------------------------------------
## Reset
##
## rst_n is asynchronous to everything, so tell the tools not to bother timing
## the path where it arrives. Every flop it feeds is synchronous to sys_clk so
## a short glitch on release is not a problem here.
## ---------------------------------------------------------------------------

set_false_path -from [get_ports rst_n]


## ---------------------------------------------------------------------------
## ADC interface
##
## Left for you to fill in, because it depends on which header the converter
## is actually wired to. Synthesis and timing analysis both run fine with only
## the clock constrained above, but you need real pins here before Vivado will
## write a bitstream.
##
## On a PYNQ-Z2 the obvious places to bring 12 bits plus a strobe in are
## PMODA/PMODB (8 pins each) or the Arduino header. Something like:
##
##   set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {adc_in[0]}]
##   set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {adc_in[1]}]
##   ...
##   set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports sample_valid]
##
## Check the pin numbers against the PYNQ-Z2 master XDC for your board
## revision before you trust them, and if the ADC clocks data out on its own
## clock rather than on sys_clk then it needs an input delay constraint and a
## proper clock domain crossing instead of just being sampled here.
##
## The result outputs (peak_bin_power_db, snr_db, peak_bin, result_valid) come
## to 39 bits, which is more than the board has spare pins for. They are meant
## to be read over AXI from the PS, or trimmed down to something that fits the
## 4 LEDs for a quick look on hardware.
## ---------------------------------------------------------------------------

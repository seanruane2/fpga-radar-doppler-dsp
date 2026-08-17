# ----------------------------------------------------------------------------
# build.tcl
#
# Builds the whole Vivado project from the files in this repo, including
# generating the FFT IP with the right settings. Nothing about the project is
# committed to git, only the sources and this script, so this is the way to
# get a working project after cloning.
#
#   vivado -mode batch -source build.tcl                 just create the project
#   vivado -mode batch -source build.tcl -tclargs sim    create it and run the testbench
#   vivado -mode batch -source build.tcl -tclargs synth  create it and synthesise
#
# The project lands in ./build/ which is gitignored.
# ----------------------------------------------------------------------------

set proj_name "dsp_fft"
set part      "xc7z020clg400-1"    ;# PYNQ-Z2, see the board_part note below

set repo_dir  [file normalize [file dirname [info script]]]
set build_dir [file join $repo_dir "build"]

set action "none"
if {$argc > 0} { set action [lindex $argv 0] }

puts "\n=== creating project in $build_dir ===\n"
file mkdir $build_dir
create_project -force $proj_name [file join $build_dir $proj_name] -part $part

# board_part is deliberately NOT set here, and it is worth explaining why
# because setting it seems like the obvious thing to do.
#
# The PYNQ-Z2 is a TUL board so its files come from the XHub board store rather
# than shipping with Vivado, which means telling Vivado where they are with an
# absolute path in board_part_repo_paths. On Windows that path runs through your
# user folder, and if your user name has a space in it Vivado splits the path on
# that space when it writes the scripts for the out of context IP synthesis run.
# The path comes back mangled, no board files are found, and xfft_0_synth_1 dies
# with a board_part error before it even looks at the design. Took me a while to
# work out that the schematic failing had nothing to do with the RTL.
#
# The design does not need the board anyway. There is no PS block and no board
# automation, the XDC names pin H16 directly, and only the part does any real
# work. So the part gets set and nothing else.
#
# If you add the Zynq PS later for the AXI registers and want board automation,
# set the board in the GUI under Settings then General, and check that
# xfft_0_synth_1 still passes afterwards, because the same space problem is
# waiting there.

# ----------------------------------------------------------------------------
# Sources
# ----------------------------------------------------------------------------
add_files -norecurse [glob [file join $repo_dir rtl *.v]]
set_property top pulse_doppler_dsp_top [get_filesets sources_1]

add_files -fileset sim_1 -norecurse [glob [file join $repo_dir sim *.sv]]
set_property top tb_pulse_doppler_dsp_top [get_filesets sim_1]

# Let the testbench run until its own $finish instead of stopping at Vivado's
# default 1000 ns. One frame of 64 samples takes about 4 us to collect, so at
# the default you would stop before the very first result appeared and the
# waveform would look completely dead. Set on the fileset so the GUI picks it
# up too, not just the batch run below.
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

add_files -fileset constrs_1 -norecurse [glob [file join $repo_dir xdc *.xdc]]

# ----------------------------------------------------------------------------
# FFT IP
#
# This is the bit that was actually wrong before. The .xci that was checked in
# asked for a 1024 point transform with bit reversed output and no aresetn port,
# which are all just the IP's defaults, so the core had never really been
# configured at all. The RTL around it is written for 64 points and it connects
# aresetn, so nothing lined up and it would not even elaborate.
#
# Setting every option explicitly here is deliberate. A .xci holding default
# values is indistinguishable from one somebody configured on purpose, so the
# config belongs in a script where you can read the intent.
# ----------------------------------------------------------------------------
puts "\n=== generating xfft_0 ===\n"
create_ip -name xfft -vendor xilinx.com -library ip -version 9.1 -module_name xfft_0

set_property -dict [list \
    CONFIG.transform_length                       {64}   \
    CONFIG.run_time_configurable_transform_length {false} \
    CONFIG.implementation_options                 {pipelined_streaming_io} \
    CONFIG.data_format                            {fixed_point} \
    CONFIG.input_width                            {16}   \
    CONFIG.phase_factor_width                     {16}   \
    CONFIG.scaling_options                        {scaled} \
    CONFIG.rounding_modes                         {convergent_rounding} \
    CONFIG.output_ordering                        {natural_order} \
    CONFIG.throttle_scheme                        {nonrealtime} \
    CONFIG.aresetn                                {true} \
    CONFIG.aclken                                 {false} \
    CONFIG.ovflo                                  {false} \
    CONFIG.xk_index                               {false} \
    CONFIG.cyclic_prefix_insertion                {false} \
] [get_ips xfft_0]

# Why these settings:
#
#   transform_length 64        matches N in the RTL. Change both together.
#   pipelined_streaming_io     lets samples go in back to back, and it is the
#                              architecture the scaling schedule in
#                              fft_block.v assumes (2 bits per pair of stages)
#   natural_order              so bin 7 really is bin 7. The default is bit
#                              reversed, which would scramble peak_bin
#   convergent_rounding        truncation biases every stage the same way and
#                              piles the error up in bin 0, rounding gives a
#                              noticeably better noise floor for a few LUTs
#   aresetn true               the RTL drives it, and without this the port
#                              does not exist and elaboration fails
#   nonrealtime                the core is allowed to drop tready and expects
#                              us to hold off, which fft_block now does

generate_target all [get_files xfft_0.xci]

# ----------------------------------------------------------------------------
# Optional actions
# ----------------------------------------------------------------------------
if {$action eq "sim"} {
    puts "\n=== running the testbench ===\n"
    launch_simulation
    run all
    close_sim
}

if {$action eq "synth"} {
    puts "\n=== synthesising ===\n"
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        puts "ERROR: synthesis did not finish"
        exit 1
    }
    open_run synth_1 -name synth_1
    report_utilization -file [file join $build_dir utilization.rpt]
    report_timing_summary -file [file join $build_dir timing.rpt]
    puts "\n=== reports written to $build_dir ===\n"
}

puts "\n=== done ===\n"

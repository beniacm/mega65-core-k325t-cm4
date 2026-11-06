
# Assume that if the Makefile runs this step we have to start all over.
reimport_files
reset_project

# Synthesis is NOT timing driven for this target: with the DDR3 attic RAM (MIG
# black box + live expansion-RAM path) synth_design's "Timing Optimization" phase
# never finished (>20 min at 100 % CPU, twice).  Placement/routing stay timing
# driven; the design has >1 ns slack.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-no_timing_driven} -objects [get_runs synth_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1

launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1

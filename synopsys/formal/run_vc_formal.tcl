# ==============================================================================
# Formal Property Verification (VC Formal / SVA) - rvx_core
# ==============================================================================
# Run via ./scripts/run_formal.sh, or from synopsys/formal:
#   vc_static_shell -fml_ultra -f run_vc_formal.tcl
# (-fml_ultra is required: the CADMICRO license server only has legacy features)
# ==============================================================================

set_fml_appmode FPV

# 1. Read RTL + SVA checker (bound into rvx_core)
read_file -top rvx_core -format sverilog -sva -vcs {-f rvx_core_formal.f}

# 2. Clock and reset (rvx_core reset is active-high)
create_clock clock -period 100
create_reset reset -sense high

# 3. Initialize the design from reset
sim_run -stable
sim_save_reset

# 4. Prove all assertions and covers
check_fv -block

# 5. Reports
report_fv -list > property_report.rpt
report_fv -verbose >> property_report.rpt

# 6. Optional: save counterexample FSDBs (no GUI needed)
#    VCF_TRACE_PROPS="ast_a ast_b" -> traces/<prop>.fsdb
if {[info exists ::env(VCF_TRACE_PROPS)]} {
  file mkdir traces
  foreach p $::env(VCF_TRACE_PROPS) {
    # catch: a bad property name must not stop the script before 'quit'
    if {[catch {fv_trace_save -include_reset_cycle -property "rvx_core.u_rvx_core_sva.$p" -fsdb_file [file normalize traces/$p.fsdb]}]} {
      puts "WARNING: no trace saved for '$p' (check the property name in property_report.rpt)"
    }
  }
}

# 7. Optional: formal core (which DUT registers the proven properties rely on)
#    VCF_FORMAL_CORE=1 -> formal_core.rpt, formal_core_uncovered.txt,
#                         formal_core_total.txt (total DUT flop bits)
if {[info exists ::env(VCF_FORMAL_CORE)]} {
  compute_formal_core -block
  redirect -file formal_core.rpt {
    report_formal_core -property [get_props -status {proven}] -verbose -bit
  }
  set fh [open formal_core_uncovered.txt w]
  foreach_in_collection r [get_formal_core -complement -registers] {
    puts $fh [get_object_name $r]
  }
  close $fh
  set fh [open formal_core_total.txt w]
  puts $fh [sizeof_collection [get_sequentials]]
  close $fh
}

if {![info exists ::env(VCF_GUI)]} {
  quit
}

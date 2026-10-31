#!/bin/bash
# Run VC Formal (FPV) on rvx_core with the SVA checker in synopsys/formal.
#
# Usage:
#   ./scripts/run_formal.sh                    # batch run, prints property summary
#   ./scripts/run_formal.sh gui                # GUI, for counterexample debug
#   ./scripts/run_formal.sh trace <prop> ...   # batch run + counterexample table
#                                              # per property (no GUI / X11 needed)
#
# The CADMICRO license server only has legacy VC Formal features, so the tool
# must be started with -fml_ultra (the default fml_base/fml_fv modes fail with
# LICENSE_CHECKOUT_ERROR).

set -e

MODE="${1:-batch}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMAL_DIR="$ROOT/synopsys/formal"

# Signals shown in counterexample tables (override with CEX_SIGNALS="...")
CEX_SIGNALS="${CEX_SIGNALS:-reset current_state program_counter instruction \
misaligned_instruction_address illegal_instruction take_trap \
integer_file_write_enable instruction_rd_address csr_mepc}"

module load vc_formal

cd "$FORMAL_DIR"
rm -rf vcst_rtdb .vcst_rtdb

echo "=============================================="
echo " RVX Core Formal Verification (VC Formal FPV)"
echo "=============================================="

if [ "$MODE" = "gui" ]; then
  VCF_GUI=1 vc_static_shell -fml_ultra -gui -f run_vc_formal.tcl
  exit 0
fi

if [ "$MODE" = "trace" ]; then
  shift
  if [ $# -eq 0 ]; then
    echo "Usage: $0 trace <property> [<property> ...]"
    exit 1
  fi
  export VCF_TRACE_PROPS="$*"
fi

vc_static_shell -fml_ultra -f run_vc_formal.tcl > vc_formal.log 2>&1 || true
if [ ! -f property_report.rpt ]; then
  echo "ERROR: formal run did not complete, see $FORMAL_DIR/vc_formal.log"
  grep -E "^\[Error\]|^Error" vc_formal.log | head -5
  exit 1
fi
sed -n '/Property List/,$p' property_report.rpt | grep -E "^\s+\[ *[0-9]+\]"
echo
echo "Full report: $FORMAL_DIR/property_report.rpt"

if [ "$MODE" = "trace" ]; then
  module load verdi
  for PROP in $VCF_TRACE_PROPS; do
    echo
    echo "=== Counterexample: $PROP"
    if [ ! -f "traces/$PROP.fsdb" ]; then
      echo "No trace saved (property not falsified?)"
      continue
    fi
    fsdb2vcd "traces/$PROP.fsdb" -o "traces/$PROP.vcd" > /dev/null 2>&1
    python3 "$ROOT/scripts/cex_table.py" "traces/$PROP.vcd" $CEX_SIGNALS
    echo "FSDB (open in Verdi): $FORMAL_DIR/traces/$PROP.fsdb"
  done
fi

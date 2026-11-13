#bash.sh - Synopys
set -e
# ============================================================
# 1. Load Synopsys and RISC-V tools
# ============================================================
module load vcs verdi
module load riscv64-elf/14.2.0

# ============================================================
# 2. Compile RVX with VCS
# ============================================================
mkdir -p synopsys/log
mkdir -p sim/results/dumps

vcs -full64 \
  -f synopsys/filelist/rvx_core.f \
  -v2005 \
  -sverilog \
  -timescale=1ns/1ps \
  -debug_access+all \
  -kdb \
  -l synopsys/log/add-01_comp.log

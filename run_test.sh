#!/bin/bash

set -e

TEST_NAME="${1:-add-01}"


PROGRAMS_DIR="dut/rvx/hardware/tests/core/unit_tests/programs"
REFERENCES_DIR="dut/rvx/hardware/tests/core/unit_tests/references"

PROGRAM_FILE="${PROGRAMS_DIR}/${TEST_NAME}.hex"
REFERENCE_FILE="${REFERENCES_DIR}/${TEST_NAME}.reference.hex"

if [[ ! -f "$PROGRAM_FILE" ]]; then
    echo "ERROR: Test program not found: $PROGRAM_FILE" >&2
    exit 1
fi

if [[ ! -f "$REFERENCE_FILE" ]]; then
    echo "ERROR: Reference file not found: $REFERENCE_FILE" >&2
    exit 1
fi
FILELIST="synopsys/filelist/rvx_core.f"
COMP_LOG="synopsys/log/${TEST_NAME}_comp.log"
RUN_LOG="synopsys/log/${TEST_NAME}.log"

echo "=============================================="
echo " RVX Core Verification"
echo " Test: $TEST_NAME"
echo "=============================================="

module load vcs verdi
module load riscv64-elf/14.2.0

mkdir -p synopsys/log
mkdir -p sim/results/dumps

echo
echo "[1/2] Compiling with VCS..."

vcs -full64 \
  -f "$FILELIST" \
  -v2005 \
  -sverilog \
  -timescale=1ns/1ps \
  -debug_access+all \
  -kdb \
  -l "$COMP_LOG"

echo
echo "[2/2] Running simulation..."

./simv \
  +TEST_NAME="$TEST_NAME" \
  -l "$RUN_LOG"

echo
echo "=============================================="
echo " TEST FINISHED: $TEST_NAME"
echo "=============================================="

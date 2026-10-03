#!/bin/bash
# ==============================================================================
# Script: run_all_tests.sh
# Description: Compiles RVX core once and runs all 54 unit tests sequentially.
#              Generates a summary pass/fail regression report.
# Usage:       ./scripts/run_all_tests.sh
# ==============================================================================

set -e

FILELIST="synopsys/filelist/rvx_core.f"
COMP_LOG="synopsys/log/regression_comp.log"
REPORT_FILE="sim/results/regression_report.txt"

PROGRAMS_DIR="dut/rvx/hardware/tests/core/unit_tests/programs"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

mkdir -p synopsys/log
mkdir -p sim/results/dumps

echo -e "${BLUE}=============================================="
echo -e " RVX Core Full Regression Suite"
echo -e "==============================================${NC}"

# Check environment
if ! command -v vcs &> /dev/null; then
    echo -e "${YELLOW}Notice: Loading Synopsys modules...${NC}"
    module load vcs verdi 2>/dev/null || true
    module load riscv64-elf/14.2.0 2>/dev/null || true
fi

echo -e "${BLUE}[1/2] Compiling RVX core testbench with VCS...${NC}"
vcs -full64 \
  -f "$FILELIST" \
  -v2005 \
  -sverilog \
  -timescale=1ns/1ps \
  -debug_access+all \
  -kdb \
  -l "$COMP_LOG"

echo -e "${GREEN}Compilation completed successfully.${NC}"
echo

# Find all test names
TEST_FILES=$(ls -1 ${PROGRAMS_DIR}/*.hex | sed 's#.*/##; s#\.hex$##' | sort)

PASSED=0
FAILED=0
TOTAL=0

PASSED_LIST=""
FAILED_LIST=""

echo "==============================================" > "$REPORT_FILE"
echo " RVX CORE REGRESSION REPORT - $(date)" >> "$REPORT_FILE"
echo "==============================================" >> "$REPORT_FILE"
printf "%-25s | %s\n" "TEST NAME" "RESULT" >> "$REPORT_FILE"
echo "----------------------------------------------" >> "$REPORT_FILE"

echo -e "${BLUE}[2/2] Running all 54 unit tests...${NC}"
echo "------------------------------------------------------------"
printf "%-30s | %-10s\n" "TEST NAME" "STATUS"
echo "------------------------------------------------------------"

for TEST_NAME in $TEST_FILES; do
    TOTAL=$((TOTAL + 1))
    RUN_LOG="synopsys/log/${TEST_NAME}.log"

    # Run test simulation (allow non-zero exit code to catch $fatal)
    set +e
    ./simv +TEST_NAME="$TEST_NAME" -l "$RUN_LOG" > /dev/null 2>&1
    EXIT_CODE=$?
    set -e

    if grep -q "PASS: $TEST_NAME" "$RUN_LOG"; then
        PASSED=$((PASSED + 1))
        PASSED_LIST="${PASSED_LIST}  - ${TEST_NAME}\n"
        printf "%-30s | ${GREEN}PASS${NC}\n" "$TEST_NAME"
        printf "%-25s | PASS\n" "$TEST_NAME" >> "$REPORT_FILE"
    else
        FAILED=$((FAILED + 1))
        FAILED_LIST="${FAILED_LIST}  - ${TEST_NAME}\n"
        printf "%-30s | ${RED}FAIL${NC}\n" "$TEST_NAME"
        printf "%-25s | FAIL\n" "$TEST_NAME" >> "$REPORT_FILE"
    fi
done

echo "------------------------------------------------------------"
echo "==============================================" >> "$REPORT_FILE"
echo " REGRESSION SUMMARY" >> "$REPORT_FILE"
echo "==============================================" >> "$REPORT_FILE"
echo "Total Tests : $TOTAL" >> "$REPORT_FILE"
echo "Passed      : $PASSED" >> "$REPORT_FILE"
echo "Failed      : $FAILED" >> "$REPORT_FILE"

echo -e "${BLUE}=============================================="
echo -e " REGRESSION COMPLETED"
echo -e " Total: $TOTAL | ${GREEN}Passed: $PASSED${NC} | ${RED}Failed: $FAILED${NC}"
echo -e " Report saved to: $REPORT_FILE"
echo -e "==============================================${NC}"

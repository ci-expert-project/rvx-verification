# RVX Code Coverage Analysis

## 1. Objective

This document describes the code coverage analysis performed on the RVX RISC-V core using Synopsys VCS and URG.

The objective is to establish a coverage baseline for the existing functional regression, identify coverage gaps, and provide metrics to support future verification activities.

## 2. Verification Environment

The verification environment uses the following tools:

- **Simulator:** Synopsys VCS W-2024.09-SP2-3_Full64
- **Coverage analysis:** Synopsys URG W-2024.09-SP2-3
- **Coverage database format:** VDB
- **Top-level testbench:** `rvx_core_tb`

The coverage instrumentation was enabled for the following metrics:

- Line coverage
- Condition coverage
- Branch coverage
- Toggle coverage
- FSM coverage

### 2.1 Source Files

The main RTL and testbench files used in the analysis are:

```text
dut/rvx/hardware/rvx_core.v
dut/rvx/hardware/rvx_ram.v
synopsys/tb/rvx_core_tb.sv
```

## 3. Functional Regression Results

The regression contains 54 tests.

| Result | Tests | Percentage |
|---|---:|---:|
| PASS | 46 | 85.19% |
| FAIL | 8 | 14.81% |
| **Total** | **54** | **100%** |

The following eight tests failed:

```text
misalign2-jalr-01
misalign-beq-01
misalign-bge-01
misalign-bgeu-01
misalign-blt-01
misalign-bltu-01
misalign-bne-01
misalign-jal-01
```

These failures are associated with misaligned branch and jump instruction addresses, a limitation documented in the current RVX implementation.

The functional classification is based on:

```text
synopsys/coverage/regression/summary.tsv
```

## 4. Coverage Collection and Consolidation

Individual coverage databases were generated for the 54 regression tests.

The databases are stored in:

```text
synopsys/coverage/regression/database/
```

The experimental database used as the design reference is:

```text
synopsys/coverage/database/add-01.vdb
```

The test selection file is:

```text
synopsys/coverage/merge_test/test_selection/all_54_tests.txt
```

It contains the 54 regression test database paths.

The final URG report was generated with:

```bash
urg \
  -dir synopsys/coverage/database/add-01.vdb \
       synopsys/coverage/regression/database/*.vdb \
  -tests synopsys/coverage/merge_test/test_selection/all_54_tests.txt \
  -report synopsys/coverage/final_report/report \
  -metric line+cond+branch+tgl+fsm \
  -format both \
  -log synopsys/coverage/final_report/merge.log
```

The experimental `add-01` database provides design metadata and is excluded from the 54-test report through the test selection file.

## 5. Coverage Results

The consolidated coverage report contains 54 tests.

| Coverage Metric | Coverage |
|---|---:|
| Line | 83.20% |
| Condition | 73.61% |
| Branch | 76.90% |
| Toggle | 65.69% |
| FSM | 62.50% |
| **URG Overall Score** | **72.38** |

The overall score is the aggregate score reported by URG and should not be interpreted as the arithmetic mean of the individual metrics.

## 6. Analysis and Interpretation

The results indicate that line coverage is the highest metric, reaching 83.20%.

Condition and branch coverage reached 73.61% and 76.90%, respectively, indicating that additional verification scenarios may be required to exercise untested decision paths.

Toggle coverage reached 65.69%, suggesting that some signal transitions were not exercised during the regression.

FSM coverage reached 62.50%, indicating opportunities to improve state-transition coverage.

These results provide a baseline for identifying verification gaps and planning additional tests.

## 7. Scope and Limitations

The coverage report was generated for the top-level hierarchy `rvx_core_tb`.

Therefore, the reported metrics include the instantiated design and testbench hierarchy, including:

- `rvx_core`
- `rvx_ram`
- `rvx_core_tb`

The overall score of 72.38 is not an isolated measurement of `rvx_core`.

The analysis is limited to the existing 54-test regression and the coverage metrics enabled during compilation and simulation. It does not establish exhaustive functional verification of the RVX implementation.

## 8. Generated Artifacts

The final report is available under:

```text
synopsys/coverage/final_report/report/
```

Main report files:

```text
dashboard.html
dashboard.txt
hierarchy.html
modlist.html
tests.html
```

The merge log is available at:

```text
synopsys/coverage/final_report/merge.log
```

Individual VDB databases and generated reports are retained locally for further analysis.

Generated databases, simulation outputs, logs, and executable files are not part of this documentation commit.

## 9. Baseline Summary

The RVX code coverage analysis established the following baseline:

- 54 regression tests analyzed.
- 46 tests passed and 8 tests failed.
- URG overall coverage score: 72.38.
- Highest metric: Line coverage (83.20%).
- Lowest metric: FSM coverage (62.50%).

These results provide a reference for future improvements to the RVX verification environment and regression suite.

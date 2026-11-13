#!/usr/bin/env python3
"""
Convert the VC Formal property report into Verdi Planner user data.

Reads the 'Property List' of property_report.rpt (written by run_vc_formal.tcl)
and writes an HVP user data file with the 'formal' metric declared in
synopsys/plan/rvx.hvp:

  HVP metric = formal
  ast_mret_to_mepc = proven
  ast_mepc_is_faulting_pc = falsified
  cov_ecall_trap = covered

  ./scripts/formal_status_to_hvp.py                       # default paths
  ./scripts/formal_status_to_hvp.py <report.rpt> <out.data> [<plan.hvp>]

A proven assertion whose antecedent can never happen is reported as 'vacuous'
(it proves nothing). Assumptions ('constrained') are not requirements and are
skipped.

If the plan is given, the script also checks traceability in both directions:
properties used in the plan but missing from the report (they would silently
show no result) and properties in the report not linked to any requirement.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_REPORT = os.path.join(ROOT, "synopsys", "formal", "property_report.rpt")
DEFAULT_DATA = os.path.join(ROOT, "synopsys", "plan", "rvx_formal.data")
DEFAULT_PLAN = os.path.join(ROOT, "synopsys", "plan", "rvx.hvp")

# Values of the 'formal' enum metric in rvx.hvp
KNOWN_STATUS = {"proven", "covered", "falsified", "uncoverable", "vacuous", "inconclusive"}

# [  16] falsified   (depth=7)    (non_vacuous)  -  rvx_core.u_rvx_core_sva.ast_mepc_is_faulting_pc
LINE_RE = re.compile(r"^\s+\[\s*\d+\]\s+(\w+)(.*?)\s+-\s+(\S+)\s*$")

# "ast_x", "cov_y" inside source = "..." of the plan
PLAN_PROP_RE = re.compile(r'"((?:ast|cov)_\w+)"')


def read_report(path):
    """Return {short property name: formal status} from the Property List."""
    status = {}
    in_list = False
    with open(path) as f:
        for line in f:
            if "Property List" in line:
                in_list = True
                continue
            if in_list and "Verbose Results" in line:
                break
            if not in_list:
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            tool_status, tags, full_name = m.groups()
            if tool_status == "constrained":
                continue
            name = full_name.split(".")[-1]
            if tool_status == "proven" and "(vacuous)" in tags:
                st = "vacuous"
            elif tool_status in KNOWN_STATUS:
                st = tool_status
            else:
                # Anything not understood (not run, error...) must not pass the goal
                print("WARNING: %s has unknown status '%s', reported as inconclusive"
                      % (name, tool_status), file=sys.stderr)
                st = "inconclusive"
            status[name] = st
    return status


def plan_properties(path):
    with open(path) as f:
        text = "\n".join(l.split("//", 1)[0] for l in f)
    return set(PLAN_PROP_RE.findall(text))


def main():
    args = sys.argv[1:]
    report = args[0] if len(args) > 0 else DEFAULT_REPORT
    data = args[1] if len(args) > 1 else DEFAULT_DATA
    plan = args[2] if len(args) > 2 else (DEFAULT_PLAN if not args else None)

    status = read_report(report)
    if not status:
        sys.exit("ERROR: no properties found in %s" % report)

    with open(data, "w") as f:
        f.write("HVP metric = formal\n")
        for name in sorted(status):
            f.write("%s = %s\n" % (name, status[name]))

    counts = {}
    for st in status.values():
        counts[st] = counts.get(st, 0) + 1
    print("Wrote %s: %d properties (%s)" % (
        data, len(status), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))

    if plan and os.path.exists(plan):
        in_plan = plan_properties(plan)
        missing = sorted(in_plan - set(status))
        untraced = sorted(set(status) - in_plan)
        if missing:
            print("WARNING: in %s but not in the report (no result):" % os.path.basename(plan))
            for n in missing:
                print("  " + n)
        if untraced:
            print("WARNING: in the report but not linked to any requirement:")
            for n in untraced:
                print("  " + n)
        if not missing and not untraced:
            print("Traceability OK: all %d properties linked to a requirement" % len(status))


if __name__ == "__main__":
    main()

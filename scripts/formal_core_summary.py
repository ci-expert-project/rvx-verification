#!/usr/bin/env python3
"""
Summarize the VC Formal formal core of all proven properties.

The formal core of a proven property is the set of design registers the
engines needed for the proof. The union over all proven properties shows
which part of the DUT state is actually checked by the assertions; registers
outside it are not verified by any proof.

  ./scripts/formal_core_summary.py synopsys/formal

Reads formal_core.rpt, formal_core_uncovered.txt and formal_core_total.txt,
written by run_vc_formal.tcl when VCF_FORMAL_CORE is set.
"""

import collections
import os
import re
import sys

# Registers of the bound SVA checker are not part of the DUT
CHECKER_INSTANCE = "u_rvx_core_sva."


def covered_bits(rpt_path):
    """Union of register bits listed under '#Registers' in the verbose report."""
    bits = set()
    in_regs = False
    with open(rpt_path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("#Registers"):
                in_regs = True
                continue
            if not s or s.startswith("#") or ":" in s:
                in_regs = False
                continue
            if in_regs and CHECKER_INSTANCE not in s:
                bits.add(s)
    return bits


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    bits = covered_bits(os.path.join(d, "formal_core.rpt"))
    with open(os.path.join(d, "formal_core_uncovered.txt")) as f:
        uncovered = sorted(l.strip() for l in f if l.strip())
    with open(os.path.join(d, "formal_core_total.txt")) as f:
        total = int(f.read().strip())

    by_reg = collections.Counter(re.sub(r"\[\d+\]$", "", b) for b in bits)
    pct = 100.0 * len(bits) / total if total else 0.0

    print("Formal core (union of proven properties)")
    print(f"  DUT flop bits in formal core : {len(bits)} / {total} ({pct:.1f}%)")
    print(f"  DUT registers in formal core : {len(by_reg)} / {len(by_reg) + len(uncovered)}")
    print()
    print("Covered registers (bits):")
    for name, n in sorted(by_reg.items()):
        print(f"  {n:5}  {name}")
    print()
    print("Registers not used by any proof:")
    for name in uncovered:
        print(f"  {name}")


if __name__ == "__main__":
    main()

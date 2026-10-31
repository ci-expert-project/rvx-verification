#!/usr/bin/env python3
"""
Print selected signals of a VCD file as a cycle-by-cycle table.

Useful to inspect VC Formal counterexamples without the GUI:
  fsdb2vcd cex.fsdb -o cex.vcd
  ./scripts/cex_table.py cex.vcd instruction take_trap integer_file_write_enable

Values are sampled right before each rising edge of the clock, i.e. the value
each signal holds during that cycle. Signals are matched by name under the
first scope that contains them (use scope.name to disambiguate).
"""

import argparse
import sys


def parse_vcd(path):
    """Return (signals, changes): signals maps full name -> (id, width),
    changes is a list of (time, id, value) in file order."""
    signals = {}
    changes = []
    scope = []
    time = 0
    with open(path) as f:
        in_defs = True
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if in_defs:
                if tok[0] == "$scope":
                    scope.append(tok[2])
                elif tok[0] == "$upscope":
                    scope.pop()
                elif tok[0] == "$var":
                    width, ident, name = int(tok[2]), tok[3], tok[4]
                    full = ".".join(scope + [name])
                    signals.setdefault(full, (ident, width))
                elif tok[0] == "$enddefinitions":
                    in_defs = False
                continue
            t = tok[0]
            if t.startswith("#"):
                time = int(t[1:])
            elif t[0] in "bBrR":
                changes.append((time, tok[1], t[1:]))
            elif t[0] in "01xXzZ":
                changes.append((time, t[1:], t[0]))
    return signals, changes


def find_signal(signals, name):
    """Shortest full name ending in '.name' (closest to the top)."""
    matches = [s for s in signals if s == name or s.endswith("." + name)]
    if not matches:
        sys.exit(f"signal not found: {name}")
    return min(matches, key=lambda s: s.count("."))


def fmt(value, width):
    if width == 1 or any(c in value for c in "xXzZ"):
        return value
    return f"{int(value, 2):0{(width + 3) // 4}x}"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd")
    ap.add_argument("signals", nargs="+")
    ap.add_argument("--clock", default="clock")
    args = ap.parse_args()

    signals, changes = parse_vcd(args.vcd)
    clk_id = signals[find_signal(signals, args.clock)][0]
    cols = [(n, *signals[find_signal(signals, n)]) for n in args.signals]

    current = {}
    rows = []
    i = 0
    while i < len(changes):
        t = changes[i][0]
        batch = []
        while i < len(changes) and changes[i][0] == t:
            batch.append(changes[i])
            i += 1
        rising = any(ident == clk_id and val == "1" and current.get(clk_id) == "0"
                     for _, ident, val in batch)
        if rising:
            rows.append([fmt(current.get(ident, "x"), w) for _, ident, w in cols])
        for _, ident, val in batch:
            current[ident] = val

    widths = [max(len(n), *(len(r[k]) for r in rows)) if rows else len(n)
              for k, (n, _, _) in enumerate(cols)]
    print("cycle  " + "  ".join(n.ljust(w) for (n, _, _), w in zip(cols, widths)))
    for c, r in enumerate(rows):
        print(f"{c:<5}  " + "  ".join(v.ljust(w) for v, w in zip(r, widths)))


if __name__ == "__main__":
    main()

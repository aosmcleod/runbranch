#!/usr/bin/env bash
#
# Checks the engine for the mistakes this file has actually made, rather than
# style. Run it before committing.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "==> bash syntax"
/bin/bash -n "$REPO/runbranch.sh" || FAIL=1

# Bash expands every argument to `local` before assigning any of them, so a
# later assignment referring to an earlier name in the SAME statement silently
# reads the unset global. Under `set -u` that aborts, and it has bitten this
# file three times.
echo "==> local self-reference"
python3 - "$REPO/runbranch.sh" <<'PY' || FAIL=1
import re, sys
bad = []
for i, line in enumerate(open(sys.argv[1]), 1):
    st = line.strip()
    if not st.startswith('local '): continue
    parts = re.findall(r'(?:[^\s"\']|"[^"]*"|\'[^\']*\')+', st[6:])
    declared = []
    for p in parts:
        name, _, rhs = p.partition('=')
        for d in declared:
            if re.search(r'\$\{?' + re.escape(d) + r'\b', rhs):
                bad.append((i, d, st)); break
        declared.append(name)
for i, d, st in bad:
    print(f"  line {i}: ${d} read in the same `local` that declares it")
    print(f"    {st}")
sys.exit(1 if bad else 0)
PY
# A function defined twice is silently the second one. Two identical copies of
# the favourites block sat 1,200 lines apart in this file and nothing complained
# — harmless only because they had not yet diverged.
echo "==> duplicate definitions"
python3 - "$REPO/runbranch.sh" <<'DUP' || FAIL=1
import re, sys
from collections import defaultdict
seen = defaultdict(list)
for i, line in enumerate(open(sys.argv[1]), 1):
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', line)
    if m:
        seen[m.group(1)].append(i)
        continue
    m = re.match(r'^([A-Z_][A-Z0-9_]*)=', line)
    if m:
        seen[m.group(1)].append(i)
dupes = {k: v for k, v in seen.items() if len(v) > 1}
for name, lines in sorted(dupes.items()):
    print("  %s defined %d times: lines %s"
          % (name, len(lines), ", ".join(map(str, lines))))
sys.exit(1 if dupes else 0)
DUP

[ "$FAIL" = 0 ] && echo "==> clean"
exit "$FAIL"

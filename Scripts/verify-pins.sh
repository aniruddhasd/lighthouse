#!/bin/sh
# Supply-chain gate: assert every revision in Package.resolved matches the
# canonical known-good value in Scripts/pinned-revisions.txt. Drift = loud
# failure pointing at the upgrade ritual, NOT silent acceptance.
# Usage: verify-pins.sh <Package.resolved> <pinned-revisions.txt>
set -eu

resolved="${1:?usage: verify-pins.sh <Package.resolved> <pinned-revisions.txt>}"
pins="${2:?usage: verify-pins.sh <Package.resolved> <pinned-revisions.txt>}"

if [ ! -f "$resolved" ]; then
    echo "SUPPLY-CHAIN FAIL: missing $resolved" >&2
    exit 1
fi

fail=0
while read -r identity expected; do
    case "$identity" in ''|\#*) continue ;; esac
    # Pull the revision recorded for this identity from Package.resolved.
    actual="$(python3 - "$resolved" "$identity" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for pin in data.get("pins", []):
    if pin.get("identity") == sys.argv[2]:
        print(pin.get("state", {}).get("revision", ""))
        break
PY
)"
    if [ "$actual" != "$expected" ]; then
        echo "SUPPLY-CHAIN FAIL: $identity revision drifted" >&2
        echo "  expected (canonical): $expected" >&2
        echo "  in Package.resolved:  ${actual:-<not found>}" >&2
        fail=1
    fi
done < "$pins"

if [ "$fail" -ne 0 ]; then
    echo "  A pinned dependency changed. Do NOT blindly accept it — run the ritual:" >&2
    echo "    /dep-audit  ->  review the upstream diff  ->  re-pin in Package.swift  ->  update $pins" >&2
    exit 1
fi
echo "SUPPLY-CHAIN OK: Package.resolved revisions match $pins"

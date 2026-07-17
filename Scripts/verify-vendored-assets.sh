#!/bin/sh
# Supply-chain gate: assert the vendored diff2html assets match the canonical
# checksums in their SHA256SUMS file (the single source of truth; the doc
# references it, no hashes are duplicated). Any mismatch fails the build with
# both hashes named. Usage: verify-vendored-assets.sh <asset-dir>
set -eu

dir="${1:?usage: verify-vendored-assets.sh <asset-dir>}"
sums="$dir/SHA256SUMS"

if [ ! -f "$sums" ]; then
    echo "SUPPLY-CHAIN FAIL: missing $sums" >&2
    exit 1
fi

# shasum -c prints "<file>: OK" / "<file>: FAILED" and exits non-zero on any
# mismatch or missing file. Run from the asset dir so the relative names match.
if ! ( cd "$dir" && shasum -a 256 -c SHA256SUMS ); then
    echo "SUPPLY-CHAIN FAIL: vendored diff2html assets do not match $sums" >&2
    echo "  A vendored asset was modified or replaced. Expected (canonical):" >&2
    sed 's/^/    /' "$sums" >&2
    echo "  Actual:" >&2
    ( cd "$dir" && for f in $(awk '{print $2}' SHA256SUMS); do
        printf '    %s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"
    done ) >&2
    echo "  Do NOT accept blindly: re-verify the asset upstream, then update SHA256SUMS." >&2
    exit 1
fi
echo "SUPPLY-CHAIN OK: vendored diff2html assets match SHA256SUMS"

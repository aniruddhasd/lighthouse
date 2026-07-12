#!/bin/sh
# Smoke check for the assembled app (SwiftUI/SwiftTerm layers that unit tests
# cannot reach): launch the bundle, verify the process stays alive and the
# attention socket exists with owner-only permissions, then quit cleanly and
# verify the socket was unlinked. Gated because it opens a real GUI window:
#
#   LIGHTHOUSE_SMOKE=1 Scripts/smoke-run.sh
set -eu

if [ "${LIGHTHOUSE_SMOKE:-}" != "1" ]; then
    echo "Set LIGHTHOUSE_SMOKE=1 to run (launches a real GUI app)." >&2
    exit 0
fi

package_root="$(cd "$(dirname "$0")/.." && pwd)"
socket="$HOME/Library/Application Support/Lighthouse/attention.sock"

"$package_root/Scripts/make-app.sh" release

"$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true' EXIT

# Socket must appear with 0600.
tries=0
until [ -S "$socket" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
        echo "FAIL: socket never appeared at $socket" >&2
        exit 1
    fi
    sleep 0.2
done
perms="$(stat -f '%Lp' "$socket")"
if [ "$perms" != "600" ]; then
    echo "FAIL: socket permissions are $perms, expected 600" >&2
    exit 1
fi

# Process must still be alive after settling.
sleep 2
if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "FAIL: app exited prematurely" >&2
    exit 1
fi

# Clean quit (no working sessions → no confirmation): SIGTERM runs the
# normal termination path, which unlinks the socket.
kill -TERM "$app_pid"
tries=0
while kill -0 "$app_pid" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
        echo "FAIL: app did not quit within 10s" >&2
        exit 1
    fi
    sleep 0.2
done
trap - EXIT

if [ -e "$socket" ]; then
    echo "FAIL: socket not unlinked on quit" >&2
    exit 1
fi

echo "SMOKE OK: launched, socket 0600, stayed alive, quit cleanly, socket unlinked."

# --- Geometry check: the terminal-sizing regression gate -------------------
# The 2026-07-12 sizing bug lived in SwiftUI layout, which unit tests cannot
# reach (no window server). LIGHTHOUSE_DEBUG_GEOMETRY=1 renders an ephemeral
# /bin/cat probe session, logs terminal/container/window frames on every
# layout pass, and auto-resizes the window once; we assert the terminal fills
# the pane at BOTH window sizes. An isolated config dir keeps the user's
# config and any live instance's socket untouched.
geometry_log="$(mktemp)"
geometry_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_GEOMETRY=1 LIGHTHOUSE_CONFIG_DIR="$geometry_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$geometry_log" 2>&1 &
geo_pid=$!
trap 'kill -9 "$geo_pid" 2>/dev/null || true' EXIT
sleep 6
kill -9 "$geo_pid" 2>/dev/null || true
trap - EXIT
rm -rf "$geometry_cfg"

python3 - "$geometry_log" <<'PY'
import re, sys

rx = re.compile(r"GEOMETRY window=(\d+)x(\d+) container=(\d+)x(\d+) terminal=(\d+)x(\d+)")
samples = [tuple(map(int, m.groups()))
           for line in open(sys.argv[1])
           if (m := rx.search(line)) and int(m.group(1)) > 0]
assert samples, "no geometry lines — probe session never rendered"

# Last settled sample per window WIDTH: the run has exactly two widths (the
# default frame, then the scripted 1000pt resize); heights fluctuate briefly
# while the toolbar settles, so the final sample per width is the truth.
final = {}
for ww, wh, cw, ch, tw, th in samples:
    final[ww] = (ww, wh, cw, ch, tw, th)
assert len(final) >= 2, f"need two window sizes, saw widths {sorted(final)}"

for ww, wh, cw, ch, tw, th in final.values():
    assert abs(tw - cw) <= 2 and abs(th - ch) <= 2, \
        f"terminal {tw}x{th} != container {cw}x{ch} at window {ww}x{wh}"
    assert th >= wh - 60, \
        f"terminal height {th} does not fill window content height {wh}"
    assert tw >= 420, f"terminal width {tw} below the pane minimum"

report = ", ".join(f"window {ww}x{wh} -> terminal {tw}x{th}"
                   for ww, wh, cw, ch, tw, th in sorted(final.values()))
print(f"GEOMETRY OK: {report}")
PY
rm -f "$geometry_log"

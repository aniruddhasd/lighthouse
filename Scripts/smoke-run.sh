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
# layout pass, and — event-driven from the first real layout — resizes the
# window once so the check sees two widths. Every stage has its own deadline
# and failure message; no fixed sleeps, no kill-and-hope. An isolated config
# dir keeps the user's config and any live instance's socket untouched.
geometry_log="$(mktemp)"
geometry_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_GEOMETRY=1 LIGHTHOUSE_CONFIG_DIR="$geometry_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$geometry_log" 2>&1 &
geo_pid=$!
trap 'kill -9 "$geo_pid" 2>/dev/null || true; rm -rf "$geometry_cfg"' EXIT

# wait_for <deadline-seconds> <stage-name> <grep-pattern>
wait_for() {
    deadline=$((($1) * 5))
    i=0
    while ! grep -qE "$3" "$geometry_log"; do
        i=$((i + 1))
        if [ "$i" -gt "$deadline" ]; then
            echo "GEOMETRY GATE: FAIL ($2 within $1s)" >&2
            grep -E "GEOMETRY" "$geometry_log" | tail -5 >&2 || true
            exit 1
        fi
        if ! kill -0 "$geo_pid" 2>/dev/null; then
            echo "GEOMETRY GATE: FAIL (app exited during stage: $2)" >&2
            exit 1
        fi
        sleep 0.2
    done
}

wait_for 20 "first-layout-never-logged (window never appeared or probe never rendered)" \
    "GEOMETRY-STAGE first-layout"
# resize-applied is emitted only after the driver OBSERVED the window change
# size (exact values are SwiftUI-clamped and vary per context; the contract
# is "a different size", not a specific one).
wait_for 20 "resize-never-observed" "GEOMETRY-STAGE resize-applied|GEOMETRY-STAGE resize-failed"
if grep -q "GEOMETRY-STAGE resize-failed" "$geometry_log"; then
    echo "GEOMETRY GATE: FAIL (window refused every resize candidate)" >&2
    grep "GEOMETRY-STAGE" "$geometry_log" | tail -8 >&2
    exit 1
fi
# The driver prints the two authoritative sizes; wait for a LAYOUT sample at
# each (SwiftUI coalesces layout passes, so samples can trail the stage
# lines — never assume log order).
baseline_size="$(sed -n 's/.*GEOMETRY-STAGE baseline content=\([0-9]*x[0-9]*\).*/\1/p' "$geometry_log" | head -1)"
resized_size="$(sed -n 's/.*GEOMETRY-STAGE resize-applied observed=\([0-9]*x[0-9]*\).*/\1/p' "$geometry_log" | head -1)"
wait_for 10 "no-layout-sample-at-baseline-size-$baseline_size" "GEOMETRY window=$baseline_size "
wait_for 10 "no-layout-sample-at-resized-size-$resized_size" "GEOMETRY window=$resized_size "
sleep 0.5

kill -TERM "$geo_pid" 2>/dev/null || true
tries=0
while kill -0 "$geo_pid" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 25 ]; then
        kill -9 "$geo_pid" 2>/dev/null || true
        break
    fi
    sleep 0.2
done
trap - EXIT
rm -rf "$geometry_cfg"

python3 - "$geometry_log" "$baseline_size" "$resized_size" <<'PY'
import re, sys

log_path, baseline, resized = sys.argv[1], sys.argv[2], sys.argv[3]
sample_rx = re.compile(r"GEOMETRY window=(\d+)x(\d+) container=(\d+)x(\d+) terminal=(\d+)x(\d+)")
by_size = {}
for line in open(log_path):
    if m := sample_rx.search(line):
        ww, wh, cw, ch, tw, th = map(int, m.groups())
        by_size[f"{ww}x{wh}"] = (ww, wh, cw, ch, tw, th)

def check(label, size):
    sample = by_size.get(size)
    if sample is None:
        print(f"GEOMETRY {label}: no layout sample at {size} -> FAIL")
        return False
    ww, wh, cw, ch, tw, th = sample
    problems = []
    if abs(tw - cw) > 2 or abs(th - ch) > 2:
        problems.append(f"terminal {tw}x{th} != container {cw}x{ch}")
    if th < wh - 60:
        problems.append(f"height {th} does not fill window content {wh}")
    if tw < 420:
        problems.append(f"width {tw} below pane minimum")
    verdict = "PASS" if not problems else "FAIL (" + "; ".join(problems) + ")"
    print(f"GEOMETRY {label}: window {ww}x{wh} terminal {tw}x{th} -> {verdict}")
    return not problems

ok = check("initial", baseline) & check("resized", resized)
bw, bh = map(int, baseline.split("x"))
rw, rh = map(int, resized.split("x"))
if abs(bw - rw) <= 40 and abs(bh - rh) <= 40:
    print(f"GEOMETRY GATE: FAIL (sizes did not differ: {baseline} vs {resized})")
    sys.exit(1)
if not ok:
    print("GEOMETRY GATE: FAIL (fill assertion)")
    sys.exit(1)
print("GEOMETRY GATE: PASS")
PY
rm -f "$geometry_log"

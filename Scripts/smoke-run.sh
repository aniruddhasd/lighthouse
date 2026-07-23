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

# Supply-chain gates up front (make-app re-runs them too, and its build uses
# --force-resolved-versions — this makes the gate independently fail fast).
"$package_root/Scripts/verify-vendored-assets.sh" \
    "$package_root/Sources/LighthouseApp/Resources/diff2html"
"$package_root/Scripts/verify-pins.sh" \
    "$package_root/Package.resolved" "$package_root/Scripts/pinned-revisions.txt"

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
# The feature must be wired, not just built: the placeholder must be gone
# from the app target (regression check for the step-5 integration miss).
if grep -rq "Live diff-vs-base lands in a later step" "$package_root/Sources/LighthouseApp"; then
    echo "REVIEWPANE GATE: FAIL (placeholder still present in the app target)" >&2
    exit 1
fi

# Fixture: a main repo plus a LINKED WORKTREE on a task branch — so the
# worktree's gitdir lives OUTSIDE the watched worktree tree (the real
# Lighthouse shape). The worktree has one tracked modification (1 changed
# file vs base) and one untracked file. Mid-run we commit a new file (a
# gitdir-only write) and assert the pane's file count updates — proving the
# stale-diff fix (2026-07-13) in the real app.
geometry_root="$(mktemp -d)"
geometry_main="$geometry_root/main"
geometry_repo="$geometry_root/wt"
mkdir -p "$geometry_main"
git -C "$geometry_main" init -q -b main
git -C "$geometry_main" config user.name smoke
git -C "$geometry_main" config user.email smoke@lighthouse.invalid
git -C "$geometry_main" config commit.gpgsign false
printf 'base\n' > "$geometry_main/tracked.txt"
git -C "$geometry_main" add tracked.txt
git -C "$geometry_main" commit -qm base
git -C "$geometry_main" worktree add -q -b task "$geometry_repo" main
printf 'changed\n' >> "$geometry_repo/tracked.txt"
printf 'brand new\n' > "$geometry_repo/untracked.txt"

geometry_log="$(mktemp)"
geometry_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_GEOMETRY=1 LIGHTHOUSE_DEBUG_REVIEWPANE="$geometry_repo" \
    LIGHTHOUSE_CONFIG_DIR="$geometry_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$geometry_log" 2>&1 &
geo_pid=$!
trap 'kill -9 "$geo_pid" 2>/dev/null || true; rm -rf "$geometry_cfg" "$geometry_root"' EXIT

# wait_for <deadline-seconds> <stage-name> <grep-pattern>
wait_for() {
    deadline=$((($1) * 5))
    i=0
    while ! grep -qE "$3" "$geometry_log"; do
        i=$((i + 1))
        if [ "$i" -gt "$deadline" ]; then
            echo "GATE: FAIL ($2 within $1s)" >&2
            grep -E "GEOMETRY|REVIEWPANE" "$geometry_log" | tail -8 >&2 || true
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
# The review pane must have rendered REAL content in the running app: the
# one tracked modification (files=1).
wait_for 15 "review-pane-never-populated" "REVIEWPANE-STAGE populated files=1"
sleep 0.5

# Stale-diff fix: commit a NEW file in the worktree — a gitdir-only write the
# worktree tree never sees. The gitdir watch must fire a refresh that raises
# the count to 2, with NO app restart and NO manual refresh.
printf 'committed\n' > "$geometry_repo/committed.txt"
git -C "$geometry_repo" add committed.txt
git -C "$geometry_repo" commit -qm "commit only"
wait_for 15 "commit-did-not-refresh-review-pane" "REVIEWPANE-STAGE populated files=2"

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
rm -rf "$geometry_cfg" "$geometry_root"

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
    # Phase 3 reshaped the center column: the terminal body now sits BELOW the
    # 52px task header + shell-tabs bar and ABOVE the 30px footer (≈111px of
    # chrome), where the old layout had only the ~28px tab bar. The fill
    # threshold is relaxed to that new true geometry (was wh-60) — a 181pt
    # collapse (the sizing scar) is still far below wh-170 at every window size,
    # so the assertion still bites.
    if th < wh - 170:
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

# Layout gate: Phase 3 retired the NavigationSplitView. The Focus area is now
# [ beacon rail (60px) | center column (flex) ]; the navigator is a 340px
# slide-in OVERLAY (closed by default), NOT a split column. This proves the
# fixed-width rail laid out at 60px and the center column + its body filled the
# remaining width/height, using the SwiftUI size probes (debugSize) the running
# app emits. (The retired centerStage/navigator/hsplit split-pane probes are
# gone; their geometry no longer exists.)
python3 - "$geometry_log" <<'PY'
import re, sys
rx = re.compile(r"GEOMETRY-SWIFTUI label=(\S+) size=(\d+)x(\d+)")
samples = {}
for line in open(sys.argv[1]):
    if m := rx.search(line):
        samples.setdefault(m.group(1), []).append((int(m.group(2)), int(m.group(3))))

def fills(label, wmin, wmax, hmin):
    seen = samples.get(label, [])
    ok = any(wmin <= w <= wmax and h >= hmin for w, h in seen)
    print(f"LAYOUT {label}: samples={seen[-3:]} -> {'PASS' if ok else 'FAIL'}")
    return ok

# The beacon rail is a FIXED 60px column; the center column + body fill the
# rest (>=420 wide). A regression that collapses either (or turns the rail into
# a flexible sidebar) fails here.
rail_ok = fills("beaconRail", 55, 65, 300)
column_ok = fills("centerColumn", 420, 100000, 300)
body_ok = fills("focusBody", 420, 100000, 200)
if not (rail_ok and column_ok and body_ok):
    print("LAYOUT GATE: FAIL (beacon rail / center column / body did not lay out)")
    sys.exit(1)
print("LAYOUT GATE: PASS")
PY

python3 - "$geometry_log" <<'PY'
import re, sys
populated = [m for l in open(sys.argv[1])
             if (m := re.search(r"REVIEWPANE-STAGE populated files=(\d+) untracked=(\d+)", l))]
assert populated, "populated line vanished"
files, untracked = map(int, populated[-1].groups())
print(f"REVIEWPANE populated: files={files} untracked={untracked}")
if files >= 1 and untracked >= 1:
    print("REVIEWPANE GATE: PASS")
else:
    print(f"REVIEWPANE GATE: FAIL (expected >=1 tracked and >=1 untracked, got {files}/{untracked})")
    sys.exit(1)
PY
rm -f "$geometry_log"
rm -rf "$(dirname "$geometry_repo")"

# --- Diff render check: the untrusted-content escape gate ------------------
# Repo file content is hostile input rendered into HTML (spec paragraph 8).
# LIGHTHOUSE_DEBUG_DIFFRENDER=1 renders a hostile fixture diff (script tags,
# event handlers, nonce theft) through the REAL pipeline — page builder,
# vendored diff2html, locked WKWebView — and the page posts its own DOM
# verdict, which we assert here.
render_log="$(mktemp)"
render_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_DIFFRENDER=1 LIGHTHOUSE_CONFIG_DIR="$render_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$render_log" 2>&1 &
render_pid=$!
trap 'kill -9 "$render_pid" 2>/dev/null || true; rm -rf "$render_cfg"' EXIT

render_tries=0
until grep -q "DIFFRENDER result" "$render_log"; do
    render_tries=$((render_tries + 1))
    if [ "$render_tries" -gt 100 ]; then
        echo "DIFFRENDER GATE: FAIL (no render result within 20s)" >&2
        grep "DIFFRENDER" "$render_log" | tail -5 >&2 || true
        exit 1
    fi
    if ! kill -0 "$render_pid" 2>/dev/null; then
        echo "DIFFRENDER GATE: FAIL (app exited before rendering)" >&2
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$render_pid" 2>/dev/null || true
render_tries=0
while kill -0 "$render_pid" 2>/dev/null; do
    render_tries=$((render_tries + 1))
    if [ "$render_tries" -gt 15 ]; then
        kill -9 "$render_pid" 2>/dev/null || true
    fi
    if [ "$render_tries" -gt 40 ]; then
        echo "DIFFRENDER GATE: FAIL (render app would not exit)" >&2
        exit 1
    fi
    sleep 0.2
done
trap - EXIT
rm -rf "$render_cfg"

python3 - "$render_log" <<'PY'
import json, re, sys

line = next((l for l in open(sys.argv[1]) if l.startswith("DIFFRENDER result ")), None)
assert line, "result line vanished"
result = json.loads(line.removeprefix("DIFFRENDER result ").strip())
print(f"DIFFRENDER dom: {result}")
problems = []
if result.get("error"):
    problems.append(f"page error: {result['error']}")
if result.get("scripts", -1) != 0:
    problems.append(f"{result.get('scripts')} script tags inside rendered diff")
if result.get("imgHandlers", -1) != 0:
    problems.append(f"{result.get('imgHandlers')} img event handlers survived")
if result.get("pwned") is not False:
    problems.append("hostile script EXECUTED (window.__pwned set)")
if result.get("hostileTextPresent") is not True:
    problems.append("hostile content missing as text — diff not actually rendered")
if result.get("files", 0) < 2:
    problems.append(f"expected 2 rendered files, got {result.get('files')}")
if problems:
    print("DIFFRENDER GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("DIFFRENDER GATE: PASS")
PY
rm -f "$render_log"

# --- File render check: the untrusted FILE-content escape gate -------------
# The Phase-B content viewer renders repo FILE content (not just diffs) into a
# WKWebView. LIGHTHOUSE_DEBUG_FILERENDER=1 renders the hostile FILE fixture
# (script close + injected image handler + unicode) through the REAL
# FilePageBuilder → locked WKWebView pipeline; the page posts its own DOM
# verdict, which we assert here (the escape proof no unit test can give).
filerender_log="$(mktemp)"
filerender_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_FILERENDER=1 LIGHTHOUSE_CONFIG_DIR="$filerender_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$filerender_log" 2>&1 &
filerender_pid=$!
trap 'kill -9 "$filerender_pid" 2>/dev/null || true; rm -rf "$filerender_cfg"' EXIT

filerender_tries=0
until grep -q "FILERENDER result" "$filerender_log"; do
    filerender_tries=$((filerender_tries + 1))
    if [ "$filerender_tries" -gt 100 ]; then
        echo "FILERENDER GATE: FAIL (no render result within 20s)" >&2
        grep "FILERENDER" "$filerender_log" | tail -5 >&2 || true
        exit 1
    fi
    if ! kill -0 "$filerender_pid" 2>/dev/null; then
        echo "FILERENDER GATE: FAIL (app exited before rendering)" >&2
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$filerender_pid" 2>/dev/null || true
filerender_tries=0
while kill -0 "$filerender_pid" 2>/dev/null; do
    filerender_tries=$((filerender_tries + 1))
    [ "$filerender_tries" -gt 15 ] && kill -9 "$filerender_pid" 2>/dev/null || true
    [ "$filerender_tries" -gt 40 ] && break
    sleep 0.2
done
trap - EXIT
rm -rf "$filerender_cfg"

python3 - "$filerender_log" <<'PY'
import json, sys
line = next((l for l in open(sys.argv[1]) if l.startswith("FILERENDER result ")), None)
assert line, "result line vanished"
result = json.loads(line.removeprefix("FILERENDER result ").strip())
print(f"FILERENDER dom: {result}")
problems = []
if result.get("error"):
    problems.append(f"page error: {result['error']}")
if result.get("scripts", -1) != 0:
    problems.append(f"{result.get('scripts')} script tags inside rendered file")
if result.get("imgs", -1) != 0:
    problems.append(f"{result.get('imgs')} img tags survived")
if result.get("handlers", -1) != 0:
    problems.append(f"{result.get('handlers')} event handlers survived")
if result.get("pwned") is not False:
    problems.append("hostile script EXECUTED (window.__pwned set)")
if result.get("hostileTextPresent") is not True:
    problems.append("hostile content missing as text — file not actually rendered")
if result.get("lines", 0) < 1:
    problems.append(f"expected rendered lines, got {result.get('lines')}")
if problems:
    print("FILERENDER GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("FILERENDER GATE: PASS")
PY
rm -f "$filerender_log"

# --- Navigator gate: the three surfaces + center-stage swap in the real app -
# LIGHTHOUSE_DEBUG_NAVIGATOR=<worktree> drives the real WorkbenchModel over a
# fixture repo: the Changes/Files/History surfaces populate, mode switching
# works, the center stage defaults to the terminal, a navigator selection swaps
# it to the viewer, a toggle returns it to the terminal, and the terminal
# controller is the SAME running instance across the swap (never recreated).
navigator_root="$(mktemp -d)"
navigator_main="$navigator_root/main"
navigator_wt="$navigator_root/wt"
mkdir -p "$navigator_main"
git -C "$navigator_main" init -q -b main
git -C "$navigator_main" config user.name smoke
git -C "$navigator_main" config user.email smoke@lighthouse.invalid
git -C "$navigator_main" config commit.gpgsign false
printf 'base\n' > "$navigator_main/tracked.txt"
git -C "$navigator_main" add tracked.txt
git -C "$navigator_main" commit -qm base
printf 'more\n' > "$navigator_main/second.txt"
git -C "$navigator_main" add second.txt
git -C "$navigator_main" commit -qm second
git -C "$navigator_main" worktree add -q -b task "$navigator_wt" main
printf 'changed\n' >> "$navigator_wt/tracked.txt"
printf 'brand new\n' > "$navigator_wt/untracked.txt"

navigator_log="$(mktemp)"
navigator_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_NAVIGATOR="$navigator_wt" LIGHTHOUSE_CONFIG_DIR="$navigator_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$navigator_log" 2>&1 &
nav_pid=$!
trap 'kill -9 "$nav_pid" 2>/dev/null || true; rm -rf "$navigator_cfg" "$navigator_root"' EXIT

nav_tries=0
until grep -q "NAVIGATOR-STAGE done" "$navigator_log"; do
    nav_tries=$((nav_tries + 1))
    if [ "$nav_tries" -gt 150 ]; then
        echo "NAVIGATOR GATE: FAIL (no terminal stage within 30s)" >&2
        grep "NAVIGATOR-STAGE" "$navigator_log" >&2 || true
        exit 1
    fi
    if ! kill -0 "$nav_pid" 2>/dev/null; then
        echo "NAVIGATOR GATE: FAIL (app exited during drive)" >&2
        grep "NAVIGATOR-STAGE" "$navigator_log" >&2 || true
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$nav_pid" 2>/dev/null || true
nav_tries=0
while kill -0 "$nav_pid" 2>/dev/null; do
    nav_tries=$((nav_tries + 1))
    [ "$nav_tries" -gt 15 ] && kill -9 "$nav_pid" 2>/dev/null || true
    [ "$nav_tries" -gt 40 ] && break
    sleep 0.2
done
trap - EXIT
rm -rf "$navigator_cfg" "$navigator_root"

python3 - "$navigator_log" <<'PY'
import sys
stages = {}
modes = []
for l in open(sys.argv[1]):
    if not l.startswith("NAVIGATOR-STAGE "):
        continue
    body = l.removeprefix("NAVIGATOR-STAGE ").strip()
    if body.startswith("mode="):
        modes.append(body.removeprefix("mode="))
    elif "=" in body:
        k, v = body.split("=", 1)
        stages[k] = v
print(f"NAVIGATOR stages: {stages} modes={modes}")

problems = []
def as_int(k):
    try: return int(stages.get(k, "x"))
    except ValueError: return -1
if as_int("changes") < 1: problems.append(f"changes={stages.get('changes')}")
if as_int("files") < 1: problems.append(f"files={stages.get('files')}")
if as_int("history") < 1: problems.append(f"history={stages.get('history')}")
if modes != ["changes", "files", "history"]: problems.append(f"mode switching {modes}")
if stages.get("center-default") != "terminal": problems.append("center did not default to terminal")
if stages.get("center-after-select") != "viewer": problems.append("selection did not swap to viewer")
if stages.get("center-after-toggle") != "terminal": problems.append("toggle did not return to terminal")
if stages.get("terminal-alive") != "true": problems.append("terminal was recreated across the swap")
if stages.get("viewer-has-content") != "true": problems.append("viewer rendered nothing on select")
if stages.get("file-page") != "true": problems.append("file selection rendered nothing")
if stages.get("commit-page") != "true": problems.append("commit selection rendered nothing")
if problems:
    print("NAVIGATOR GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("NAVIGATOR GATE: PASS")
PY
rm -f "$navigator_log"

# --- Notification gate: decision + UN* enqueue path in the real app --------
# UNUserNotificationCenter SIGTRAPs unless the app is launched by
# LaunchServices, so this probe launches via `open` (how the real app runs)
# and writes results to a file. It asserts the DECISION (needs-input fires,
# suppressed when the task is viewed) and that the request ENQUEUED — banner
# DISPLAY needs the user's authorization and is NOT asserted here (honest).
notify_out="$(mktemp -d)/notify.txt"
notify_cfg="$(mktemp -d)"
open -n --env "LIGHTHOUSE_DEBUG_NOTIFY=$notify_out" --env "LIGHTHOUSE_CONFIG_DIR=$notify_cfg" \
    "$package_root/dist/Lighthouse.app"
trap 'pkill -9 -f "dist/Lighthouse.app/Contents/MacOS/Lighthouse" 2>/dev/null || true; rm -rf "$notify_cfg" "$(dirname "$notify_out")"' EXIT
notify_tries=0
until grep -q "NOTIFY-STAGE done" "$notify_out" 2>/dev/null; do
    notify_tries=$((notify_tries + 1))
    if [ "$notify_tries" -gt 100 ]; then
        echo "NOTIFY GATE: FAIL (no result within 20s)" >&2
        cat "$notify_out" 2>/dev/null >&2 || true
        exit 1
    fi
    sleep 0.2
done
pkill -9 -f "dist/Lighthouse.app/Contents/MacOS/Lighthouse" 2>/dev/null || true
trap - EXIT
python3 - "$notify_out" <<'PY'
import sys
lines = dict(
    l.strip().removeprefix("NOTIFY-STAGE ").split("=", 1)
    for l in open(sys.argv[1]) if l.startswith("NOTIFY-STAGE ") and "=" in l)
print(f"NOTIFY stages: {lines}")
problems = []
if lines.get("decision") != "needsInput": problems.append(f"decision={lines.get('decision')}")
if lines.get("suppressed-when-viewed") != "true": problems.append("not suppressed when viewed")
if lines.get("enqueued") != "true": problems.append("request not enqueued")
if problems:
    print("NOTIFY GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("NOTIFY GATE: PASS (banner display depends on user authorization — not asserted)")
PY
rm -rf "$notify_cfg" "$(dirname "$notify_out")"

# --- Theme gate: the runtime theme foundation in the real app --------------
# The Theme tokens are pure and unit-tested, but the LIVE flip + the custom
# titlebar are SwiftUI/AppKit surfaces unit tests cannot reach.
# LIGHTHOUSE_DEBUG_THEME=1 resolves BOTH palettes in the running app, proves
# they differ, proves `termbg` stays near-black across the flip (the
# viewer/terminal stay-dark rule), and confirms the custom titlebar came up
# with its trailing accessory, the theme switcher, and the centered wordmark.
# Launched directly (a window is created — the titlebar needs one), like the
# GEOMETRY gate.
theme_log="$(mktemp)"
theme_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_THEME=1 LIGHTHOUSE_CONFIG_DIR="$theme_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$theme_log" 2>&1 &
theme_pid=$!
trap 'kill -9 "$theme_pid" 2>/dev/null || true; rm -rf "$theme_cfg"' EXIT

theme_tries=0
until grep -q "THEME-STAGE done" "$theme_log"; do
    theme_tries=$((theme_tries + 1))
    if [ "$theme_tries" -gt 150 ]; then
        echo "THEME GATE: FAIL (no done stage within 30s)" >&2
        grep "THEME-STAGE" "$theme_log" >&2 || true
        exit 1
    fi
    if ! kill -0 "$theme_pid" 2>/dev/null; then
        echo "THEME GATE: FAIL (app exited during theme check)" >&2
        grep "THEME-STAGE" "$theme_log" >&2 || true
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$theme_pid" 2>/dev/null || true
theme_tries=0
while kill -0 "$theme_pid" 2>/dev/null; do
    theme_tries=$((theme_tries + 1))
    [ "$theme_tries" -gt 15 ] && kill -9 "$theme_pid" 2>/dev/null || true
    [ "$theme_tries" -gt 40 ] && break
    sleep 0.2
done
trap - EXIT
rm -rf "$theme_cfg"

python3 - "$theme_log" <<'PY'
import sys
stages = {}
for l in open(sys.argv[1]):
    if not l.startswith("THEME-STAGE "):
        continue
    body = l.removeprefix("THEME-STAGE ").strip()
    for tok in body.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stages[k] = v
    if body == "done":
        stages["done"] = "true"
print(f"THEME stages: {stages}")

problems = []
def want(key, val):
    if stages.get(key) != val:
        problems.append(f"{key}={stages.get(key)} (expected {val})")

want("beacon-all-resolve", "true")
want("native-all-resolve", "true")
# Beacon's exact documented hex, resolved live in the app.
want("beacon-bg", "0a0d14")
want("beacon-primary", "f0b45e")
want("beacon-termbg", "080b11")
# Native termbg is the fixed dark value (not themed to light).
want("native-termbg", "1e1e22")
# Both palettes differ + termbg dark in both + dark after the live flip.
want("differ", "true")
want("termbg-dark-beacon", "true")
want("termbg-dark-native", "true")
want("termbg-still-dark", "true")
# The custom titlebar came up with its accessory + switcher + wordmark.
want("titlebar-accessory", "true")
want("switcher", "true")
want("wordmark", "true")
# COHERENCE (the 2026-07-15 half-light bug): each theme pins the live window
# appearance, and tokens resolved WITHIN that window appearance are coherent —
# Native is light (bg light, text dark), Beacon is dark (bg dark, text light) —
# independent of the process/system Light/Dark setting. Without the window
# appearance pin these FAIL (Native bg resolves dark under a dark process).
want("native-window-pinned", "true")
want("beacon-window-pinned", "true")
want("native-bg-light", "true")
want("native-text-dark", "true")
want("beacon-bg-dark", "true")
want("beacon-text-light", "true")
if "done" not in stages:
    problems.append("no done stage")
if problems:
    print("THEME GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("THEME GATE: PASS")
PY
rm -f "$theme_log"

# --- Harbor gate: the Phase-2 two-mode shell in the real app ----------------
# HarborOrder / the filter predicate / the nav transitions are pure and
# unit-tested (LighthouseAppCore); the SwiftUI shell is not headlessly
# testable (the scar). LIGHTHOUSE_DEBUG_HARBOR=1 seeds five ephemeral tasks
# (2 needs-input, 1 each working/idle/stale) + a live /bin/cat agent pty, then
# proves in the running app: the Harbor grid renders the expected card count;
# HarborOrder sorts needs->working->idle->stale; each filter chip yields the
# right subset; a card tap and a ⌘K select both flip the runtime to Focus; and
# — highest value — the registry-owned terminal survives a real Harbor<->Focus
# view flip (the pty is never tied to the Focus view's appearance; the scar).
# Launched directly (a window is created — the grid renders), like THEME.
harbor_log="$(mktemp)"
harbor_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_HARBOR=1 LIGHTHOUSE_CONFIG_DIR="$harbor_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$harbor_log" 2>&1 &
harbor_pid=$!
trap 'kill -9 "$harbor_pid" 2>/dev/null || true; rm -rf "$harbor_cfg"' EXIT

harbor_tries=0
until grep -q "HARBOR-STAGE done" "$harbor_log"; do
    harbor_tries=$((harbor_tries + 1))
    if [ "$harbor_tries" -gt 150 ]; then
        echo "HARBOR GATE: FAIL (no done stage within 30s)" >&2
        grep "HARBOR-STAGE" "$harbor_log" >&2 || true
        exit 1
    fi
    if ! kill -0 "$harbor_pid" 2>/dev/null; then
        echo "HARBOR GATE: FAIL (app exited during harbor check)" >&2
        grep "HARBOR-STAGE" "$harbor_log" >&2 || true
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$harbor_pid" 2>/dev/null || true
harbor_tries=0
while kill -0 "$harbor_pid" 2>/dev/null; do
    harbor_tries=$((harbor_tries + 1))
    [ "$harbor_tries" -gt 15 ] && kill -9 "$harbor_pid" 2>/dev/null || true
    [ "$harbor_tries" -gt 40 ] && break
    sleep 0.2
done
trap - EXIT
rm -rf "$harbor_cfg"

python3 - "$harbor_log" <<'PY'
import sys
stages = {}
for l in open(sys.argv[1]):
    if not l.startswith("HARBOR-STAGE "):
        continue
    body = l.removeprefix("HARBOR-STAGE ").strip()
    if body == "done":
        stages["done"] = "true"
        continue
    for tok in body.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stages[k] = v
print(f"HARBOR stages: {stages}")

problems = []
def want(key, val):
    if stages.get(key) != val:
        problems.append(f"{key}={stages.get(key)} (expected {val})")

# The live grid rendered the five seeded cards.
want("rendered-cards", "5")
# HarborOrder: needs -> working -> idle(done) -> stale(dirty). A wrong sort
# (plain name, or InboxOrder's needs->working->dirty->done) fails here.
want("sort", "needs-input,needs-input,working,done,dirty")
# Each filter chip selects exactly its mapped state's subset.
want("filter-all", "5")
want("filter-needs", "2")
want("filter-working", "1")
want("filter-idle", "1")
want("filter-stale", "1")
# card -> Focus and ⌘K -> Focus both flip the runtime, with selection applied.
want("card-open-view", "focus")
want("card-open-selected", "true")
want("back-view", "harbor")
want("switcher-open-view", "focus")
# The registry-owned terminal is the SAME running instance after a real
# Harbor<->Focus<->Harbor<->Focus flip — never recreated by the view lifecycle.
want("terminal-alive", "true")
if "done" not in stages:
    problems.append("no done stage")
if problems:
    print("HARBOR GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("HARBOR GATE: PASS")
PY
rm -f "$harbor_log"

# --- Focus gate: the Phase-3 Focus reshape in the real app ------------------
# The §3.4 body-state rules are pure and unit-tested (FocusBodyState); the
# reshaped SwiftUI shell (beacon rail, task header, footer, navigator overlay,
# three-pane body) is not headlessly testable (the scar). LIGHTHOUSE_DEBUG_FOCUS=1
# seeds three ephemeral tasks + a live /bin/cat agent pty, enters Focus, and
# proves in the running app: the rail rendered a dot per task and a dot drives
# open(id); the task header + footer rendered; the navigator overlay MOUNTS and
# UNMOUNTS on toggle (a real overlay, not a split column); the viewer overlay
# WINS over terminal/summary and a mode switch clears it; and — highest value —
# the registry-owned terminal is the SAME running instance after a full mode
# swap (terminal→summary→viewer→terminal) AND a nav toggle, and it FILLS the
# center column's body (not centered/collapsed at 181pt — the sizing scar).
# Launched directly (a window is created — the shell renders), like HARBOR.
focus_log="$(mktemp)"
focus_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_FOCUS=1 LIGHTHOUSE_CONFIG_DIR="$focus_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$focus_log" 2>&1 &
focus_pid=$!
trap 'kill -9 "$focus_pid" 2>/dev/null || true; rm -rf "$focus_cfg"' EXIT

focus_tries=0
until grep -q "FOCUS-STAGE done" "$focus_log"; do
    focus_tries=$((focus_tries + 1))
    if [ "$focus_tries" -gt 150 ]; then
        echo "FOCUS GATE: FAIL (no done stage within 30s)" >&2
        grep "FOCUS-STAGE" "$focus_log" >&2 || true
        exit 1
    fi
    if ! kill -0 "$focus_pid" 2>/dev/null; then
        echo "FOCUS GATE: FAIL (app exited during focus check)" >&2
        grep "FOCUS-STAGE" "$focus_log" >&2 || true
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$focus_pid" 2>/dev/null || true
focus_tries=0
while kill -0 "$focus_pid" 2>/dev/null; do
    focus_tries=$((focus_tries + 1))
    [ "$focus_tries" -gt 15 ] && kill -9 "$focus_pid" 2>/dev/null || true
    [ "$focus_tries" -gt 40 ] && break
    sleep 0.2
done
trap - EXIT
rm -rf "$focus_cfg"

echo "--- FOCUS gate stdout ---"
grep "FOCUS-STAGE" "$focus_log" || true
echo "-------------------------"

python3 - "$focus_log" <<'PY'
import re, sys
log = sys.argv[1]
stages = {}
geo = []  # (container_w, container_h, terminal_w, terminal_h)
geo_rx = re.compile(
    r"FOCUS-STAGE terminal window=\d+x\d+ container=(\d+)x(\d+) terminal=(\d+)x(\d+)")
for l in open(log):
    if not l.startswith("FOCUS-STAGE "):
        continue
    if m := geo_rx.search(l):
        geo.append(tuple(map(int, m.groups())))
        continue
    body = l.removeprefix("FOCUS-STAGE ").strip()
    if body == "done":
        stages["done"] = "true"
        continue
    for tok in body.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stages[k] = v
print(f"FOCUS stages: {stages}")

problems = []
def want(key, val):
    if stages.get(key) != val:
        problems.append(f"{key}={stages.get(key)} (expected {val})")

# Rail rendered a dot per seeded task; a dot drives open(id).
want("rendered-dots", "3")
want("rail-dot-view", "focus")
want("rail-dot-selected", "true")
# Task header + footer present.
want("header-present", "true")
want("footer-present", "true")
# §3.4 viewer precedence, asserted on the live mounted model.
want("viewer-wins-over-terminal", "true")
want("setmode-clears-viewer", "true")
want("viewer-wins-over-summary", "true")
want("closeviewer-returns-to-mode", "true")
# Navigator is a REAL overlay that mounts/unmounts on toggle.
want("nav-open-mounted", "true")
want("nav-closed-unmounted", "true")
# ★ Terminal survives the full mode swap + nav toggle (same running instance).
want("terminal-alive", "true")
if "done" not in stages:
    problems.append("no done stage")

# ★ Terminal FILLS the center column body: the real NSView frame equals its
# container and is not collapsed (width >= 420, height >= 250 — a 181pt
# collapse fails). The FOCUS gate does not resize, so the window may be small
# (the default here is ~418pt content tall → ~306pt body); the thresholds still
# bite the sizing scar (181 < both) while tolerating a small restored window.
# Assert the largest observed sample (the settled layout).
if not geo:
    problems.append("no terminal geometry samples (terminal never laid out)")
else:
    cw, ch, tw, th = max(geo, key=lambda g: g[2] * g[3])
    fill_problems = []
    if abs(tw - cw) > 2 or abs(th - ch) > 2:
        fill_problems.append(f"terminal {tw}x{th} != container {cw}x{ch}")
    if tw < 420:
        fill_problems.append(f"terminal width {tw} collapsed (< 420)")
    if th < 250:
        fill_problems.append(f"terminal height {th} collapsed (< 250)")
    verdict = "PASS" if not fill_problems else "FAIL (" + "; ".join(fill_problems) + ")"
    print(f"FOCUS terminal-fills: container {cw}x{ch} terminal {tw}x{th} -> {verdict}")
    problems += fill_problems

if problems:
    print("FOCUS GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("FOCUS GATE: PASS")
PY
rm -f "$focus_log"

# --- Digest gate: the Phase-4 per-task metadata in the real app -------------
# The pure pieces (DiffStat.parse, TranscriptReader, TaskDigestCache, baked
# timing) are unit-tested; the end-to-end wiring is not headlessly testable.
# LIGHTHOUSE_DEBUG_DIGEST=1 builds a throwaway git fixture with a KNOWN diff,
# seeds an ephemeral repo+task over it, and proves in the running app: the
# DETERMINISTIC diff counts are EXACT (files=3,add=3,del=1 — computed by git,
# not hardcoded in the app: a wrong reading flips diffstat-exact to false, the
# fail-before shown at build time); baked is the measured turn duration; the
# Summary DEGRADES GRACEFULLY with no transcript/recap (model/ctx stay BLANK,
# not zeros, while the deterministic diff stands); a hostile action is stored
# VERBATIM and rendered inert (SwiftUI Text); and the Summary pane renders
# without crashing. Launched directly (a window is created), like HARBOR/FOCUS.
digest_log="$(mktemp)"
digest_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_DIGEST=1 LIGHTHOUSE_CONFIG_DIR="$digest_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$digest_log" 2>&1 &
digest_pid=$!
trap 'kill -9 "$digest_pid" 2>/dev/null || true; rm -rf "$digest_cfg"' EXIT

digest_tries=0
until grep -q "DIGEST-STAGE done" "$digest_log"; do
    digest_tries=$((digest_tries + 1))
    if [ "$digest_tries" -gt 150 ]; then
        echo "DIGEST GATE: FAIL (no done stage within 30s)" >&2
        grep "DIGEST-STAGE" "$digest_log" >&2 || true
        exit 1
    fi
    if ! kill -0 "$digest_pid" 2>/dev/null; then
        echo "DIGEST GATE: FAIL (app exited during digest check)" >&2
        grep "DIGEST-STAGE" "$digest_log" >&2 || true
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$digest_pid" 2>/dev/null || true
digest_tries=0
while kill -0 "$digest_pid" 2>/dev/null; do
    digest_tries=$((digest_tries + 1))
    [ "$digest_tries" -gt 15 ] && kill -9 "$digest_pid" 2>/dev/null || true
    [ "$digest_tries" -gt 40 ] && break
    sleep 0.2
done
trap - EXIT
rm -rf "$digest_cfg"

echo "--- DIGEST gate stdout ---"
grep "DIGEST-STAGE" "$digest_log" || true
echo "--------------------------"

python3 - "$digest_log" <<'PY'
import sys
log = sys.argv[1]
stages = {}
for l in open(log):
    if not l.startswith("DIGEST-STAGE "):
        continue
    body = l.removeprefix("DIGEST-STAGE ").strip()
    if body == "done":
        stages["done"] = "true"
        continue
    for tok in body.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stages[k] = v
print(f"DIGEST stages: {stages}")

problems = []
def want(key, val):
    if stages.get(key) != val:
        problems.append(f"{key}={stages.get(key)} (expected {val})")

# Deterministic diff counts EXACT against the real git fixture.
want("diffstat-exact", "true")
# baked is the measured turn duration (explicit 2s clock in the gate).
want("baked", "2.0")
# Graceful degradation: no transcript read, so model/ctx are BLANK (not zeros),
# while the deterministic diff is known.
want("degrade-model-blank", "true")
want("degrade-ctx-blank", "true")
want("degrade-diff-known", "true")
# Untrusted action stored verbatim (never stripped/interpreted); Summary renders
# it through SwiftUI Text (inert). The pane rendered without crashing.
want("action-verbatim", "true")
want("summary-rendered", "true")
if "done" not in stages:
    problems.append("no done stage")

if problems:
    print("DIGEST GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("DIGEST GATE: PASS")
PY
rm -f "$digest_log"

# --- Motion gate: the Phase-5 reduce-motion contract in the real app --------
# The pure decisions (MotionResolver) are unit-tested; the ambient beam is a
# LIVE SwiftUI layer no unit test can reach. LIGHTHOUSE_DEBUG_MOTION=1 with
# LIGHTHOUSE_DEBUG_REDUCE_MOTION=1 forces reduce-motion and proves in the
# running app: motion is disabled (motion-enabled=false); beamVisible tracks
# `showBeam && motionEnabled` across the matrix; and — the load-bearing safety
# property + fail-before target — the beam is ABSENT even with the showBeam pref
# ON (reduce-motion wins), with the env-injected motionEnabled resolved false.
# A beam that ignored reduce-motion would flip beam-present/beam-when-reduced to
# true here. Launched directly (a window is created — Harbor renders), like
# HARBOR/FOCUS/DIGEST.
motion_log="$(mktemp)"
motion_cfg="$(mktemp -d)"
LIGHTHOUSE_DEBUG_MOTION=1 LIGHTHOUSE_DEBUG_REDUCE_MOTION=1 LIGHTHOUSE_CONFIG_DIR="$motion_cfg" \
    "$package_root/dist/Lighthouse.app/Contents/MacOS/Lighthouse" > "$motion_log" 2>&1 &
motion_pid=$!
trap 'kill -9 "$motion_pid" 2>/dev/null || true; rm -rf "$motion_cfg"' EXIT

motion_tries=0
until grep -q "MOTION-STAGE done" "$motion_log"; do
    motion_tries=$((motion_tries + 1))
    if [ "$motion_tries" -gt 150 ]; then
        echo "MOTION GATE: FAIL (no done stage within 30s)" >&2
        grep "MOTION-STAGE" "$motion_log" >&2 || true
        exit 1
    fi
    if ! kill -0 "$motion_pid" 2>/dev/null; then
        echo "MOTION GATE: FAIL (app exited during motion check)" >&2
        grep "MOTION-STAGE" "$motion_log" >&2 || true
        exit 1
    fi
    sleep 0.2
done
kill -TERM "$motion_pid" 2>/dev/null || true
motion_tries=0
while kill -0 "$motion_pid" 2>/dev/null; do
    motion_tries=$((motion_tries + 1))
    [ "$motion_tries" -gt 15 ] && kill -9 "$motion_pid" 2>/dev/null || true
    [ "$motion_tries" -gt 40 ] && break
    sleep 0.2
done
trap - EXIT
rm -rf "$motion_cfg"

echo "--- MOTION gate stdout ---"
grep "MOTION-STAGE" "$motion_log" || true
echo "--------------------------"

python3 - "$motion_log" <<'PY'
import sys
stages = {}
for l in open(sys.argv[1]):
    if not l.startswith("MOTION-STAGE "):
        continue
    body = l.removeprefix("MOTION-STAGE ").strip()
    if body == "done":
        stages["done"] = "true"
        continue
    for tok in body.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stages[k] = v
print(f"MOTION stages: {stages}")

problems = []
def want(key, val):
    if stages.get(key) != val:
        problems.append(f"{key}={stages.get(key)} (expected {val})")

# Reduce-motion forced on → motion disabled.
want("forced-reduce", "true")
want("motion-enabled", "false")
# beamVisible == showBeam && motionEnabled, across the matrix (both cases).
want("beamvis-motion-on-beam-on", "true")
want("beamvis-motion-on-beam-off", "false")
want("beamvis-motion-off-beam-on", "false")
# The pref is ON, yet the LIVE beam is absent (reduce-motion wins), and the
# env-injected motionEnabled the app resolved is false. These are the
# fail-before targets: a beam ignoring reduce-motion flips them.
want("showbeam-pref", "true")
want("harbor-bg-appeared", "true")
want("beam-present", "false")
want("env-motion-enabled", "false")
want("beam-when-reduced", "absent")
if "done" not in stages:
    problems.append("no done stage")
if problems:
    print("MOTION GATE: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("MOTION GATE: PASS")
PY
rm -f "$motion_log"

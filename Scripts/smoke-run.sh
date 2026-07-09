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

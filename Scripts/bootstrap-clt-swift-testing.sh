#!/bin/sh
# Workaround for a SwiftPM/Command Line Tools mismatch (observed 2026-07,
# CLT 26.x with Swift 6.3.2, no Xcode installed):
#
# CLT ships Swift Testing as Testing.framework in
# /Library/Developer/CommandLineTools/Library/Developer/Frameworks, but
# SwiftPM passes that directory to the compiler as -I (a swiftmodule search
# path), not -F (a framework search path). Manifest swiftSettings cannot fix
# the auto-generated test-runner module, so without this shim the runner's
# `#if canImport(Testing)` silently compiles to an empty main() and
# `swift test` exits 0 HAVING RUN ZERO TESTS.
#
# This script symlinks the framework's swiftmodule and binary into the build
# directory, which IS on the runner's -I and the product link's -L. Run it
# once after any `.build` wipe, before `swift test`. Idempotent.

set -eu

frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
framework="$frameworks/Testing.framework/Versions/A"

if [ ! -d "$framework/Modules/Testing.swiftmodule" ]; then
    # Xcode toolchains ship Testing properly; nothing to shim.
    echo "No CLT Testing.framework at $frameworks — shim not needed." >&2
    exit 0
fi

package_root="$(cd "$(dirname "$0")/.." && pwd)"
arch="$(uname -m)"
debug_dir="$package_root/.build/$arch-apple-macosx/debug"

mkdir -p "$debug_dir/Modules"
ln -sfn "$framework/Modules/Testing.swiftmodule" "$debug_dir/Modules/Testing.swiftmodule"
ln -sfn "$framework/Testing" "$debug_dir/libTesting.dylib"
echo "Swift Testing shim installed in $debug_dir"

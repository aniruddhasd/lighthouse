#!/bin/sh
# Assembles a runnable Lighthouse.app from the SPM build — the SPM package
# stays the single source of truth (no .xcodeproj to keep in sync). A real
# bundle (stable bundle id + Info.plist) is required for native notifications
# later; the id is baked now.
#
#   Scripts/make-app.sh [debug|release]   → dist/Lighthouse.app
#   LIGHTHOUSE_DIST_DIR=<dir> Scripts/make-app.sh …   → <dir>/Lighthouse.app (e.g. to build
#   a copy while the installed one is running)
set -eu

configuration="${1:-release}"
package_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$package_root"

build_stamp="$(git -C "$package_root" rev-parse --short HEAD)$(git -C "$package_root" diff --quiet HEAD 2>/dev/null || printf '%s' '-dirty')"

# Supply-chain gates BEFORE anything is built or copied:
#  - vendored diff2html assets + bundled fonts match their canonical checksums;
#  - Package.resolved revisions match the canonical pinned-revisions lock.
"$package_root/Scripts/verify-vendored-assets.sh" \
    "$package_root/Sources/LighthouseApp/Resources/diff2html"
"$package_root/Scripts/verify-vendored-assets.sh" \
    "$package_root/Sources/LighthouseApp/Resources/fonts"
"$package_root/Scripts/verify-pins.sh" \
    "$package_root/Package.resolved" "$package_root/Scripts/pinned-revisions.txt"

# --force-resolved-versions: build only from Package.resolved and error on any
# manifest/lockfile disagreement — no silent re-resolution (verified flag,
# Swift 6.3.3).
swift build --force-resolved-versions -c "$configuration" --product Lighthouse
# The supervisor's MCP server ships beside the app binary (the app launches it for the
# supervisor; docs/orchestrator-design.md §14).
swift build --force-resolved-versions -c "$configuration" --product lighthouse-supervisor-mcp

app="${LIGHTHOUSE_DIST_DIR:-$package_root/dist}/Lighthouse.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

cp ".build/$configuration/Lighthouse" "$app/Contents/MacOS/Lighthouse"
cp ".build/$configuration/lighthouse-supervisor-mcp" "$app/Contents/MacOS/lighthouse-supervisor-mcp"

# SPM resource bundle (vendored diff renderer): Bundle.module resolves it
# from Contents/Resources in a .app.
mkdir -p "$app/Contents/Resources"
cp -R ".build/$configuration/Lighthouse_LighthouseApp.bundle" "$app/Contents/Resources/"

# App icon: compile AppIcon.appiconset → AppIcon.icns into Resources and point
# Info.plist at it (CFBundleIconFile below). We assemble the bundle manually (no
# Xcode/actool), so iconutil takes a .iconset with Apple's fixed filenames; the
# appiconset's PNGs map 1:1 onto them (see AppIcon.appiconset/Contents.json).
iconset_src="$package_root/AppIcon.appiconset"
if [ -d "$iconset_src" ]; then
    iconset_tmp="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset_tmp"
    cp "$iconset_src/icon_16.png"   "$iconset_tmp/icon_16x16.png"
    cp "$iconset_src/icon_32.png"   "$iconset_tmp/icon_16x16@2x.png"
    cp "$iconset_src/icon_32.png"   "$iconset_tmp/icon_32x32.png"
    cp "$iconset_src/icon_64.png"   "$iconset_tmp/icon_32x32@2x.png"
    cp "$iconset_src/icon_128.png"  "$iconset_tmp/icon_128x128.png"
    cp "$iconset_src/icon_256.png"  "$iconset_tmp/icon_128x128@2x.png"
    cp "$iconset_src/icon_256.png"  "$iconset_tmp/icon_256x256.png"
    cp "$iconset_src/icon_512.png"  "$iconset_tmp/icon_256x256@2x.png"
    cp "$iconset_src/icon_512.png"  "$iconset_tmp/icon_512x512.png"
    cp "$iconset_src/icon_1024.png" "$iconset_tmp/icon_512x512@2x.png"
    iconutil -c icns "$iconset_tmp" -o "$app/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$iconset_tmp")"
else
    echo "warning: $iconset_src not found — building without an app icon" >&2
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.lighthouse.app</string>
    <key>CFBundleName</key>
    <string>Lighthouse</string>
    <key>CFBundleDisplayName</key>
    <string>Lighthouse</string>
    <key>CFBundleExecutable</key>
    <string>Lighthouse</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>$build_stamp</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local dev builds; hardened runtime and real
# identity come with distribution, not v1.
codesign --force --sign - "$app"

# The bundle must hold a working supervisor MCP server and verify as a whole.
test -x "$app/Contents/MacOS/lighthouse-supervisor-mcp"
codesign --verify --deep --strict "$app"

echo "Built $app"
echo "Run with: open \"$app\""

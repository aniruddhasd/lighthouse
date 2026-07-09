#!/bin/sh
# Assembles a runnable Lighthouse.app from the SPM build — the SPM package
# stays the single source of truth (no .xcodeproj to keep in sync). A real
# bundle (stable bundle id + Info.plist) is required for native notifications
# later; the id is baked now.
#
#   Scripts/make-app.sh [debug|release]   → dist/Lighthouse.app
set -eu

configuration="${1:-release}"
package_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$package_root"

swift build -c "$configuration" --product Lighthouse

app="$package_root/dist/Lighthouse.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

cp ".build/$configuration/Lighthouse" "$app/Contents/MacOS/Lighthouse"

cat > "$app/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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

echo "Built $app"
echo "Run with: open \"$app\""

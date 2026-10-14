#!/bin/zsh
# Release build → build/TailnetManager.app (hardened runtime).
#   ./build.sh                                                    ad-hoc signed: runs on this Mac only
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh                  signed for distribution
#   SIGN_ID=… NOTARY_PROFILE=<profile> ./build.sh   + notarized and stapled, zipped as build/TailnetManager.zip
#     (one-time: xcrun notarytool store-credentials <profile> --apple-id … --team-id …)
set -euo pipefail
cd "$(dirname "$0")"
BUNDLE_ID=io.github.xorroproprop.tailnet-manager   # = AppInfo.bundleID (Vault.swift) — it also names the Keychain items
VERSION=${VERSION:-1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
SIGN_ID=${SIGN_ID:--}

swift build -c release
[[ -f AppIcon.icns ]] || swift make-icon.swift
APP="$(pwd)/build/TailnetManager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/TailnetManager"
cp .build/release/TailnetManager "$BIN"
# Ship no build-machine paths: the debug map names every .o under this checkout (your home folder), and a non-Xcode
# toolchain adds an rpath into its own folder. Every Swift library loads from /usr/lib/swift, so that rpath is unused.
strip -S -x "$BIN"
for r in ${(f)"$(otool -l "$BIN" | awk '/cmd LC_RPATH/{getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print}')"}; do
    [[ "$r" == /usr/lib/swift || "$r" == @* ]] || install_name_tool -delete_rpath "$r" "$BIN"
done
! LC_ALL=C grep -aqF "$HOME" "$BIN" || { echo "❌ $HOME is still inside $BIN — not shipping that"; exit 1; }
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TailnetManager</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Tailnet Manager</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppleEventsUsageDescription</key><string>Tailnet Manager opens SSH sessions in Terminal when Ghostty isn't installed.</string>
</dict>
</plist>
PLIST

# Hardened runtime: no injected libraries or debugger attach, so no other process can borrow this app's Keychain
# access to the vault key. The one entitlement: driving Terminal via osascript when Ghostty is missing.
ENT="$(pwd)/build/TailnetManager.entitlements"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST
ts=(); [[ "$SIGN_ID" == "-" ]] || ts=(--timestamp)
codesign --force --options runtime "${ts[@]}" --entitlements "$ENT" --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "$SIGN_ID" != "-" ]] || { echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)"; exit 1; }
    ZIP="$(pwd)/build/TailnetManager.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # again, with the ticket stapled
    echo "✅ Notarized $ZIP"
fi
echo "✅ Built $APP ($([[ "$SIGN_ID" == "-" ]] && echo "ad-hoc — this Mac only" || echo "$SIGN_ID"))"
echo "   Launch: open \"$APP\""

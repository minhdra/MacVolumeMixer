#!/bin/bash
#
# build-release.sh — builds MacVolumeMixer.app, signs it, and packages it as
# both a .zip and a .dmg for GitHub Releases.
#
# Usage:
#   scripts/build-release.sh [VERSION]
#
#   VERSION defaults to the current git tag (if HEAD is tagged) or "0.0.0-dev".
#   Pass explicitly for a real release, e.g.: scripts/build-release.sh 0.1.0
#
# Environment variables (all optional):
#   CODESIGN_IDENTITY   Signing identity to pass to `codesign --sign`.
#                        Defaults to "-" (ad-hoc signing — no Apple Developer
#                        account needed; the app runs on the machine that
#                        built it, but Gatekeeper will warn other users with
#                        "unidentified developer" until they right-click ->
#                        Open once). Set to a real "Developer ID Application:
#                        ..." identity from `security find-identity -v
#                        -p codesigning` to produce a Developer-ID-signed build.
#   NOTARIZE             Set to "1" to run `xcrun notarytool submit` +
#                        `xcrun stapler staple` after signing. Requires
#                        CODESIGN_IDENTITY to be a real Developer ID and a
#                        notarytool keychain profile named "MacVolumeMixer"
#                        (set up once via:
#                        `xcrun notarytool store-credentials MacVolumeMixer
#                         --apple-id <id> --team-id <team> --password <app-specific-password>`).
#                        Skipped (with a clear message) when unset — ad-hoc
#                        builds cannot be notarized by Apple.
#
# Output: dist/MacVolumeMixer-<version>.zip, dist/MacVolumeMixer-<version>.dmg,
# and a .sha256 checksum file for each, all under dist/.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/MacVolumeMixer"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="MacVolumeMixer"
BUNDLE_ID="com.adjustvolume.MacVolumeMixer"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
fi
if [ -z "$VERSION" ]; then
    VERSION="0.0.0-dev"
fi

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"

echo "==> Building $APP_NAME version $VERSION (signing identity: $CODESIGN_IDENTITY)"

# 1. Release build via SwiftPM.
echo "==> swift build -c release"
(cd "$PACKAGE_DIR" && swift build -c release)

BINARY_PATH="$PACKAGE_DIR/.build/release/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo "error: expected release binary not found at $BINARY_PATH" >&2
    exit 1
fi

# 2. Assemble a real .app bundle. (`swift build` alone produces a bare
#    Mach-O with an embedded __info_plist section, which is enough for
#    `swift run`/dev, but a proper double-clickable, Gatekeeper- and
#    LaunchServices-recognized app needs the standard Contents/ layout.)
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PACKAGE_DIR/Sources/$APP_NAME/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PACKAGE_DIR/Sources/$APP_NAME/Resources/MenuBarIcon.png" "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png"
cp "$PACKAGE_DIR/Sources/$APP_NAME/Resources/ControlPanelIcon.png" "$APP_BUNDLE/Contents/Resources/ControlPanelIcon.png"

# Stamp the requested version into the bundle's Info.plist (source-controlled
# Info.plist keeps static placeholder values; this is the one place version
# numbers get set, so a release always matches its git tag).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Signing (identity: $CODESIGN_IDENTITY)"
codesign --force --deep --options runtime --timestamp="$([ "$CODESIGN_IDENTITY" = "-" ] && echo none || echo yes)" \
    --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [ "$NOTARIZE" = "1" ]; then
    if [ "$CODESIGN_IDENTITY" = "-" ]; then
        echo "==> Skipping notarization: ad-hoc signed builds cannot be notarized by Apple."
        echo "    Set CODESIGN_IDENTITY to a Developer ID Application identity to notarize."
    else
        echo "==> Notarizing (this can take a few minutes)..."
        NOTARIZE_ZIP="$WORK_DIR/notarize-submission.zip"
        ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
        xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "MacVolumeMixer" --wait
        xcrun stapler staple "$APP_BUNDLE"
    fi
else
    echo "==> NOTARIZE not set — skipping notarization step."
fi

# 3. Package.
mkdir -p "$DIST_DIR"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$ZIP_PATH" "$DMG_PATH"

echo "==> Creating $ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Creating $DMG_PATH"
DMG_STAGING="$WORK_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

# 4. Checksums, so the in-app update checker (or anyone else) can verify a
#    downloaded artifact matches what was actually built here.
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")

echo ""
echo "==> Done. Artifacts in $DIST_DIR:"
ls -lh "$DIST_DIR" | grep "$VERSION"

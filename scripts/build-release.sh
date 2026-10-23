#!/bin/zsh
# Release build for friends: a Release build without paid signing, then zip and dmg in dist/.
# Run from any folder: scripts/build-release.sh
# There is no Apple signature (local signature "-"), so on first open the Mac asks for confirmation:
# see docs/INSTALL.md. A public release without warnings needs a Developer ID and notarization.
set -euo pipefail

cd "${0:A:h}/.."
PROJECT="d-cal.xcodeproj"
SCHEME="MyApp"
NAME="What Was That"
OUT="dist"
DERIVED="$OUT/build"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')
echo "Version: ${VERSION:-?}"

rm -rf "$OUT"
mkdir -p "$OUT"

# The app icon name is passed as a build parameter: it can also be set by hand in the project settings
# (Target → General → App Icons → App Icon = AppIcon), then the parameter is not needed.
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon CODE_SIGN_IDENTITY=- \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

BUILT=$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)
[[ -n "$BUILT" ]] || { echo "Built app not found"; exit 1; }

# The app file is named without "!?": easier in the terminal and in Finder. The displayed name comes from Info.plist.
APP="$OUT/$NAME.app"
ditto "$BUILT" "$APP"

# zip
ditto -c -k --keepParent "$APP" "$OUT/$NAME-${VERSION:-1.0}.zip"

# dmg: the app, a link to "Applications" and the instructions
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/Read me first.md"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME-${VERSION:-1.0}.dmg" >/dev/null
rm -rf "$STAGE" "$DERIVED"

echo "Done:"
ls -lh "$OUT"

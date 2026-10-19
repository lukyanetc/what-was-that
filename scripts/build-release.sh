#!/bin/zsh
# Сборка релиза для друзей: Release-сборка без платной подписи, затем zip и dmg в папке dist/.
# Запуск из любой папки: scripts/build-release.sh
# Подписи Apple нет (локальная подпись «-»), поэтому при первом открытии Mac спросит подтверждение:
# см. docs/INSTALL.md. Для публичного релиза без предупреждений нужны Developer ID и нотаризация.
set -euo pipefail

cd "${0:A:h}/.."
PROJECT="d-cal.xcodeproj"
SCHEME="MyApp"
NAME="What Was That"
OUT="dist"
DERIVED="$OUT/build"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')
echo "Версия: ${VERSION:-?}"

rm -rf "$OUT"
mkdir -p "$OUT"

# Имя значка приложения передаётся параметром сборки: в настройках проекта его можно задать и вручную
# (Target → General → App Icons → App Icon = AppIcon), тогда параметр не нужен.
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon CODE_SIGN_IDENTITY=- \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

BUILT=$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)
[[ -n "$BUILT" ]] || { echo "Собранное приложение не найдено"; exit 1; }

# Файл приложения называется без «!?»: так удобнее в терминале и в Finder. Показываемое имя берётся из Info.plist.
APP="$OUT/$NAME.app"
ditto "$BUILT" "$APP"

# zip
ditto -c -k --keepParent "$APP" "$OUT/$NAME-${VERSION:-1.0}.zip"

# dmg: приложение, ссылка на «Программы» и инструкция
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/Read me first.md"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME-${VERSION:-1.0}.dmg" >/dev/null
rm -rf "$STAGE" "$DERIVED"

echo "Готово:"
ls -lh "$OUT"

#!/bin/sh
# Release derlemesi → imzalama → DMG → (isteğe bağlı) notarization + Sparkle appcast
#
# Ortam değişkenleri (hepsi isteğe bağlı; yoksa o adım atlanır):
#   SIGN_ID        "Developer ID Application: Ad Soyad (TEAMID)" — yoksa ad-hoc imza
#   NOTARY_PROFILE `xcrun notarytool store-credentials` ile kaydedilmiş profil adı
#   SPARKLE_BIN    Sparkle araçlarının klasörü (generate_appcast); yoksa appcast atlanır
#   ARCHS          varsayılan "arm64"; "arm64 x86_64" için Rust hedefleri kurulu olmalı
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

ARCHS=${ARCHS:-arm64}
DIST=dist
# derleme iCloud dışında: senkron xattr'ları codesign'ı bozuyor
DD=${TMPDIR:-/tmp}/kern-release-dd
VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' apps/macos/project.yml)
APP="$DD/Build/Products/Release/Kern.app"
DMG="$DIST/Kern-$VERSION.dmg"

echo "▸ Kern $VERSION ($ARCHS)"
rm -rf "$DIST" "$DD"
mkdir -p "$DIST"

command -v xcodegen >/dev/null || { echo "xcodegen gerekli: brew install xcodegen" >&2; exit 1; }
(cd apps/macos && xcodegen generate >/dev/null)

echo "▸ derleniyor"
xcodebuild -project apps/macos/Kern.xcodeproj -scheme Kern -configuration Release \
  -derivedDataPath "$DD" ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO build >"$DIST/build.log" 2>&1 ||
  { tail -40 "$DIST/build.log"; echo "derleme başarısız, tam günlük: $DIST/build.log" >&2; exit 1; }

# imzalama: önce çerçeveler ve gömülü ikililer, en son uygulama
echo "▸ imzalanıyor (${SIGN_ID:-ad-hoc})"
xattr -cr "$APP"
IDENTITY=${SIGN_ID:--}
SIGN="codesign --force --timestamp --options runtime --sign $IDENTITY"
[ "$IDENTITY" = "-" ] && SIGN="codesign --force --sign -"
find "$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 2>/dev/null | while read -r fw; do
  $SIGN "$fw"
done
[ -f "$APP/Contents/Resources/bin/kern" ] && $SIGN "$APP/Contents/Resources/bin/kern"
$SIGN --entitlements apps/macos/Kern.entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "  imza doğrulandı"

echo "▸ DMG"
STAGE=$DIST/stage
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Kern $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
[ "$IDENTITY" = "-" ] || $SIGN "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ notarization"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "▸ notarization atlandı (NOTARY_PROFILE yok)"
fi

# Sparkle appcast: imza anahtarı Keychain'de, generate_appcast dist/ klasörünü tarar
if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "▸ appcast"
  "$SPARKLE_BIN/generate_appcast" "$DIST"
else
  echo "▸ appcast atlandı (SPARKLE_BIN yok)"
fi

echo "▸ hazır: $DMG"
ls -lh "$DMG"

cat <<'NOTE'

İlk yayından önce bir kez:
  1. Sparkle anahtarları:  <Sparkle>/bin/generate_keys   → genel anahtarı
     apps/macos/project.yml içindeki SUPublicEDKey alanına yaz (boşken güncelleme kapalıdır).
  2. Notarization profili:  xcrun notarytool store-credentials kern-notary \
       --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
  3. Yayın: DMG ve appcast.xml GitHub Releases'e yüklenir (SUFeedURL bu adresi gösterir).
NOTE

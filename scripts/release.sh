#!/usr/bin/env bash
#
# release.sh – baut, signiert, notarisiert Logbuch Loader als DMG und erzeugt
# den signierten Sparkle-Appcast (docs/appcast.xml).
#
# Voraussetzungen:
#   • Xcode installiert; „Developer ID Application"-Zertifikat im Schlüsselbund
#   • notarytool-Keychain-Profil (Standard: LogbuchNotary) – einmalig anlegen mit
#       xcrun notarytool store-credentials "LogbuchNotary" \
#         --apple-id "<APPLE_ID>" --team-id "<TEAM_ID>"
#   • create-dmg (sindresorhus):  npm install -g create-dmg
#   • Sparkle-EdDSA-Schlüssel im Schlüsselbund (einmalig via `generate_keys`)
#
# Aufruf:   scripts/release.sh
# Env-Overrides:  NOTARY_PROFILE, SIGN_IDENTITY
#
# Hinweis: Das Skript veröffentlicht NICHTS. Am Ende gibt es die Befehle für
# den GitHub-Release + Pages-Push aus – die führst du bewusst selbst aus.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Logbuch Loader.xcodeproj"
SCHEME="Logbuch Loader"
APP_NAME="Logbuch Loader.app"
ENTITLEMENTS="Logbuch_Loader.entitlements"
# Build-Verzeichnis MUSS lokal liegen – NICHT im iCloud-Projektordner, sonst
# scheitert codesign an iCloud-Extended-Attributes („resource fork … not allowed").
BUILD_ROOT="$HOME/Library/Caches/LogbuchLoaderRelease"
BUILD_DIR="$BUILD_ROOT/build"
DIST_DIR="$BUILD_ROOT/dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-LogbuchNotary}"
REPO="supapilot/logbuch-loader"

# ── Developer-ID-Identität automatisch ermitteln (kein Klarname/Team im Repo) ──
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
	| awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$SIGN_IDENTITY" ] || { echo "❌ Keine 'Developer ID Application'-Identität gefunden."; exit 1; }
TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$SIGN_IDENTITY")"
echo "▸ Signieridentität: $SIGN_IDENTITY  (Team $TEAM_ID)"

# ── 1) Release bauen (Developer ID, Hardened Runtime, Runtime-Pin 14.0) ───────
# Build-Nummer (CFBundleVersion) aus dem Commit-Count – MUSS je Release steigen,
# da Sparkle Updates anhand von sparkle:version (= CFBundleVersion) erkennt.
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "▸ [1/6] Release bauen … (Build-Nummer $BUILD_NUMBER)"
rm -rf "$BUILD_DIR"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
	-project "$PROJECT" -scheme "$SCHEME" -configuration Release \
	-derivedDataPath "$BUILD_DIR" \
	CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
	DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES \
	CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	OTHER_CODE_SIGN_FLAGS="--timestamp --runtime-version 14.0" \
	clean build

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "▸ Version $VERSION"

# ── 2) Sparkle-Komponenten + App mit Developer ID neu signieren ───────────────
#    Das Sparkle-Binary-Framework kommt ad-hoc-signiert; xcodebuild signiert die
#    tief verschachtelten Helfer (Updater.app, Autoupdate, XPC-Dienste) NICHT mit
#    der Developer ID. Deshalb hier von innen nach außen explizit signieren
#    (Hardened Runtime + Secure Timestamp), zuletzt das App-Bundle (das dabei
#    auch get-task-allow verliert). Kein --deep.
echo "▸ [2/6] Sparkle-Komponenten + App signieren …"
FW="$APP/Contents/Frameworks/Sparkle.framework"
FWV="$FW/Versions/$(readlink "$FW/Versions/Current")"
for item in \
	"XPCServices/Downloader.xpc" \
	"XPCServices/Installer.xpc" \
	"Updater.app" \
	"Autoupdate"; do
	codesign --force --options runtime --timestamp --runtime-version 14.0 \
		--sign "$SIGN_IDENTITY" "$FWV/$item"
done
codesign --force --options runtime --timestamp --runtime-version 14.0 \
	--sign "$SIGN_IDENTITY" "$FW"

codesign --force --options runtime --timestamp --runtime-version 14.0 \
	--sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - | grep -q '"com.apple.security.get-task-allow" => 1'; then
	echo "❌ get-task-allow noch vorhanden – Abbruch."; exit 1
fi

# ── 3) DMG bauen (create-dmg signiert automatisch mit der App-Identität) ──────
echo "▸ [3/6] DMG bauen …"
rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"
create-dmg "$APP" "$DIST_DIR" >/dev/null
DMG="$(ls "$DIST_DIR"/*.dmg | head -1)"
echo "▸ $DMG"

# ── 4) DMG notarisieren + stapeln ─────────────────────────────────────────────
echo "▸ [4/6] Notarisieren (kann einige Minuten dauern) …"
# Falls --wait in ein Netzwerk-Timeout läuft: Einreichung ist trotzdem erfolgt –
# Status separat mit `xcrun notarytool info <id> --keychain-profile $NOTARY_PROFILE` pollen.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# DMG mit der nun gestapelten App neu bauen, damit die herausgezogene App offline startet:
rm -f "$DMG"; create-dmg "$APP" "$DIST_DIR" >/dev/null
DMG="$(ls "$DIST_DIR"/*.dmg | head -1)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vvv -t install "$DMG" || true

# ── 5) Appcast erzeugen + signieren (EdDSA) → docs/appcast.xml ────────────────
echo "▸ [5/6] Appcast erzeugen + signieren …"
GEN_APPCAST="$(find "$HOME/Library/Developer/Xcode/DerivedData"/Logbuch_Loader-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name generate_appcast 2>/dev/null | head -1)"
[ -n "$GEN_APPCAST" ] || { echo "❌ generate_appcast nicht gefunden (SPM-Artefakte fehlen)."; exit 1; }
# Enclosure-URL zeigt auf das Release-Asset des passenden Tags v<version>.
"$GEN_APPCAST" \
	--download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
	-o docs/appcast.xml "$DIST_DIR"
echo "▸ docs/appcast.xml aktualisiert."

# ── 6) Nächste Schritte (bewusst manuell – nichts wird hier veröffentlicht) ───
DMG_BASENAME="$(basename "$DMG")"
cat <<EOF

✅ Fertig. DMG + signierter Appcast liegen bereit.

Nächste Schritte (selbst ausführen):
  1) Appcast committen & pushen (löst GitHub-Pages-Deploy aus):
       git add docs/appcast.xml && git commit -m "Appcast v$VERSION" && git push

  2) GitHub-Release mit dem DMG anlegen (Tag MUSS v$VERSION heißen):
       gh release create "v$VERSION" "$DMG" --title "v$VERSION" --notes-file <(sed -n '/## \\[$VERSION\\]/,/## \\[/p' CHANGELOG.md) --latest

  3) Prüfen: https://supapilot.github.io/logbuch-loader/appcast.xml erreichbar,
     Enclosure-URL zeigt auf …/releases/download/v$VERSION/$DMG_BASENAME
EOF

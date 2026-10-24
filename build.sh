#!/bin/zsh
# Build Filee.app.
#
#   ./build.sh            Release build into build/Filee.app, signed with your signing identity (see below)
#   ./build.sh --install  also copy it to /Applications/Filee.app (quits a running Filee first)
#   ./build.sh --test     run the FileeCore unit tests first
#
# Steps: app icon (assets/AppIcon.svg), XcodeGen project, xcodebuild, codesign.
#
# Signing identity: $FILEE_SIGN_IDENTITY, else FILEE_SIGN_IDENTITY in .private/signing.env (git-ignored), for example
#   FILEE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# Without one, the app is signed ad hoc: it runs, but macOS asks again for folder access after each rebuild.
# A Developer ID + hardened runtime + a stable bundle id keep macOS permission grants across rebuilds.

set -euo pipefail
cd "${0:A:h}"

INSTALL=false
TEST=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --test) TEST=true ;;
  esac
done

start=$(date +%s)
RES=FileeMac/Resources
if [[ -z "${FILEE_SIGN_IDENTITY:-}" && -f .private/signing.env ]]; then
  source .private/signing.env
fi
IDENTITY="${FILEE_SIGN_IDENTITY:--}"
mkdir -p "$RES" build

if $TEST; then
  echo "🧪 FileeCore tests"
  (cd FileeCore && swift test 2>&1 | grep -E "Executed .* tests|error:" | tail -3)
fi

# 1. App icon: the white folder with the NicAI edelweiss (assets/AppIcon-art.svg) on a full-canvas red plate, the name
#    "Filee" under it (Lato Black, 200 px on 1024, as in Notee's icon). At 16 to 64 px the name can't be read:
#    assets/AppIcon-small.svg has the folder only. Both SVGs come from the NicAI icon generator:
#    python3 ~/ai/_shared/nicai-design/app_icon.py --name Filee --plate "gradient:#ea5544,#d63c2c,#b8302a" \
#      --art assets/AppIcon-art.svg --out /tmp/filee-icon   (then copy AppIcon.svg and AppIcon-small.svg to assets/)
#    Rebuilt when an SVG changes. The name needs the Lato font installed.
if [[ ! -f "$RES/AppIcon.icns" || assets/AppIcon.svg -nt "$RES/AppIcon.icns" || assets/AppIcon-small.svg -nt "$RES/AppIcon.icns" ]]; then
  echo "🎨 App icon"
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  render() { # $1 = pixel size, $2 = output file
    local svg=assets/AppIcon.svg
    (( $1 < 128 )) && svg=assets/AppIcon-small.svg
    rsvg-convert -w $1 -h $1 "$svg" -o "$2"
  }
  for size in 16 32 128 256 512; do
    render $size "$ICONSET/icon_${size}x${size}.png"
    render $((size*2)) "$ICONSET/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
fi

# 2. Project and build (unsigned; signed below).
echo "🛠  xcodegen"
xcodegen generate --quiet
echo "🛠  xcodebuild (Release)"
if ! xcodebuild -project Filee.xcodeproj -scheme Filee -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet build > build/xcodebuild.log 2>&1; then
  grep -E "error:" build/xcodebuild.log | sort -u | head -40 >&2
  echo "❌ build failed (build/xcodebuild.log)" >&2
  exit 1
fi
APP=build/DerivedData/Build/Products/Release/Filee.app
rm -rf build/Filee.app
cp -R "$APP" build/Filee.app

# 3. Sign.
echo "🔏 codesign"
if [[ "$IDENTITY" == "-" ]]; then
  echo "⚠️  no signing identity: ad-hoc signature (set FILEE_SIGN_IDENTITY, see the top of this file)"
  codesign --force --sign - --options runtime --entitlements FileeMac/Filee.entitlements build/Filee.app
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements FileeMac/Filee.entitlements build/Filee.app
fi
codesign --verify --strict build/Filee.app

if $INSTALL; then
  if pgrep -f /Applications/Filee.app/Contents/MacOS/Filee >/dev/null; then
    osascript -e 'tell application "Filee" to quit' >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -rf /Applications/Filee.app
  cp -R build/Filee.app /Applications/Filee.app
  echo "✅ installed /Applications/Filee.app"
  # The agent CLI on the PATH (agent interface).
  mkdir -p ~/.local/bin && ln -sf "$PWD/filee.py" ~/.local/bin/filee
fi

size=$(du -sh build/Filee.app | cut -f1)
echo "✅ build/Filee.app ($size) in $(( $(date +%s) - start ))s"

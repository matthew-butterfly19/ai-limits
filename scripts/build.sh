#!/bin/bash
# Builds AILimits.app without Xcode and without SwiftPM.
#
# Why not `swift build`: on stock Command Line Tools (Swift 6.1.2) the shipped
# libPackageDescription.dylib does not export the Package initialiser SwiftPM
# links against, so every manifest fails at link time. swiftc itself is fine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
APP="$BUILD/AILimits.app"
TARGET="${AILIMITS_TARGET:-arm64-apple-macosx14.0}"
CONFIG="${1:-debug}"

mkdir -p "$BUILD"

# ---------------------------------------------------------------------------
# Workaround: some Command Line Tools installations carry a stale duplicate of
# the SwiftBridging module map, left behind by an older install. Two files then
# define `module SwiftBridging`, and *every* Swift compilation dies on
# "redefinition of module 'SwiftBridging'" — including a bare `import Foundation`.
# Rather than asking for sudo to delete a system file, mask the stale copy with
# a VFS overlay that maps it to an empty file, for this build only.
# ---------------------------------------------------------------------------
VFS_ARGS=()
SWIFT_INC="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
if [[ -f "$SWIFT_INC/module.modulemap" && -f "$SWIFT_INC/bridging.modulemap" ]]; then
  : > "$BUILD/empty.modulemap"
  cat > "$BUILD/vfs-overlay.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": false,
  "roots": [
    { "type": "directory",
      "name": "$SWIFT_INC",
      "contents": [
        { "type": "file",
          "name": "module.modulemap",
          "external-contents": "$BUILD/empty.modulemap" }
      ] }
  ]
}
EOF
  VFS_ARGS=(-vfsoverlay "$BUILD/vfs-overlay.yaml")
  echo "note: masking duplicate module map at $SWIFT_INC/module.modulemap"
fi

FLAGS=(-parse-as-library -target "$TARGET" -swift-version 5)
if [[ "$CONFIG" == "release" ]]; then
  FLAGS+=(-O -whole-module-optimization)
else
  FLAGS+=(-Onone -g)
fi

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)
echo "building ${#SOURCES[@]} source files ($CONFIG)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc ${VFS_ARGS[@]+"${VFS_ARGS[@]}"} "${FLAGS[@]}" \
  -o "$APP/Contents/MacOS/AILimits" "${SOURCES[@]}"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Podpis ad-hoc (`--sign -`) ma wymaganie `cdhash H"…"` — odcisk dokładnie tego
# pliku, inny po każdym buildzie. Keychain traktuje wtedy każdy build jak inną
# aplikację i po każdej instalacji znowu pyta o hasło do klucza OpenRoutera.
# Samo przypięcie wymagania do identyfikatora tego nie naprawia: przy podpisie
# ad-hoc identyfikator nie jest niczym poświadczony, więc ACL Keychaina i tak
# pyta ponownie. Dlatego, jeśli lokalna tożsamość istnieje
# (`scripts/signing.sh` ją zakłada), podpisujemy nią — jej wymaganie
# `identifier … and certificate leaf = H"…"` jest takie samo dla każdego
# buildu, więc „Zawsze zezwalaj” klika się raz.
IDENTITY="AI Limits Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier "dev.ailimits.AILimits" "$APP" >/dev/null
  echo "note: podpisano tożsamością „${IDENTITY}”"
else
  codesign --force --sign - --identifier "dev.ailimits.AILimits" \
    --requirements '=designated => identifier "dev.ailimits.AILimits"' "$APP" >/dev/null
  echo "note: podpis ad-hoc — Keychain będzie pytał po każdej instalacji"
  echo "      (./scripts/signing.sh zakłada stałą tożsamość i to kończy)"
fi

echo "built $APP"

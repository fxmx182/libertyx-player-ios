#!/bin/bash
# Põe o VLCKit 4 onde Packages/VLCKit espera.
#
# O certo é o nosso: o release vlckit4-<tag> deste repositório, feito pelo
# workflow vlckit4.yml (Scripts/compilar-vlckit4.sh) — Release, sem as
# verificações de depuração do núcleo do VLC. A soma vem junto no release.
#
# Só para conferir se o código compila enquanto o nosso ainda não existe, o
# build sem assinatura aceita a prévia da VideoLAN (VLCKIT_ACEITA_PREVIA=1).
# O TestFlight nunca: a prévia é a que fechava o app.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=4.0.0-a26
RELEASE="vlckit4-$TAG"
DESTINO=Packages/VLCKit/VLCKit.xcframework
MARCA=Packages/VLCKit/ORIGEM.txt

if [ -d "$DESTINO" ] && [ -f "$MARCA" ]; then
    echo "VLCKit já está lá: $(cat "$MARCA")"
    exit 0
fi
rm -rf "$DESTINO" "$MARCA"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="${GITHUB_REPOSITORY:-fxmx182/libertyx-player-ios}"
BASE="https://github.com/$REPO/releases/download/$RELEASE"

if curl -fsSL --retry 3 -o "$TMP/vlckit.zip" "$BASE/VLCKit.xcframework.zip" &&
   curl -fsSL --retry 3 -o "$TMP/soma" "$BASE/VLCKit.xcframework.zip.sha256"; then
    (cd "$TMP" && sed 's/  .*/  vlckit.zip/' soma | shasum -a 256 -c -)
    ditto -x -k "$TMP/vlckit.zip" "$TMP/x"
    mv "$TMP/x/VLCKit.xcframework" "$DESTINO"
    echo "nosso $RELEASE (Release, sem assert)" > "$MARCA"
elif [ "${VLCKIT_ACEITA_PREVIA:-0}" = 1 ]; then
    echo "::warning title=VLCKit::release $RELEASE ainda não existe; compilando com a prévia da VideoLAN (só para conferir o código)"
    URL=https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20261109-1916.zip
    SOMA=1fec7232f88e706f44d9a015133e08d742166eb2666cb44915c9f570bf339463
    curl -fsSL --retry 3 -o "$TMP/vlckit.zip" "$URL"
    echo "$SOMA  $TMP/vlckit.zip" | shasum -a 256 -c -
    ditto -x -k "$TMP/vlckit.zip" "$TMP/x"
    FW=$(find "$TMP/x" -maxdepth 3 -name VLCKit.xcframework -type d | head -1)
    [ -n "$FW" ] || { echo "VLCKit.xcframework não está no zip"; find "$TMP/x" -maxdepth 3; exit 1; }
    mv "$FW" "$DESTINO"
    echo "prévia da VideoLAN $TAG (com assert — nunca para o TestFlight)" > "$MARCA"
else
    echo "::error title=VLCKit::o release $RELEASE não existe — rode o workflow vlckit4.yml"
    exit 1
fi

echo "VLCKit pronto: $(cat "$MARCA")"
ls "$DESTINO"

#!/bin/bash
# Baixa o MobileVLCKit 3.7.5 da VideoLAN e o põe onde Packages/VLCKit espera.
# A soma é conferida: um arquivo diferente do esperado para o build.
set -euo pipefail
cd "$(dirname "$0")/.."
DESTINO=Packages/VLCKit/MobileVLCKit.xcframework
[ -d "$DESTINO" ] && { echo "MobileVLCKit já está lá"; exit 0; }
URL=https://download.videolan.org/cocoapods/prod/MobileVLCKit-3.7.5-a213fd11-6de05adc.tar.xz
SOMA=a76f7a6cfcde4209b56f943e6e18400659d8a7a93ff482f8b1d059468d11e6be
TMP=$(mktemp -d)
curl -fsSL --retry 3 -o "$TMP/vlckit.tar.xz" "$URL"
echo "$SOMA  $TMP/vlckit.tar.xz" | shasum -a 256 -c -
tar -xJf "$TMP/vlckit.tar.xz" -C "$TMP" MobileVLCKit-binary/MobileVLCKit.xcframework
mv "$TMP/MobileVLCKit-binary/MobileVLCKit.xcframework" "$DESTINO"
rm -rf "$TMP"
echo "MobileVLCKit 3.7.5 pronto"

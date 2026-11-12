#!/bin/bash
# Compila o VLCKit 4 em modo final, só para iPhone (arm64), e deixa
# saida/VLCKit.xcframework.zip pronto para virar asset de release.
#
# Por que compilar, se a VideoLAN publica o VLCKit 4 pronto: o que ela publica
# é a prévia feita pelo Packaging/buildAndDeployFrameworks.sh, que chama
# `compileAndBuildVLCKit.sh -vf` — sem `-r`. Sem `-r` o libVLC é configurado
# sem `--disable-debug`, e no VLC isso quer dizer `assert()` ligado no núcleo
# inteiro. Foi uma dessas verificações (video_output.c, clock.c, decoder.c,
# es_out.c, input.c) que derrubou o app ao buscar e retomar pela rede em
# 03/11/2026. Com `-r`, o mesmo código vai para o build sem elas, que é como o
# app do VLC para iPhone é publicado na App Store.
#
# Roda no CI (workflow vlckit4.yml), em macOS. Leva horas: as dependências do
# VLC (FFmpeg, libass, dav1d, libsmb2...) são compiladas do código.
#
# O código vem dos espelhos oficiais da VideoLAN no GitHub: o
# code.videolan.org passou a pedir prova anti-robô e recusa o CI.
set -euo pipefail

VLCKIT_TAG="${VLCKIT_TAG:-4.0.0-a26}"
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
TRABALHO="${TRABALHO:-$RAIZ/build-vlckit4}"
SAIDA="$RAIZ/saida"

# GNU make 4.4, e não o 3.81 do macOS. O make antigo divide as tarefas por
# um par de descritores herdados; o meson abre o ninja fechando-os, e o ninja
# do VLC (o da Kitware, que fala com o make) para com "Could not initialize
# jobserver: Invalid file descriptors" — foi onde a primeira tentativa caiu,
# no dav1d. O 4.4 usa uma fila com nome (fifo), que sobrevive a isso. O
# script do VLCKit monta o PATH do zero, mas mantém $VLC_PATH nele.
command -v brew >/dev/null && { brew list make >/dev/null 2>&1 || brew install make; }
export VLC_PATH="$(brew --prefix make)/libexec/gnubin"
PATH="$VLC_PATH:$PATH" make --version | head -1
PATH="$VLC_PATH:$PATH" make --version | head -1 | grep -qE "GNU Make 4\.([4-9]|[1-9][0-9])" ||
    { echo "::error::precisa do GNU make 4.4 ou mais novo"; exit 1; }

rm -rf "$TRABALHO" "$SAIDA"
mkdir -p "$TRABALHO" "$SAIDA"
cd "$TRABALHO"

echo "== VLCKit $VLCKIT_TAG"
git clone --quiet --depth 1 --branch "$VLCKIT_TAG" https://github.com/videolan/vlckit.git VLCKit
cd VLCKit
HASH_VLC=$(sed -n 's/^TESTEDHASH="\([0-9a-f]*\)".*/\1/p' compileAndBuildVLCKit.sh)
[ -n "$HASH_VLC" ] || { echo "TESTEDHASH não encontrado"; exit 1; }
echo "== libVLC $HASH_VLC (o que o VLCKit $VLCKIT_TAG pede)"

# O mesmo que o script do VLCKit faz, mas pelo espelho: clona, fixa no hash
# testado e aplica os remendos dele (AC-3 pelo AudioToolbox, tokens HTTP...).
mkdir -p libvlc
git clone --quiet --filter=blob:none https://github.com/videolan/vlc.git libvlc/vlc
(
    cd libvlc/vlc
    git -c advice.detachedHead=false checkout --quiet -B localBranch "$HASH_VLC"
    git -c user.name=ci -c user.email=ci@localhost am --quiet ../patches/*.patch
    git log --oneline -1
)

# Só o aparelho. Com `-a aarch64` o script ainda passa pela etapa do
# simulador, e ali o arm64 cai de novo em "iphoneos" e refaz o mesmo build.
# Nenhum simulador roda este app; tirar a chamada poupa uma hora de CI.
perl -0pi -e 's/buildMobileKit iphonesimulator/true # sem simulador/' compileAndBuildVLCKit.sh
grep -q "true # sem simulador" compileAndBuildVLCKit.sh

# -r: Release e --disable-debug (sem assert). -a aarch64: só arm64 do iPhone.
# -n: não clonar de novo (já está aqui, e veio do espelho).
./compileAndBuildVLCKit.sh -r -n -a aarch64

FW=build/iOS/VLCKit.xcframework
[ -d "$FW" ] || { echo "xcframework não saiu"; ls -R build | head -50; exit 1; }

BIN=$(find "$FW" -path '*ios-arm64*' -name VLCKit -type f | head -1)
echo "== binário: $BIN ($(lipo -archs "$BIN"), $(du -h "$BIN" | cut -f1))"

# A prova de que é o build certo: o binário da prévia trazia o nome dos
# arquivos do núcleo do VLC, que só entram no binário pelas mensagens do
# assert(). Aqui eles não podem estar.
SUSPEITOS=0
for f in src/video_output/video_output.c src/clock/clock.c src/input/decoder.c src/input/es_out.c src/input/input.c; do
    if strings -a "$BIN" | grep -q "$f"; then
        echo "::warning::$f ainda aparece no binário"
        SUSPEITOS=$((SUSPEITOS + 1))
    fi
done
echo "== arquivos do núcleo com assert no binário: $SUSPEITOS (esperado 0)"
[ "$SUSPEITOS" -eq 0 ] || { echo "::error::o libVLC saiu com as verificações de depuração"; exit 1; }

ditto -c -k --sequesterRsrc --keepParent "$FW" "$SAIDA/VLCKit.xcframework.zip"
(cd "$SAIDA" && shasum -a 256 VLCKit.xcframework.zip | tee VLCKit.xcframework.zip.sha256)
{
    echo "VLCKit $VLCKIT_TAG ($(git rev-parse --short HEAD))"
    echo "libVLC $HASH_VLC + $(ls libvlc/patches | wc -l | tr -d ' ') remendos do VLCKit"
    echo "compileAndBuildVLCKit.sh -r -n -a aarch64 (Release, --disable-debug), só iphoneos arm64"
    echo "Xcode: $(xcodebuild -version | head -1)"
} | tee "$SAIDA/LEIA.txt"

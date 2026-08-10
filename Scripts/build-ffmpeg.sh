#!/usr/bin/env bash
#
# Compila o FFmpeg para iOS e empacota como FFmpeg.xcframework.
#
# Roda no runner macOS do CI (~12 min) e o resultado é cacheado — o cache é
# invalidado pelo hash deste arquivo, então mexer aqui força recompilação.
#
# Licença: LGPL. Sem --enable-gpl e sem --enable-nonfree, de propósito. O que o
# GPL traria (x264, x265) é irrelevante aqui: o app só decodifica, nunca
# codifica, e a decodificação pesada vai para o VideoToolbox.
#
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.1}"
MIN_IOS="${MIN_IOS:-17.0}"

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRABALHO="$RAIZ/.ffmpeg-build"
PREFIXO="$TRABALHO/install"
SAIDA="$RAIZ/Vendor/FFmpeg.xcframework"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CC_BIN="$(xcrun --sdk iphoneos -f clang)"

# ---------------------------------------------------------------------------
# Configuração: TODOS os decodificadores.
#
# A versão anterior partia de --disable-everything e ligava uma lista curada.
# Menor e mais rápida de compilar, mas com um defeito fatal para um player de
# uso real: o arquivo que não abre é sempre o que ficou de fora da lista, e
# descobrir isso exige um ciclo inteiro de CI + reinstalação.
#
# Agora a lógica é inversa — parte de tudo e desliga só o que um player nunca
# usa: codificadores, multiplexadores e dispositivos de captura. Isso mantém
# todos os demuxers, decodificadores, parsers, bitstream filters e protocolos
# que o FFmpeg conhece. Custa tamanho de binário; vale a tranquilidade.
#
# Continua LGPL: sem --enable-gpl e sem --enable-nonfree. O que o GPL traria
# (x264, x265) é só codificação, que não usamos.
# ---------------------------------------------------------------------------

echo "==> FFmpeg $FFMPEG_VERSION | iOS mínimo $MIN_IOS"
echo "    SDK: $SDK_PATH"

mkdir -p "$TRABALHO"
cd "$TRABALHO"

FONTE="ffmpeg-$FFMPEG_VERSION"
if [ ! -d "$FONTE" ]; then
  echo "==> baixando fontes…"
  curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o ffmpeg.tar.xz
  tar xf ffmpeg.tar.xz
  rm -f ffmpeg.tar.xz
fi

cd "$FONTE"

if [ ! -f config.h ]; then
  echo "==> configurando…"
  # shellcheck disable=SC2046
  ./configure \
    --prefix="$PREFIXO" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch=arm64 \
    --cc="$CC_BIN" \
    --as="$CC_BIN" \
    --sysroot="$SDK_PATH" \
    --extra-cflags="-arch arm64 -mios-version-min=$MIN_IOS -fembed-bitcode-marker -fno-stack-check" \
    --extra-ldflags="-arch arm64 -mios-version-min=$MIN_IOS" \
    --enable-static --disable-shared \
    --enable-pic \
    --disable-programs --disable-doc --disable-debug \
    --disable-gpl --disable-nonfree \
    --disable-avdevice --disable-postproc \
    --disable-encoders --disable-muxers \
    --enable-avformat --enable-avcodec --enable-avutil \
    --enable-swresample --enable-swscale --enable-avfilter \
    --enable-videotoolbox \
    --enable-securetransport
fi

echo "==> compilando…"
make -j"$(sysctl -n hw.ncpu)"
make install

# ---------------------------------------------------------------------------
# Empacotamento
#
# Juntamos as libs numa só antes do xcframework: seis .a separadas obrigariam
# o alvo a listar todas na ordem certa de link, o que quebra em silêncio.
# ---------------------------------------------------------------------------
echo "==> empacotando xcframework…"
cd "$PREFIXO"
libtool -static -o libffmpeg.a \
  lib/libavformat.a lib/libavcodec.a lib/libavfilter.a \
  lib/libswresample.a lib/libswscale.a lib/libavutil.a

rm -rf "$SAIDA"
mkdir -p "$(dirname "$SAIDA")"
xcodebuild -create-xcframework \
  -library "$PREFIXO/libffmpeg.a" \
  -headers "$PREFIXO/include" \
  -output "$SAIDA"

echo
echo "pronto: $SAIDA"
du -sh "$SAIDA"

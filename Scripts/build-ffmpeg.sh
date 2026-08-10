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
SAIDA="$RAIZ/Vendor/FFmpeg.xcframework"

# Alvos no formato plataforma:arquitetura.
#
# A fatia de simulador não é luxo — é o que permite rodar o app no CI, ver a
# tela e pegar crash sem instalar no celular a cada mudança.
#
# E ela precisa das DUAS arquiteturas: os runners do GitHub podem ser Intel ou
# Apple Silicon, e o simulador segue a arquitetura do host. Com só uma, o
# linker descarta a biblioteca inteira num dos casos, arquivo por arquivo, com
# a mensagem "found architecture arm64, required architecture x86_64".
ALVOS=("iphoneos:arm64" "iphonesimulator:arm64" "iphonesimulator:x86_64")

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

mkdir -p "$TRABALHO"
FONTE="$TRABALHO/ffmpeg-$FFMPEG_VERSION"

if [ ! -d "$FONTE" ]; then
  echo "==> baixando fontes…"
  curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$TRABALHO/ffmpeg.tar.xz"
  tar xf "$TRABALHO/ffmpeg.tar.xz" -C "$TRABALHO"
  rm -f "$TRABALHO/ffmpeg.tar.xz"
fi

for ALVO in "${ALVOS[@]}"; do
  PLATAFORMA="${ALVO%%:*}"
  ARQUITETURA="${ALVO##*:}"

  SDK_PATH="$(xcrun --sdk "$PLATAFORMA" --show-sdk-path)"
  CC_BIN="$(xcrun --sdk "$PLATAFORMA" -f clang)"

  # A flag de versão mínima tem nome diferente em cada plataforma; usar a
  # errada faz o linker rejeitar a biblioteca depois, sem dizer o porquê.
  if [ "$PLATAFORMA" = "iphonesimulator" ]; then
    FLAG_VERSAO="-mios-simulator-version-min=$MIN_IOS"
  else
    FLAG_VERSAO="-mios-version-min=$MIN_IOS"
  fi

  # O assembly x86 do FFmpeg exige nasm, que não vem no runner. Desligá-lo
  # custa desempenho que não importa: essa fatia só existe para o simulador.
  #
  # A expansão usa a forma ${arr[@]+"${arr[@]}"} porque o macOS ainda traz
  # bash 3.2, onde expandir array vazio sob `set -u` é erro fatal.
  EXTRA_CONFIG=()
  [ "$ARQUITETURA" = "x86_64" ] && EXTRA_CONFIG+=(--disable-x86asm)

  CONSTRUCAO="$TRABALHO/build-$PLATAFORMA-$ARQUITETURA"
  PREFIXO="$TRABALHO/install-$PLATAFORMA-$ARQUITETURA"
  mkdir -p "$CONSTRUCAO"

  echo
  echo "==> $PLATAFORMA / $ARQUITETURA"
  echo "    SDK: $SDK_PATH"

  # Compilação fora da árvore de fontes: os dois alvos compartilham o mesmo
  # código-fonte e mantêm config.h separados. Compilar no diretório de fontes
  # obrigaria a limpar tudo entre as plataformas.
  cd "$CONSTRUCAO"
  if [ ! -f config.h ]; then
    echo "    configurando…"
    "$FONTE/configure" \
      --prefix="$PREFIXO" \
      --enable-cross-compile \
      --target-os=darwin \
      --arch="$ARQUITETURA" \
      --cc="$CC_BIN" \
      --as="$CC_BIN" \
      --sysroot="$SDK_PATH" \
      --extra-cflags="-arch $ARQUITETURA $FLAG_VERSAO -fno-stack-check" \
      --extra-ldflags="-arch $ARQUITETURA $FLAG_VERSAO" \
      ${EXTRA_CONFIG[@]+"${EXTRA_CONFIG[@]}"} \
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

  echo "    compilando…"
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
  make install >/dev/null

  # Uma biblioteca só por plataforma: seis .a separadas obrigariam o alvo a
  # listar todas na ordem certa de link, o que quebra em silêncio.
  cd "$PREFIXO"
  libtool -static -o libffmpeg.a \
    lib/libavformat.a lib/libavcodec.a lib/libavfilter.a \
    lib/libswresample.a lib/libswscale.a lib/libavutil.a

done

# ---------------------------------------------------------------------------
# Uma biblioteca por PLATAFORMA — as arquiteturas da mesma plataforma são
# unidas com lipo. O xcframework recusa duas entradas para a mesma plataforma,
# então arm64 e x86_64 do simulador precisam virar um binário só.
# ---------------------------------------------------------------------------
ARGUMENTOS_XCFRAMEWORK=()

for PLATAFORMA in iphoneos iphonesimulator; do
  PARTES=()
  for ALVO in "${ALVOS[@]}"; do
    [ "${ALVO%%:*}" = "$PLATAFORMA" ] || continue
    PARTES+=("$TRABALHO/install-$PLATAFORMA-${ALVO##*:}/libffmpeg.a")
  done
  [ ${#PARTES[@]} -gt 0 ] || continue

  FINAL="$TRABALHO/libffmpeg-$PLATAFORMA.a"
  if [ ${#PARTES[@]} -eq 1 ]; then
    cp "${PARTES[0]}" "$FINAL"
  else
    lipo -create "${PARTES[@]}" -output "$FINAL"
  fi
  echo "    $PLATAFORMA: $(lipo -archs "$FINAL")"

  # Os cabeçalhos são idênticos entre arquiteturas; bastam os da primeira.
  ARGUMENTOS_XCFRAMEWORK+=(-library "$FINAL" -headers "$(dirname "${PARTES[0]}")/include")
done

echo
echo "==> empacotando xcframework…"
rm -rf "$SAIDA"
mkdir -p "$(dirname "$SAIDA")"
xcodebuild -create-xcframework "${ARGUMENTOS_XCFRAMEWORK[@]}" -output "$SAIDA"

echo
echo "pronto: $SAIDA"
du -sh "$SAIDA"
ls "$SAIDA"

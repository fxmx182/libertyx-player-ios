#!/usr/bin/env bash
#
# Instala o LabPlayer.ipa no iPhone ligado por USB neste servidor.
#
# Pré-requisitos (uma vez só):
#   sudo apt install -y usbmuxd libimobiledevice-utils ideviceinstaller
#   container `anisette` rodando na porta 6969
#   binário AltServer em ~/.local/bin/AltServer
#
# Uso:
#   Scripts/instalar-no-iphone.sh caminho/para/LabPlayer.ipa
#
set -euo pipefail

ANISETTE_URL="${ALTSERVER_ANISETTE_SERVER:-http://127.0.0.1:6969}"
ALTSERVER="$HOME/.local/bin/AltServer"

falhar() { echo "erro: $*" >&2; exit 1; }

IPA="${1:-}"
[ -n "$IPA" ] || falhar "informe o caminho do .ipa
  exemplo: $0 ~/Downloads/LabPlayer.ipa"
[ -f "$IPA" ] || falhar "arquivo não encontrado: $IPA"

# O artefato do GitHub vem como .zip com o .ipa dentro; erro comum.
case "$IPA" in
  *.zip) falhar "isso é o .zip do artefato. Descompacte primeiro:
  unzip '$IPA' && $0 LabPlayer.ipa" ;;
esac

[ -x "$ALTSERVER" ] || falhar "AltServer não encontrado em $ALTSERVER"

command -v idevice_id >/dev/null || falhar "libimobiledevice ausente. Rode:
  sudo apt install -y usbmuxd libimobiledevice-utils ideviceinstaller"

systemctl is-active --quiet usbmuxd || echo "aviso: serviço usbmuxd não está ativo"

curl -sf --max-time 10 "$ANISETTE_URL" >/dev/null \
  || falhar "servidor anisette não responde em $ANISETTE_URL
  suba com: docker start anisette"

echo "==> procurando o iPhone…"
UDID="$(idevice_id -l 2>/dev/null | head -1 || true)"
[ -n "$UDID" ] || falhar "nenhum aparelho encontrado.
  Ligue o iPhone por USB neste servidor, desbloqueie a tela e toque em
  'Confiar neste computador'. Depois rode de novo."

NOME="$(ideviceinfo -u "$UDID" -k DeviceName 2>/dev/null || echo '?')"
VERSAO="$(ideviceinfo -u "$UDID" -k ProductVersion 2>/dev/null || echo '?')"
echo "    $NOME (iOS $VERSAO)"
echo "    udid: $UDID"

# A senha vai direto para a Apple via anisette local. Não é gravada em disco,
# não entra no histórico do shell e não sai desta máquina para mais ninguém.
echo
read -rp "Apple ID (e-mail): " APPLE_ID
read -rsp "Senha do Apple ID: " APPLE_SENHA
echo; echo

echo "==> assinando e instalando (o 2FA vai ser pedido aqui)…"
echo

# O AltServer sai com código 0 mesmo quando falha — confiar no exit status faz
# o script anunciar sucesso que não houve. Então guardamos a saída, procuramos
# erro nela e, no fim, conferimos no próprio aparelho.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

set +e
ALTSERVER_ANISETTE_SERVER="$ANISETTE_URL" \
  "$ALTSERVER" -u "$UDID" -a "$APPLE_ID" -p "$APPLE_SENHA" "$IPA" 2>&1 | tee "$LOG"
set -e

echo
echo "==> conferindo no aparelho…"
sleep 2

# `ideviceinstaller list`, não `-l`: a flag antiga não existe mais e o erro de
# sintaxe, silenciado por 2>/dev/null, virava um falso "não instalou".
if ideviceinstaller list 2>&1 | grep -qi 'labplayer'; then
  echo
  echo "INSTALADO. O LabPlayer está na tela inicial do iPhone."
  # O AltServer acrescenta o sufixo do time ao bundle id em conta gratuita.
  ideviceinstaller list 2>/dev/null | grep -i labplayer | sed 's/^/  /'
  echo
  echo "Antes de abrir, confie no certificado uma vez:"
  echo "  Ajustes > Geral > VPN e Gerenciamento de Dispositivo > seu Apple ID > Confiar"
  echo
  echo "Com Apple ID gratuito o app expira em 7 dias — rode este script de novo"
  echo "para renovar."
  exit 0
fi

echo
echo "NÃO INSTALOU. O app não aparece na lista do aparelho."
echo

if grep -q '434' "$LOG"; then
  cat <<'DIAG'
Diagnóstico: código 434 na resposta de dois fatores.

Isso vem da autenticação da Apple, não do app nem do .ipa — que já foi
verificado como íntegro. O AltServer-Linux não recebe atualização real desde
2023, e a Apple mudou o fluxo de login desde então; é o suspeito principal.

O que costuma valer a pena, em ordem:
  1. Repetir uma vez — a Apple às vezes bloqueia por tentativas seguidas.
     Espere alguns minutos entre as tentativas.
  2. Entrar em https://appleid.apple.com pelo navegador e ver se há termos
     novos a aceitar ou aviso de segurança pendente. Login travado por isso
     falha exatamente assim.
  3. Trocar a ferramenta de instalação (Sideloadly num PC Windows/Mac, ou
     conta de desenvolvedor paga assinando por certificado — que dispensa
     senha, 2FA e o AltServer inteiro).
DIAG
elif grep -qi 'anisette' "$LOG"; then
  echo "Diagnóstico: problema no servidor anisette. Reinicie com:"
  echo "  docker restart anisette"
else
  echo "Últimas linhas da saída do AltServer:"
  tail -15 "$LOG" | sed 's/^/  /'
fi

exit 1

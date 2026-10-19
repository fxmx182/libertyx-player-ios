# LibertyX Player — iPhone

Player de vídeo para iOS no espírito do MX Player, feito porque o iOS não tem
nada equivalente: o VLC abre tudo mas rola o vídeo aos pulos, e o player nativo
rola liso mas não abre quase nada.

As duas coisas que motivam o projeto:

1. **Rolagem integral.** Arrastar o dedo e ver *cada frame*, sem saltar para o
   keyframe mais próximo.
2. **SMB direto.** Abrir o vídeo no servidor de casa sem baixar nada antes.

Bundle: `com.mauricio.labplayer` — herdado do nome antigo do projeto (LabPlayer)
e mantido, porque trocar o bundle faz o iPhone tratar como outro app.

**Baixar:** [LibertyXPlayer.ipa](https://github.com/fxmx182/libertyx-player-ios/releases/download/latest/LibertyXPlayer.ipa)
— sempre o build mais recente da `main`.

---

## Estado atual

**Fase 1 — o app existe e o pipeline fecha.** Roda em cima do AVFoundation.

| | |
|---|---|
| Pendrive USB / iCloud / pastas locais | funciona (via seletor do iOS + bookmark persistente) |
| Gestos MX Player | funciona (brilho, volume, seek, 2×, zoom, duplo toque) |
| Seek frame-exato | funciona **nos codecs que a Apple abre** (H.264/HEVC em MP4/MOV) |
| MKV, AVI, TS, DTS/AC3, legendas ASS | ❌ precisa do motor FFmpeg |
| SMB | ❌ precisa do motor FFmpeg |

A camada de gestos e a interface já estão escritas contra o protocolo
`PlaybackEngine`, não contra o AVFoundation — trocar o motor não as reescreve.

## Por que nesta ordem

Nenhuma máquina do projeto roda macOS. Quem compila é o runner do GitHub
Actions, o que significa que **erro de compilação só aparece ~10 min depois do
push**. Escrever 5 000 linhas de decodificador de vídeo antes de ter um build
verde seria depurar às cegas. Então: primeiro o pipeline, depois o motor.

## Arquitetura

```
LibraryView (SwiftUI)          escolhe a mídia
        │
        ▼
PlayerViewController (UIKit)   gestos, HUD, controles  ← a "cara" do app
        │  fala só com o protocolo
        ▼
PlaybackEngine (protocolo)
        ├── AVPlayerEngine     hoje
        └── FFmpegEngine       fase 2
                │
                ▼
        MediaOrigin: .file | .smb | .remote
```

`MediaOrigin` é a peça que faz o resto funcionar: o motor nunca sabe se os
bytes vieram do pendrive ou do servidor SMB — ele só pede blocos. Na fase 2
cada caso vira um `AVIOContext` do FFmpeg com callbacks de read/seek.

### Como a rolagem integral vai funcionar

O que o VLC faz: seek → pula para o keyframe anterior → mostra. Como um GOP
tem tipicamente 2–10 s, o vídeo "anda aos pulos".

O que o MX Player faz, e o que o `FFmpegEngine` vai fazer:

1. `av_seek_frame(..., AVSEEK_FLAG_BACKWARD)` até o keyframe anterior ao alvo;
2. decodifica para frente **descartando** frames até `pts >= alvo`;
3. mostra o frame exato.

Com decodificação por hardware (VideoToolbox) isso cabe no orçamento de um
frame na maioria dos GOPs. Detalhe importante: durante o arrasto, o scrub usa
um decodificador **separado** do de reprodução — daí os `beginScrub()` /
`endScrub()` já existirem no protocolo. E os seeks são coalescidos (no máximo
um em voo) — sem isso a fila cresce e o vídeo fica segundos atrás do dedo.

## Roadmap

- [x] **Fase 1** — esqueleto, gestos, USB, CI gerando `.ipa`
- [ ] **Fase 2** — `FFmpeg.xcframework` (LGPL, sem `--enable-gpl`) compilado no
      CI e cacheado; demux + VideoToolbox + render em Metal
- [ ] **Fase 3** — scrub frame-a-frame de verdade, com decodificador dedicado
- [ ] **Fase 4** — SMB (`AVIOContext` sobre cliente SMB2/3) e navegação na rede
- [ ] **Fase 5** — legendas externas (SRT/ASS), troca de faixa de áudio, sincronia
- [ ] **Fase 6** — retomar de onde parou, histórico, miniaturas

## Compilar

Não precisa de Mac. Um push na `main` (ou *Run workflow* na aba Actions)
compila e publica `LibertyXPlayer.ipa` no release `latest`.

O `.ipa` sai **sem assinatura**, de propósito: quem assina é o SideStore ou o
AltStore no aparelho, com o seu Apple ID. Assim o CI não precisa de
certificado nem de conta paga.

Localmente, com Xcode:

```bash
brew install xcodegen && xcodegen generate && open LabPlayer.xcodeproj
```

O `.xcodeproj` é gerado a partir de `project.yml` e **não** é versionado —
projeto do Xcode em git dá conflito a cada build.

## LibertyX Pro

O app é grátis e completo como player. O **Pro** libera pastas da rede (SMB),
áudio em segundo plano, tempo para dormir e captura de quadro; os sete primeiros
dias vêm com tudo liberado. É o mesmo Pro do Android, com a mesma chave.

Sem App Store não há StoreKit: a compra é a **chave LibertyX**, vendida com
Bitcoin ou USDT/USDC pelo bot da loja no Telegram
([@libertx_partition_bot](https://t.me/libertx_partition_bot?start=player)).
`Core/Pro.swift` confere a chave sozinho, sem internet (`LXP1-…`, assinatura
ECDSA P-256 conferida com CryptoKit, produto 2 = Player ou 9 = pacote). O início
do teste e a chave ficam no Keychain, que sobrevive a reinstalar pelo Sideloadly.

- `Library/ProView.swift`: a tela do Pro, a de colar a chave, `ProPortao` (põe a
  tela do Pro no lugar de uma tela Pro) e `Pro.exigir` (a porta no player).
- Portas: servidores (`ProPortao(.rede)`), captura e tempo para dormir no painel
  de ferramentas, e o segundo plano (sair do app sem Pro pausa o filme).

## Instalar no iPhone

Com Apple ID gratuito o app expira a cada 7 dias e o SideStore renova sozinho
pelo Wi-Fi. Com conta de desenvolvedor paga ($99/ano) a assinatura dura 1 ano.
A decisão ainda está em aberto — o projeto não depende dela: não há
*entitlements* no alvo justamente para continuar assinável pela conta gratuita.

## Android

O mesmo player existe para Android, no repositório [libertyx-player-android](https://github.com/fxmx182/libertyx-player-android) — Kotlin,
mesmo motor (libVLC), mesmos gestos, mesmo ícone. Não é um porte do código, que
é Swift e não roda lá: é a mesma arquitetura reescrita, com a interface falando
com um `VlcEngine` como aqui ela fala com o protocolo `PlaybackEngine`.

Três coisas que faltavam deste lado e existem lá: a **rolagem quadro a quadro**
(o Android expõe o `setTime(ms, fast=false)` que o VLCKit do iOS esconde — era
justamente a lacuna que quase virou um motor FFmpeg próprio), a **janela
flutuante** com qualquer motor, e **compilar na própria máquina**, sem depender
de um runner macOS. E o app **acha os vídeos sozinho**: o MediaStore já indexou
tudo, então não há a dança de autorizar pasta por pasta.

O mesmo app é também o de **televisão** — um APK à parte só porque as caixinhas
de TV se dividem entre 32 e 64 bits e o `LibertyXPlayer-TV.apk` carrega as duas.
Instalado num Chromecast com Google TV, Fire TV ou Nvidia Shield, ele troca a
grade por faixas horizontais, ganha realce de foco e passa a obedecer ao
controle remoto — com o servidor de casa na primeira faixa, porque numa
caixinha de TV quase não há vídeo local.

```bash
# no libertyx-player-android
./gradlew assembleRelease
adb install -r dist/LibertyXPlayer-Celular.apk
```

## Estrutura

```
App/Sources/
  Core/      MediaSource · PlaybackEngine · AVPlayerEngine
  Player/    PlayerViewController · GestureHUDView · PlayerControlsView
  Library/   LibraryView · BookmarkStore · FolderScanner · DocumentPicker
Scripts/     make_icon.py
.github/     workflows/build.yml (.ipa) · workflows/ffmpeg.yml (FFmpeg)
project.yml  definição do projeto (XcodeGen)
```

## Gestos

| Gesto | Ação |
|---|---|
| Arrastar ↔ | Seek com pré-visualização ao vivo |
| Arrastar ↕ na metade esquerda | Brilho da tela |
| Arrastar ↕ na metade direita | Volume do app |
| Toque duplo à esquerda / direita | −10 s / +10 s |
| Toque duplo no centro | Play / pause |
| Toque simples | Mostrar/ocultar controles |
| Segurar | 2× enquanto segura |
| Pinça | Ajustar / Preencher / Esticar |

## Família LibertyX

| App | Repositório |
|---|---|
| LibertyX Player — iPhone | [libertyx-player-ios](https://github.com/fxmx182/libertyx-player-ios) |
| LibertyX Player — Android e TV | [libertyx-player-android](https://github.com/fxmx182/libertyx-player-android) |
| LibertyX Folder — iPhone | [libertyx-folder-ios](https://github.com/fxmx182/libertyx-folder-ios) |
| LibertyX Folder — Android e TV | [libertyx-folder-android](https://github.com/fxmx182/libertyx-folder-android) |
| LibertyX Partition — Windows | [libertyx-partition](https://github.com/fxmx182/libertyx-partition) |

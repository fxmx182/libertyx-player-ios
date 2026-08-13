import UIKit
import AVFoundation

/// A tela de reprodução e toda a camada de gestos estilo MX Player.
///
/// Deliberadamente escrita em UIKit e contra o protocolo `PlaybackEngine`: os
/// gestos são a parte que dá a "cara" do app e não podem ser refeitos quando o
/// motor FFmpeg substituir o AVPlayer. Nada aqui conhece AVFoundation.
final class PlayerViewController: UIViewController {

    // MARK: - Ajustes de sensibilidade

    private enum Tuning {
        /// Quantos segundos de vídeo por largura de tela arrastada.
        /// MX Player escala isso com a duração; abaixo de 2 min fica fino.
        static let seekSecondsPerScreenWidth: Double = 120
        /// Fração da altura da tela para percorrer 0→100% de brilho/volume.
        static let verticalTravelFraction: CGFloat = 0.6
        /// Distância mínima antes de decidir se o gesto é horizontal ou vertical.
        static let axisLockThreshold: CGFloat = 12
        static let doubleTapSeconds: Double = 10
        static let holdToSpeedRate: Float = 2.0
    }

    private enum PanAxis { case undecided, horizontal, vertical }

    // MARK: - Estado

    private let engine: PlaybackEngine
    /// Muda ao pular de faixa — daí não ser constante.
    private var item: MediaItem
    /// Os outros vídeos da mesma pasta, para anterior/próxima.
    private let playlist: [MediaItem]
    private var currentIndex: Int

    private var renderView: UIView!
    private let hud = GestureHUDView()
    private let controls = PlayerControlsView()
    private let subtitleLabel = UILabel()

    private var panAxis: PanAxis = .undecided
    private var panStartTime: Double = 0
    private var panStartBrightness: CGFloat = 0
    private var panStartVolume: Float = 1
    private var panIsOnLeftHalf = true

    private var pendingSeekTarget: Double?
    /// A coalescência de destinos mudou de lugar: agora vive no motor, junto
    /// do decodificador. Aqui só rastreamos o arrasto na barra.
    private var isBarScrubbing = false

    /// A ponte com a ilha, a central de controle e o botão do fone.
    private let nowPlaying = NowPlayingCenter()

    /// Se foi este mesmo toque que trouxe a barra à tela.
    private var mostrouNesteToque = false

    private var rateBeforeHold: Float = 1.0
    private var controlsHideWorkItem: DispatchWorkItem?
    private var didPresentError = false
    private var playbackSpeed: Float = 1.0
    private var lastSavedPosition: Double = 0
    /// Instante a retomar assim que a reprodução começar de fato.
    private var pendingResume: Double?

    // MARK: - Ferramentas

    enum RepeatMode { case off, one }
    private var repeatMode: RepeatMode = .off
    private var isShuffling = false
    private var sleepTimer: Timer?
    private var sleepDeadline: Date?
    /// Camada escura por cima do vídeo — o "modo noturno" é escurecer além do
    /// mínimo do sistema, útil para assistir no escuro sem queimar os olhos.
    private let dimView = UIView()
    private var pip: PictureInPicture?
    private let systemVolume = SystemVolume()
    private var volumeObservation: NSKeyValueObservation?

    private let gravityModes: [AVLayerVideoGravity] = [.resizeAspect, .resizeAspectFill, .resize]
    private var gravityIndex = 0

    // MARK: - Ampliação

    /// Ampliação contínua da imagem, independente do enquadramento.
    ///
    /// O enquadramento decide como o vídeo se encaixa na tela; a ampliação é o
    /// usuário chegando mais perto de um pedaço. São coisas diferentes e por
    /// isso não se atrapalham.
    private var videoZoom: CGFloat = 1.0
    /// Que pedaço da imagem ampliada está no centro.
    private var videoOffset: CGPoint = .zero
    /// Abaixo de 1× dá para ver a imagem inteira afastada; acima, chega-se
    /// perto o bastante para ler uma placa no fundo da cena.
    private let zoomRange: ClosedRange<CGFloat> = 0.5...6.0

    // MARK: - Ciclo de vida

    init(engine: PlaybackEngine, item: MediaItem, playlist: [MediaItem] = []) {
        self.engine = engine
        self.item = item
        // Sem lista, o próprio vídeo é a lista — assim o resto do código não
        // precisa tratar o caso vazio em todo lugar.
        let lista = playlist.isEmpty ? [item] : playlist
        self.playlist = lista
        self.currentIndex = lista.firstIndex { $0.id == item.id } ?? 0
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        renderView = engine.makeRenderView()
        renderView.translatesAutoresizingMaskIntoConstraints = false
        // Nada é tocado sobre o vídeo: tudo é gesto ou botão dos controles. O
        // VLC monta a própria view de desenho, interativa, e ela engolia os
        // toques antes de chegarem aos gestos — por isso a barra não abria.
        renderView.isUserInteractionEnabled = false
        view.addSubview(renderView)

        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        dimView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimView)

        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.isUserInteractionEnabled = false
        view.addSubview(hud)

        setupSubtitleLabel()
        systemVolume.attach(to: view)
        observeHardwareVolume()

        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: view.topAnchor),
            renderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            renderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        controls.title = item.title
        controls.onPlayPause = { [weak self] in self?.togglePlayPause() }
        controls.onClose = { [weak self] in self?.close() }
        controls.onScrub = { [weak self] time, finished in
            self?.handleControlScrub(to: time, finished: finished)
        }
        controls.onSeekRelative = { [weak self] delta in self?.jump(by: delta) }
        controls.onShowTracks = { [weak self] kind in self?.showTracks(kind) }
        controls.onPrevious = { [weak self] in self?.goToPrevious() }
        controls.onNext = { [weak self] in self?.goToNext() }
        controls.onLockChange = { [weak self] locked in
            // Com a tela bloqueada nada some sozinho: o usuário bloqueou
            // justamente para nada mudar enquanto ele encosta na tela.
            if locked { self?.controlsHideWorkItem?.cancel() } else { self?.scheduleControlsHide() }
        }

        controls.onBackgroundTap = { [weak self] in
            self?.controls.setVisible(false, animated: true)
        }
        controls.onCycleAspect = { [weak self] in self?.cycleAspect() }
        controls.onTogglePiP = { [weak self] in self?.acionarPiP() }
        controls.moreMenuProvider = { [weak self] in self?.buildToolsMenu() ?? [] }

        // A janela flutuante só é montada depois da carga: quem toca o
        // arquivo é decidido ali, e só o AVPlayer oferece a camada que o
        // sistema aceita para PiP.
        controls.setPiPAvailable(false)
        refreshToolStrip()

        // Enquanto o vídeo toca, ninguém disputa disco e CPU com ele. A
        // retomada fica em `viewWillDisappear` — e precisa ficar, porque sem
        // ela abrir um único vídeo desligava a geração de miniatura para o
        // resto da sessão.
        ThumbnailStore.isSuspended = true

        installGestures()
        bindEngine()
        bindNowPlaying()
        loadNowPlayingArtwork()
        updateNavigation()
        loadAndPlay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Fora da reprodução a biblioteca volta a poder gerar miniatura.
        //
        // Isto faltava, e era a causa de só uns poucos vídeos terem imagem: a
        // suspensão era ligada ao abrir o primeiro vídeo e nunca mais
        // desligada. Sobrava o que já estava em cache — os primeiros da lista,
        // gerados antes de o usuário abrir qualquer coisa. Filme e servidor,
        // que demoram mais para chegar na vez, nunca tinham a sua.
        ThumbnailStore.isSuspended = false

        // Sair com a janela flutuante aberta é legítimo: o vídeo continua nela.
        guard pip?.isActive != true else { return }
        volumeObservation?.invalidate()
        volumeObservation = nil
        cancelSleepTimer()
        engine.teardown()
    }

    // MARK: - Integração com o sistema

    private func bindNowPlaying() {
        nowPlaying.onPlay = { [weak self] in self?.engine.play() }
        nowPlaying.onPause = { [weak self] in self?.engine.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.goToNext() }
        nowPlaying.onPrevious = { [weak self] in self?.goToPrevious() }
        nowPlaying.onSkip = { [weak self] passo in self?.jump(by: passo) }
        nowPlaying.onSeek = { [weak self] instante in
            guard let self else { return }
            Task { @MainActor in await self.engine.seek(to: instante, precise: false) }
        }
        nowPlaying.activate()
        refreshNowPlaying()
    }

    /// Mantém o sistema sabendo o que está tocando e em que ponto.
    ///
    /// Sem o tempo e a taxa corretos a barrinha da tela bloqueada fica parada,
    /// e a ilha não anima.
    private func refreshNowPlaying() {
        nowPlaying.hasNext = currentIndex + 1 < playlist.count
        nowPlaying.hasPrevious = currentIndex > 0
        nowPlaying.update(title: item.title,
                          currentTime: engine.currentTime,
                          duration: engine.duration,
                          rate: engine.state == .playing ? playbackSpeed : 0)
    }

    /// A miniatura do vídeo vira a capa na ilha e na tela bloqueada.
    private func loadNowPlayingArtwork() {
        let alvo = item
        Task { @MainActor in
            let imagem = await ThumbnailStore.shared.load(alvo)
            guard self.item.id == alvo.id else { return }
            self.nowPlaying.setArtwork(imagem)
        }
    }

    // MARK: - Motor

    private func bindEngine() {
        engine.onTimeUpdate = { [weak self] time in
            guard let self else { return }

            // Aplica a retomada no primeiro sinal de que a reprodução começou
            // DE VERDADE. `play()` marca o estado como tocando na hora, antes
            // de o VLC posicionar o arquivo — buscar ali é ignorado, e o vídeo
            // seguia do zero. Atualização de tempo só chega com ele rodando.
            if let alvo = self.pendingResume, self.engine.duration > 0 {
                self.pendingResume = nil
                Task { @MainActor in await self.engine.seek(to: alvo, precise: false) }
                return
            }

            self.controls.update(currentTime: time, duration: self.engine.duration)
            self.saveResumePoint(time)
            self.refreshNowPlaying()
        }
        engine.onBufferingChange = { [weak self] buffering in
            self?.controls.setBuffering(buffering)
        }
        engine.onSubtitle = { [weak self] texto in
            self?.subtitleLabel.text = texto
            self?.subtitleLabel.isHidden = (texto == nil)
        }
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.controls.apply(state: state)
            self.refreshNowPlaying()
            if case .failed(let message) = state { self.presentError(message) }

            if state == .ended { self.handlePlaybackEnded() }
        }
    }

    private func loadAndPlay() {
        Task { @MainActor in
            do {
                try await engine.load(item)
                configurarPiP()
                controls.update(currentTime: 0, duration: engine.duration)

                // Retomar é pergunta, não regra: às vezes se quer rever o
                // filme desde o começo, e voltar sozinho ao meio obriga a
                // desfazer na mão toda vez.
                // Sem comparar com a duração: o VLC só a conhece depois de
                // começar a tocar, então a condição nunca passava e a pergunta
                // nunca aparecia. Quem valida a marca é o próprio ResumeStore,
                // que guardou a duração junto.
                if let retomada = ResumeStore.shared.position(for: item.origin.resumeKey) {
                    perguntarRetomada(de: retomada)
                } else {
                    engine.play()
                    scheduleControlsHide()
                }
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    /// Liga a janela flutuante quando quem assumiu foi o AVPlayer.
    ///
    /// Com ele o sistema controlaria pausa e avanço sozinho. O VLC desenha por
    /// conta própria e não oferece essa camada, então hoje não há janela — o
    /// botão fica e explica, em vez de sumir sem motivo aparente.
    private func configurarPiP() {
        // O botão fica sempre à mostra. Esconder quando não dá transformava um
        // limite conhecido num sumiço inexplicável.
        controls.setPiPAvailable(true)

        // Sem AVPlayer não há camada sobre a qual o iOS monte a janelinha.
        pip = nil
        refreshToolStrip()
    }

    /// Pergunta antes de retomar.
    ///
    /// Voltar sozinho ao meio do filme é útil na maioria das vezes e péssimo
    /// quando se quer rever desde o começo — e desfazer isso na mão, toda vez,
    /// cansa mais do que responder uma pergunta.
    private func perguntarRetomada(de instante: Double) {
        controlsHideWorkItem?.cancel()

        let alerta = UIAlertController(
            title: item.title,
            message: "Você parou em \(TimeFormat.clock(instante)).",
            preferredStyle: .alert)

        alerta.addAction(UIAlertAction(title: "Continuar de \(TimeFormat.clock(instante))",
                                       style: .default) { [weak self] _ in
            guard let self else { return }
            // Buscar antes de a reprodução começar é ignorado pelo VLC — ele
            // ainda não tem o arquivo posicionado. A marca fica guardada e é
            // aplicada assim que ele começa a tocar.
            self.pendingResume = instante
            self.engine.play()
            self.scheduleControlsHide()
        })

        alerta.addAction(UIAlertAction(title: "Começar do início", style: .default) { [weak self] _ in
            guard let self else { return }
            ResumeStore.shared.clear(key: self.item.origin.resumeKey)
            self.engine.play()
            self.scheduleControlsHide()
        })

        present(alerta, animated: true)
    }

    /// Guarda a posição de tempos em tempos, não a cada quadro: são ~30
    /// gravações por segundo contra uma a cada cinco segundos.
    private func saveResumePoint(_ time: Double) {
        guard engine.duration > 0, abs(time - lastSavedPosition) >= 5 else { return }
        lastSavedPosition = time
        ResumeStore.shared.save(position: time, duration: engine.duration,
                                for: item.origin.resumeKey)
    }

    private func presentError(_ message: String) {
        // `load` falha por duas vias ao mesmo tempo: o throw e a transição para
        // `.failed`. Sem esta trava o usuário levaria dois alertas empilhados.
        guard !didPresentError else { return }
        didPresentError = true

        controls.setVisible(true, animated: true)

        // "Formato não suportado" sozinho não diz nada acionável: pode ser
        // codec que a Apple recusa, ou o arquivo nem estar sendo lido por
        // falta de permissão — problemas opostos. O FFmpeg já está no app,
        // então perguntamos a ele antes de mostrar o alerta.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let diagnostico = await self.diagnose()
            self.showAlert(message: message, diagnosis: diagnostico)
        }
    }

    private func diagnose() async -> String? {
        guard case .file = item.origin else { return nil }
        let origin = item.origin

        let resultado = await Task.detached(priority: .userInitiated) { () -> Result<MediaInfo, Error> in
            do {
                guard let info = try FileAccess.withAccess(origin, { try MediaProbe.probe(path: $0) }) else {
                    return .failure(PlaybackError.securityScopeDenied)
                }
                return .success(info)
            } catch {
                return .failure(error)
            }
        }.value

        switch resultado {
        case .success(let info):
            let video = info.video.first.map { "\($0.codec.uppercased()) \($0.resolution)" } ?? "sem vídeo"
            let audio = info.audio.first.map { $0.codec.uppercased() } ?? "sem áudio"
            return """

            O FFmpeg lê este arquivo normalmente:
            \(info.formatName.uppercased()) · \(video) · \(audio)

            Ou seja, o arquivo está íntegro e legível — quem recusa é o \
            motor da Apple. É exatamente o caso que o motor FFmpeg resolve.
            """
        case .failure(let erro):
            return """

            O FFmpeg também não conseguiu abrir:
            \(erro.localizedDescription)

            Isso aponta para permissão de leitura, não para codec. Tente \
            adicionar a pasta de novo em Pastas.
            """
        }
    }

    private func showAlert(message: String, diagnosis: String?) {
        let alert = UIAlertController(title: "Não deu para tocar",
                                      message: message + (diagnosis ?? ""),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Voltar", style: .default) { [weak self] _ in
            self?.close()
        })
        present(alert, animated: true)
    }

    private func close() {
        // Grava sem o intervalo de cinco segundos: sair é justamente quando a
        // posição mais precisa estar certa.
        if engine.duration > 0, engine.currentTime > 30 {
            ResumeStore.shared.save(position: engine.currentTime,
                                    duration: engine.duration,
                                    for: item.origin.resumeKey)
        }
        nowPlaying.deactivate()
        engine.teardown()
        dismiss(animated: true)
    }

    // MARK: - Anterior / próxima

    /// Convenção de player: com o vídeo já andando, "anterior" volta ao começo
    /// dele; só nos primeiros segundos é que salta para o arquivo anterior.
    /// Sem isso, quem quer reiniciar acaba pulando de faixa sem querer.
    private func goToPrevious() {
        if engine.currentTime > 3 {
            Task { await engine.seek(to: 0, precise: false) }
            scheduleControlsHide()
            return
        }
        switchTo(index: currentIndex - 1)
    }

    private func goToNext() {
        if isShuffling, playlist.count > 1 {
            // Sorteia sem repetir o atual — cair no mesmo vídeo não parece
            // aleatório, parece defeito.
            var sorteado = currentIndex
            while sorteado == currentIndex { sorteado = Int.random(in: playlist.indices) }
            switchTo(index: sorteado)
            return
        }
        switchTo(index: currentIndex + 1)
    }

    private func handlePlaybackEnded() {
        if repeatMode == .one {
            Task { @MainActor in
                await engine.seek(to: 0, precise: false)
                engine.play()
            }
            return
        }

        // Quem assistiu até o fim não quer voltar para os créditos na próxima.
        ResumeStore.shared.clear(key: item.origin.resumeKey)

        if isShuffling, playlist.count > 1 {
            goToNext()
        } else if currentIndex + 1 < playlist.count {
            goToNext()
        }
    }

    private func switchTo(index: Int) {
        guard playlist.indices.contains(index) else { return }

        currentIndex = index
        item = playlist[index]

        // Estado do vídeo anterior não pode vazar para o novo: um erro
        // mostrado antes bloquearia o alerta do próximo, e as faixas listadas
        // seriam as do arquivo errado.
        didPresentError = false
        lastSavedPosition = 0
        // A ampliação era do vídeo anterior; o novo pode nem ter o mesmo
        // formato de tela.
        videoZoom = 1
        videoOffset = .zero
        applyZoom()

        controls.title = item.title
        controls.update(currentTime: 0, duration: 0)
        controls.setVisible(true, animated: true)
        updateNavigation()

        refreshNowPlaying()
        loadNowPlayingArtwork()

        hud.show(.text(item.title))
        hud.hideAfterDelay(1.2)

        loadAndPlay()
    }

    private func updateNavigation() {
        controls.setNavigation(hasPrevious: currentIndex > 0,
                               hasNext: currentIndex + 1 < playlist.count)
    }

    private func togglePlayPause() {
        if engine.state == .playing {
            engine.pause()
        } else {
            engine.play()
            // `play()` volta para 1×; sem isto a velocidade escolhida some a
            // cada pausa.
            if playbackSpeed != 1.0 { engine.rate = playbackSpeed }
        }
        scheduleControlsHide()
    }

    // MARK: - Gestos

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        // Sem isso, um toque simples dispara antes de o duplo ser reconhecido.
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        view.addGestureRecognizer(longPress)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let zoomPan = UIPanGestureRecognizer(target: self, action: #selector(handleZoomPan))
        zoomPan.minimumNumberOfTouches = 2
        zoomPan.delegate = self
        view.addGestureRecognizer(zoomPan)

        // O relógio recomeça a cada toque, inclusive nos que caem em botões.
        let espiao = TouchSpyRecognizer()
        espiao.onTouch = { [weak self] in self?.userDidTouchScreen() }
        view.addGestureRecognizer(espiao)
    }

    /// Qualquer encostar de dedo com a barra na tela reinicia a contagem.
    ///
    /// Sem isto o relógio corria desde o instante em que a barra apareceu, e
    /// nunca era reiniciado: tocar num botão nove segundos depois deixava meio
    /// segundo antes de tudo sumir. Não era intermitente — dependia de quando
    /// no ciclo o toque acontecia, o que parece aleatório de fora.
    private func userDidTouchScreen() {
        guard gesturesEnabled, controls.isVisible, !controls.isLocked else { return }
        // Um gesto em curso já segura a barra por conta própria; reagendar no
        // meio dele faria a barra sumir com o dedo ainda na tela.
        guard panAxis == .undecided, !isBarScrubbing else { return }
        scheduleControlsHide()
    }

    private func setupSubtitleLabel() {
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        subtitleLabel.isHidden = true
        subtitleLabel.isUserInteractionEnabled = false
        // Contorno escuro em vez de fundo sólido: legenda sobre cena clara
        // some sem isso, e uma tarja preta atravessada na imagem é pior.
        subtitleLabel.layer.shadowColor = UIColor.black.cgColor
        subtitleLabel.layer.shadowOpacity = 1
        subtitleLabel.layer.shadowRadius = 3
        subtitleLabel.layer.shadowOffset = .zero
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            // Acima da barra inferior, para os controles não taparem a fala.
            subtitleLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -70),
        ])
    }

    /// Com a tela bloqueada, todo gesto é ignorado — é para isso que serve.
    private var gesturesEnabled: Bool { !controls.isLocked }

    /// Faz os botões físicos de volume mostrarem o nosso indicador.
    ///
    /// O iOS esconde o indicador dele quando existe um `MPVolumeView` na tela —
    /// e é ele que nos permite controlar o volume pelo gesto. Em vez de perder
    /// o retorno visual, os botões passam a usar o mesmo balão do gesto: um só
    /// indicador para as duas formas de mexer no volume.
    private func observeHardwareVolume() {
        let sessao = AVAudioSession.sharedInstance()
        volumeObservation = sessao.observe(\.outputVolume, options: [.new]) { [weak self] _, mudanca in
            guard let novo = mudanca.newValue else { return }
            Task { @MainActor in
                guard let self else { return }
                self.hud.show(.volume(novo))
                self.hud.hideAfterDelay(1.0)
            }
        }
    }

    /// Mostrar os controles acontece no instante em que o dedo encosta, e não
    /// num gesto reconhecido.
    ///
    /// O toque único precisa esperar o sistema descartar a hipótese de toque
    /// duplo — uns 0,3 s. Nesse intervalo parece que nada aconteceu, então o
    /// usuário toca de novo, vira toque duplo e o vídeo pausa. Respondendo já
    /// no toque, a barra aparece na hora e o gesto duplo continua valendo para
    /// o que ele serve.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard gesturesEnabled else { return }

        if controls.isVisible {
            // Barra já na tela: este toque é para escondê-la.
            mostrouNesteToque = false
        } else {
            mostrouNesteToque = true
            controls.setVisible(true, animated: true)
            scheduleControlsHide()
        }
    }

    /// Já visível, o toque simples esconde — o mostrar ficou no `touchesBegan`.
    ///
    /// Só que os dois eram o mesmo dedo. Mostrar acontece no encostar; o toque
    /// simples só é reconhecido uns 0,3 s depois, quando o toque duplo desiste.
    /// Nesse intervalo a barra já estava visível, então o mesmo toque que a
    /// trouxe a mandava embora — ela piscava e sumia. Tocar num botão parecia
    /// funcionar porque aí nem um nem outro chegava a rodar.
    @objc private func handleSingleTap() {
        guard gesturesEnabled, controls.isVisible else { return }
        guard !mostrouNesteToque else {
            mostrouNesteToque = false
            return
        }
        controls.setVisible(false, animated: true)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesturesEnabled else { return }
        let x = gesture.location(in: view).x
        let third = view.bounds.width / 3

        if x < third {
            jump(by: -Tuning.doubleTapSeconds)
        } else if x > third * 2 {
            jump(by: Tuning.doubleTapSeconds)
        } else {
            togglePlayPause()
        }
    }

    private func jump(by delta: Double) {
        let target = max(0, min(engine.currentTime + delta, engine.duration))
        hud.show(.seek(delta: delta, target: target, duration: engine.duration))
        Task { await engine.seek(to: target, precise: false) }
        hud.hideAfterDelay()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesturesEnabled else { return }
        switch gesture.state {
        case .began:
            guard engine.state == .playing else { return }
            rateBeforeHold = engine.rate
            engine.rate = Tuning.holdToSpeedRate
            hud.show(.rate(Tuning.holdToSpeedRate))
        case .ended, .cancelled, .failed:
            guard engine.rate == Tuning.holdToSpeedRate else { return }
            engine.rate = rateBeforeHold
            hud.hideAfterDelay()
        default:
            break
        }
    }

    /// Pinça amplia e reduz a imagem, como em qualquer foto no iPhone.
    ///
    /// Antes ela percorria os modos de enquadramento — mas para isso já existe
    /// o botão "Enquadrar", e nenhum outro app do aparelho usa a pinça assim.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesturesEnabled else { return }

        switch gesture.state {
        case .changed:
            videoZoom = min(max(videoZoom * gesture.scale, zoomRange.lowerBound), zoomRange.upperBound)
            gesture.scale = 1
            applyZoom()
            hud.show(.text("\(Int(videoZoom * 100))%"))
            controlsHideWorkItem?.cancel()

        case .ended, .cancelled, .failed:
            // Perto do tamanho original a pinça encaixa em 1×: acertar
            // exatamente 100% com dois dedos é impossível, e ficar em 1,03×
            // deixa a imagem tremida sem nenhum motivo.
            if abs(videoZoom - 1) < 0.08 {
                videoZoom = 1
                videoOffset = .zero
                applyZoom(animated: true)
            }
            hud.hideAfterDelay()
            scheduleControlsHide()

        default:
            break
        }
    }

    /// Dois dedos arrastando movem a imagem ampliada.
    ///
    /// Um dedo já é rolagem do vídeo e volume — mexer nisso custaria os gestos
    /// principais do app para servir a um caso ocasional.
    @objc private func handleZoomPan(_ gesture: UIPanGestureRecognizer) {
        guard gesturesEnabled, videoZoom > 1 else { return }

        switch gesture.state {
        case .changed:
            let passo = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            videoOffset.x += passo.x
            videoOffset.y += passo.y
            applyZoom()
            controlsHideWorkItem?.cancel()

        case .ended, .cancelled, .failed:
            scheduleControlsHide()

        default:
            break
        }
    }

    private func applyZoom(animated: Bool = false) {
        // A imagem não pode ser arrastada para fora de vista: o limite é a
        // sobra que a ampliação criou de cada lado.
        let sobraX = max(0, view.bounds.width * (videoZoom - 1) / 2)
        let sobraY = max(0, view.bounds.height * (videoZoom - 1) / 2)
        videoOffset.x = min(max(videoOffset.x, -sobraX), sobraX)
        videoOffset.y = min(max(videoOffset.y, -sobraY), sobraY)

        let transformacao = CGAffineTransform(translationX: videoOffset.x, y: videoOffset.y)
            .scaledBy(x: videoZoom, y: videoZoom)

        if animated {
            UIView.animate(withDuration: 0.2) { self.renderView.transform = transformacao }
        } else {
            renderView.transform = transformacao
        }
    }

    /// Volta a imagem ao tamanho original.
    private func resetZoom() {
        guard videoZoom != 1 || videoOffset != .zero else { return }
        videoZoom = 1
        videoOffset = .zero
        applyZoom(animated: true)
        hud.show(.text("100%"))
        hud.hideAfterDelay()
    }

    /// Mesma ação pelo botão da barra de ferramentas, aí sempre avançando.
    /// Percorre os enquadramentos e desfaz a ampliação.
    ///
    /// Enquadrar é justamente o botão de "ajeita isso aí": deixar a imagem
    /// ampliada por baixo faria o enquadramento novo chegar recortado, e daria
    /// a impressão de que o botão não fez nada.
    private func cycleAspect() {
        gravityIndex = (gravityIndex + 1) % gravityModes.count
        videoZoom = 1
        videoOffset = .zero
        applyZoom(animated: true)
        applyGravity()
        refreshToolStrip()
        scheduleControlsHide()
    }

    private func applyGravity() {
        let mode = gravityModes[gravityIndex]
        (renderView as? VideoGravityAdjustable)?.setGravity(mode)
        let texto = label(for: mode)
        hud.show(.text(texto))
        hud.hideAfterDelay()
    }

    private func label(for gravity: AVLayerVideoGravity) -> String {
        switch gravity {
        case .resizeAspectFill: return "Preencher"
        case .resize:           return "Esticar"
        default:                return "Ajustar"
        }
    }

    /// Alterna retrato/paisagem à força, como o botão de girar do MX Player.
    private func toggleOrientation() {
        guard let scene = view.window?.windowScene else { return }
        let alvo: UIInterfaceOrientationMask =
            scene.interfaceOrientation.isLandscape ? .portrait : .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: alvo))
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scheduleControlsHide()
    }

    // MARK: - Menu de ferramentas

    /// Monta a fileira de ferramentas sobre o vídeo.
    ///
    /// Refeita a cada mudança de estado para os destaques acompanharem — mudo
    /// ligado, repetição ativa, modo noturno em uso.
    private func refreshToolStrip() {
        var ferramentas: [ToolStripView.Tool] = [
            .init(id: "mudo",
                  symbol: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2",
                  title: "Mudo",
                  isOn: engine.isMuted) { [weak self] in
                      self?.engine.isMuted.toggle()
                      self?.refreshToolStrip()
                      self?.scheduleControlsHide()
                  },
            .init(id: "repetir", symbol: "repeat.1", title: "Repetir",
                  isOn: repeatMode == .one) { [weak self] in
                      guard let self else { return }
                      self.repeatMode = self.repeatMode == .one ? .off : .one
                      self.refreshToolStrip()
                  },
        ]

        if playlist.count > 1 {
            ferramentas.append(.init(id: "aleatorio", symbol: "shuffle", title: "Aleatório",
                                     isOn: isShuffling) { [weak self] in
                self?.isShuffling.toggle()
                self?.refreshToolStrip()
            })
        }

        ferramentas.append(contentsOf: [
            .init(id: "velocidade", symbol: "speedometer", title: "Velocidade",
                  isOn: playbackSpeed != 1.0) { [weak self] in self?.showSpeedSheet() },
            .init(id: "legendas", symbol: "captions.bubble", title: "Legendas",
                  isOn: engine.currentSubtitleTrack != nil) { [weak self] in
                      self?.showTracks(.subtitle)
                  },
            .init(id: "audio", symbol: "waveform", title: "Áudio") { [weak self] in
                self?.showTracks(.audio)
            },
            .init(id: "enquadramento", symbol: "rectangle.arrowtriangle.2.inward",
                  title: "Enquadrar") { [weak self] in self?.cycleAspect() },
            .init(id: "captura", symbol: "camera", title: "Captura") { [weak self] in
                self?.takeSnapshot()
            },
            .init(id: "noturno", symbol: "moon.stars", title: "Modo noturno",
                  isOn: dimView.alpha > 0) { [weak self] in self?.cycleNightMode() },
            .init(id: "dormir", symbol: "timer", title: "Dormir",
                  isOn: sleepTimer != nil) { [weak self] in self?.showSleepSheet() },
            .init(id: "girar", symbol: "rotate.right", title: "Girar tela") { [weak self] in
                self?.toggleOrientation()
            },
            .init(id: "zoom", symbol: "arrow.up.left.and.arrow.down.right",
                  title: "Ampliação", isOn: videoZoom != 1) { [weak self] in
                      self?.resetZoom()
                      self?.refreshToolStrip()
                      self?.scheduleControlsHide()
                  },
            .init(id: "interface", symbol: "clock.arrow.circlepath", title: "Ocultar barra",
                  isOn: PlayerPreferences.autoHide == .nunca) { [weak self] in
                      self?.showAutoHideSheet()
                  },
        ])

        ferramentas.append(.init(id: "pip", symbol: "pip.enter", title: "Janela flutuante") { [weak self] in
            self?.acionarPiP()
        })

        ferramentas.append(.init(id: "bloqueio", symbol: "lock", title: "Bloquear") { [weak self] in
            self?.controls.toggleLock()
        })

        controls.toolStrip.configure(with: ferramentas)
    }

    /// Percorre os níveis em vez de abrir um menu: uma ferramenta de um toque
    /// só, que é o ponto de ela estar na tela.
    private func cycleNightMode() {
        let niveis: [CGFloat] = [0, 0.25, 0.45, 0.65]
        let atual = niveis.firstIndex { abs($0 - dimView.alpha) < 0.01 } ?? 0
        let proximo = niveis[(atual + 1) % niveis.count]
        UIView.animate(withDuration: 0.2) { self.dimView.alpha = proximo }
        hud.show(.text(proximo == 0 ? "Modo noturno desligado"
                                    : "Modo noturno \(Int(proximo * 100))%"))
        hud.hideAfterDelay(1.2)
        refreshToolStrip()
    }

    private func showSpeedSheet() {
        let sheet = UIAlertController(title: "Velocidade", message: nil, preferredStyle: .actionSheet)
        for valor: Float in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let marca = abs(valor - playbackSpeed) < 0.01 ? "✓ " : ""
            let titulo = valor == rintf(valor) ? "\(Int(valor))×" : String(format: "%.2g×", valor)
            sheet.addAction(UIAlertAction(title: marca + titulo, style: .default) { [weak self] _ in
                guard let self else { return }
                self.playbackSpeed = valor
                if self.engine.state == .playing { self.engine.rate = valor }
                self.hud.show(.rate(valor))
                self.hud.hideAfterDelay()
                self.refreshToolStrip()
            })
        }
        sheet.addAction(UIAlertAction(title: "Fechar", style: .cancel))
        presentSheet(sheet)
    }

    private func showSleepSheet() {
        let sheet = UIAlertController(title: sleepTimerTitle(), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: sleepTimer == nil ? "✓ Desligado" : "Desligado",
                                      style: .default) { [weak self] _ in
            self?.cancelSleepTimer()
            self?.refreshToolStrip()
        })
        for minutos in [15, 30, 45, 60] {
            sheet.addAction(UIAlertAction(title: "\(minutos) minutos", style: .default) { [weak self] _ in
                self?.startSleepTimer(minutes: minutos)
                self?.refreshToolStrip()
            })
        }
        sheet.addAction(UIAlertAction(title: "No fim do vídeo", style: .default) { [weak self] _ in
            guard let self else { return }
            self.startSleepTimer(minutes: nil,
                                 seconds: max(1, self.engine.duration - self.engine.currentTime))
            self.refreshToolStrip()
        })
        sheet.addAction(UIAlertAction(title: "Fechar", style: .cancel))
        presentSheet(sheet)
    }

    /// Abre a janela flutuante, ou explica por que este vídeo não a tem.
    ///
    /// A janela do iOS é montada pelo sistema sobre a camada do AVPlayer. Nos
    /// arquivos que o AVFoundation recusa — HEVC marcado como `hev1`, MKV,
    /// tudo o que vem do servidor — quem toca é o VLC, que desenha por conta
    /// própria numa superfície que o sistema não sabe transportar para a
    /// janelinha. Não é opção nossa desligada: é uma porta que só a Apple abre.
    private func acionarPiP() {
        Task { @MainActor in
            if await pip?.toggle() == true { return }
            explicarPiPIndisponivel()
        }
    }

    private func explicarPiPIndisponivel() {
        let alerta = UIAlertController(
            title: "Janela flutuante indisponível",
            message: "O iOS só monta a janelinha sobre o reprodutor da Apple. "
                   + "Este arquivo está tocando no VLC, que abre formatos que a "
                   + "Apple recusa — e aí o sistema não tem como transportar a imagem.",
            preferredStyle: .alert)
        alerta.addAction(UIAlertAction(title: "Entendi", style: .default) { [weak self] _ in
            self?.scheduleControlsHide()
        })
        presentSheet(alerta)
    }

    /// Quanto tempo a barra fica na tela — o "Interface auto hide" do MX Player.
    private func showAutoHideSheet() {
        let atual = PlayerPreferences.autoHide
        let sheet = UIAlertController(title: "Ocultar barra depois de",
                                      message: nil, preferredStyle: .actionSheet)
        for opcao in PlayerPreferences.AutoHide.allCases {
            let marca = opcao == atual ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: marca + opcao.title, style: .default) { [weak self] _ in
                PlayerPreferences.autoHide = opcao
                self?.refreshToolStrip()
                // Reagenda já com o valor novo, para o efeito ser sentido
                // nesta mesma vez em vez de só no próximo toque.
                self?.scheduleControlsHide()
            })
        }
        sheet.addAction(UIAlertAction(title: "Fechar", style: .cancel))
        presentSheet(sheet)
    }

    private func buildToolsMenu() -> [UIMenuElement] {
        var itens: [UIMenuElement] = []

        itens.append(UIAction(title: engine.isMuted ? "Desativar mudo" : "Mudo",
                              image: UIImage(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2"),
                              state: engine.isMuted ? .on : .off) { [weak self] _ in
            self?.engine.isMuted.toggle()
        })

        itens.append(UIAction(title: "Repetir este vídeo",
                              image: UIImage(systemName: "repeat.1"),
                              state: repeatMode == .one ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.repeatMode = self.repeatMode == .one ? .off : .one
        })

        if playlist.count > 1 {
            itens.append(UIAction(title: "Aleatório",
                                  image: UIImage(systemName: "shuffle"),
                                  state: isShuffling ? .on : .off) { [weak self] _ in
                self?.isShuffling.toggle()
            })
        }

        itens.append(UIAction(title: "Captura de tela",
                              image: UIImage(systemName: "camera")) { [weak self] _ in
            self?.takeSnapshot()
        })

        itens.append(UIAction(title: "Janela flutuante",
                              image: UIImage(systemName: "pip.enter")) { [weak self] _ in
            self?.acionarPiP()
        })

        itens.append(UIMenu(title: "Modo noturno", image: UIImage(systemName: "moon.stars"),
                            children: nightModeActions()))
        itens.append(UIMenu(title: sleepTimerTitle(), image: UIImage(systemName: "timer"),
                            children: sleepTimerActions()))
        return itens
    }

    private func nightModeActions() -> [UIAction] {
        // O iOS já tem brilho mínimo; escurecer por cima vai além dele, que é
        // o que serve para assistir no escuro sem incomodar os olhos.
        let niveis: [(String, CGFloat)] = [("Desligado", 0), ("Leve", 0.25),
                                           ("Médio", 0.45), ("Forte", 0.65)]
        return niveis.map { nome, valor in
            UIAction(title: nome, state: abs(dimView.alpha - valor) < 0.01 ? .on : .off) { [weak self] _ in
                UIView.animate(withDuration: 0.2) { self?.dimView.alpha = valor }
            }
        }
    }

    private func sleepTimerTitle() -> String {
        guard let sleepDeadline else { return "Tempo para dormir" }
        let restante = max(0, sleepDeadline.timeIntervalSinceNow)
        return "Dormir em \(Int(restante / 60) + 1) min"
    }

    private func sleepTimerActions() -> [UIAction] {
        var acoes = [UIAction(title: "Desligado", state: sleepTimer == nil ? .on : .off) { [weak self] _ in
            self?.cancelSleepTimer()
        }]
        for minutos in [15, 30, 45, 60] {
            acoes.append(UIAction(title: "\(minutos) minutos") { [weak self] _ in
                self?.startSleepTimer(minutes: minutos)
            })
        }
        acoes.append(UIAction(title: "No fim do vídeo") { [weak self] _ in
            guard let self else { return }
            let restante = max(1, self.engine.duration - self.engine.currentTime)
            self.startSleepTimer(minutes: nil, seconds: restante)
        })
        return acoes
    }

    private func startSleepTimer(minutes: Int?, seconds: Double? = nil) {
        cancelSleepTimer()
        let intervalo = seconds ?? Double((minutes ?? 30) * 60)
        sleepDeadline = Date().addingTimeInterval(intervalo)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: intervalo, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.engine.pause()
                self?.cancelSleepTimer()
                self?.hud.show(.text("Pausado pelo temporizador"))
                self?.hud.hideAfterDelay(2.5)
            }
        }
        hud.show(.text("Dormir em \(Int(intervalo / 60)) min"))
        hud.hideAfterDelay(1.8)
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
    }

    private func takeSnapshot() {
        guard let imagem = engine.snapshot() else {
            hud.show(.text("Nada para capturar"))
            hud.hideAfterDelay(1.5)
            return
        }
        UIImageWriteToSavedPhotosAlbum(imagem, nil, nil, nil)
        hud.show(.text("Salvo em Fotos"))
        hud.hideAfterDelay(1.8)
    }

    // MARK: - Faixas de áudio e legenda


    private func showTracks(_ kind: PlayerControlsView.TrackKind) {
        controlsHideWorkItem?.cancel()

        let titulo = kind == .audio ? "Faixas de áudio" : "Legendas"
        let sheet = UIAlertController(title: titulo, message: nil, preferredStyle: .actionSheet)

        // As faixas vêm do motor, que já tem o arquivo aberto — e não de uma
        // sondagem à parte, que só funcionava para arquivos locais e deixava
        // os do servidor sem faixa nenhuma.
        let faixas = kind == .audio ? engine.audioTracks : engine.subtitleTracks
        let atual = kind == .audio ? engine.currentAudioTrack : engine.currentSubtitleTrack

        if kind == .subtitle {
            let acao = UIAlertAction(title: atual == nil ? "✓ Desligada" : "Desligada",
                                     style: .default) { [weak self] _ in
                self?.scheduleControlsHide()
                Task { await self?.engine.selectSubtitleTrack(nil) }
            }
            sheet.addAction(acao)
        }

        for faixa in faixas {
            let marca = faixa.id == atual ? "✓ " : ""
            let extra = faixa.isBitmap ? " (imagem)" : ""
            let acao = UIAlertAction(title: "\(marca)\(faixa.label)\(extra)", style: .default) { [weak self] _ in
                guard let self else { return }
                // Sem isto a barra ficava presa na tela depois de trocar de
                // faixa: abrir a lista cancela o agendamento e nada o repunha.
                self.scheduleControlsHide()
                Task {
                    if kind == .audio {
                        await self.engine.selectAudioTrack(faixa.id)
                    } else {
                        await self.engine.selectSubtitleTrack(faixa.id)
                    }
                }
            }
            sheet.addAction(acao)
        }

        if faixas.isEmpty {
            sheet.message = kind == .audio
                ? "Este arquivo tem só uma faixa de áudio."
                : "Este arquivo não tem legendas embutidas."
        }
        sheet.addAction(UIAlertAction(title: "Fechar", style: .cancel) { [weak self] _ in
            self?.scheduleControlsHide()
        })
        presentSheet(sheet)
    }

    private func presentSheet(_ sheet: UIAlertController) {
        // Em iPad o action sheet exige âncora, senão o app quebra.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesturesEnabled else { return }
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            panAxis = .undecided
            panStartTime = engine.currentTime
            panStartBrightness = UIScreen.main.brightness
            // Parte do volume que o aparelho está de fato tocando, e não de um
            // número interno — senão o gesto dá um salto ao começar.
            panStartVolume = systemVolume.value
            panIsOnLeftHalf = gesture.location(in: view).x < view.bounds.midX

        case .changed:
            if panAxis == .undecided {
                let dx = abs(translation.x), dy = abs(translation.y)
                guard max(dx, dy) > Tuning.axisLockThreshold else { return }
                panAxis = dx > dy ? .horizontal : .vertical
                // Qualquer gesto em curso segura os controles na tela.
                controlsHideWorkItem?.cancel()
                if panAxis == .horizontal {
                    controls.suppressBuffering = true
                    engine.beginScrub()
                }
            }

            switch panAxis {
            case .horizontal: updateSeekPan(translation.x)
            case .vertical:   updateVerticalPan(translation.y)
            case .undecided:  break
            }

        case .ended, .cancelled, .failed:
            if panAxis == .horizontal {
                commitSeekPan()
                engine.endScrub()
                controls.suppressBuffering = false
            }
            panAxis = .undecided
            scheduleControlsHide()
            hud.hideAfterDelay()

        default:
            break
        }
    }

    private func updateSeekPan(_ dx: CGFloat) {
        guard engine.duration > 0 else { return }

        // Escala a sensibilidade com a duração: num vídeo de 3 h, arrastar a
        // tela inteira por 2 min é inútil; num clipe de 40 s, 2 min é grosseiro.
        let span = min(max(engine.duration / 4, 30), Tuning.seekSecondsPerScreenWidth * 4)
        let secondsPerPoint = min(span, Tuning.seekSecondsPerScreenWidth) / Double(view.bounds.width)

        let delta = Double(dx) * secondsPerPoint
        let target = max(0, min(panStartTime + delta, engine.duration))

        // Só o tempo, sem caixa em volta: informa o destino sem tapar a cena.
        hud.show(.time(target))
        controls.update(currentTime: target, duration: engine.duration)

        // É aqui que mora a "rolagem integral": em vez de só mostrar um rótulo e
        // seekar no final, mandamos seeks precisos durante o arrasto. A coalescência
        // abaixo garante no máximo um seek em voo — sem isso a fila de seeks cresce
        // e o vídeo fica arrastando segundos atrás do dedo.
        requestScrubSeek(to: target)
    }

    /// Durante o arrasto quem manda é `scrub`, não `seek`.
    ///
    /// `seek` para o áudio, esvazia filas e reinicia o laço — custo alto
    /// demais para acontecer a cada movimento do dedo. `scrub` só decodifica e
    /// desenha o quadro daquele instante, que é o que produz a rolagem
    /// contínua em vez do salto de keyframe em keyframe.
    private func requestScrubSeek(to time: Double) {
        pendingSeekTarget = time
        engine.scrub(to: time)
    }

    /// Ao soltar o dedo, `endScrub` já busca para o ponto final e retoma a
    /// reprodução — buscar aqui também faria a mesma coisa duas vezes.
    private func commitSeekPan() {
        pendingSeekTarget = nil
    }

    private func updateVerticalPan(_ dy: CGFloat) {
        // Para cima aumenta: invertemos porque dy cresce para baixo no UIKit.
        let travel = view.bounds.height * Tuning.verticalTravelFraction
        let fraction = -dy / travel

        if panIsOnLeftHalf {
            let value = max(0, min(1, panStartBrightness + fraction))
            UIScreen.main.brightness = value
            hud.show(.brightness(Float(value)))
        } else {
            let value = max(0, min(1, panStartVolume + Float(fraction)))
            // Volume do aparelho, o mesmo dos botões laterais. Se o controle do
            // sistema não estiver acessível, cai no ganho interno do player
            // para o gesto não ficar inerte.
            if !systemVolume.set(value) {
                engine.volume = value
            }
            // Mostra o que o aparelho tem agora, não o que pedimos: se algo
            // limitar o valor, o número na tela seguiria mentindo.
            hud.show(.volume(systemVolume.value))
        }
    }

    // MARK: - Controles

    /// A barra de progresso usa o mesmo caminho do arrasto na tela.
    private func handleControlScrub(to time: Double, finished: Bool) {
        if finished {
            engine.endScrub()
            isBarScrubbing = false
            controls.suppressBuffering = false
            scheduleControlsHide()
        } else {
            if !isBarScrubbing {
                isBarScrubbing = true
                controls.suppressBuffering = true
                engine.beginScrub()
            }
            // Com o dedo na barra, esconder no meio do arrasto é o pior
            // momento possível: o cronômetro só volta a correr ao soltar.
            controlsHideWorkItem?.cancel()
            requestScrubSeek(to: time)
        }
    }

    private func scheduleControlsHide() {
        controlsHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Só o pausado segura os controles na tela — ali o usuário quer ver
            // o botão de play. Exigir `== .playing` deixava a barra presa para
            // sempre quando o motor reportava qualquer outro estado, como
            // "carregando", e nunca mais reagendava.
            guard self.engine.state != .paused else { return }
            self.controls.setVisible(false, animated: true)
        }
        // Em "Nunca" a barra fica até o usuário tocar na tela — o agendamento
        // simplesmente não acontece.
        guard let atraso = PlayerPreferences.autoHide.delay else {
            controlsHideWorkItem = nil
            return
        }
        controlsHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + atraso, execute: work)
    }
}

/// Pinçar e arrastar com dois dedos são o mesmo gesto para quem faz: um ajusta
/// o tamanho, o outro escolhe o pedaço, e exigir que aconteçam em turnos
/// deixaria a ampliação truncada.
extension PlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

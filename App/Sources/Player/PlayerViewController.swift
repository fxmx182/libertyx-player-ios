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
        static let controlsAutoHideDelay: TimeInterval = 2.0
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

    private var rateBeforeHold: Float = 1.0
    private var controlsHideWorkItem: DispatchWorkItem?
    private var didPresentError = false
    private var playbackSpeed: Float = 1.0
    private var lastSavedPosition: Double = 0

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

        controls.onCycleAspect = { [weak self] in self?.cycleAspect() }
        controls.onTogglePiP = { [weak self] in self?.pip?.toggle() }
        controls.moreMenuProvider = { [weak self] in self?.buildToolsMenu() ?? [] }

        // A janela flutuante é montada sobre a camada de desenho do motor
        // próprio. O VLC desenha do jeito dele, então o botão some quando ela
        // não está disponível — em vez de existir e não fazer nada.
        if let ffmpeg = engine as? FFmpegEngine {
            pip = PictureInPicture(engine: engine, layer: ffmpeg.displayLayer)
        }
        controls.setPiPAvailable(pip?.isSupported == true)
        refreshToolStrip()

        // Diz qual motor está em uso: sem isso não dá para comparar os dois na
        // prática, que é justamente o ponto de eles conviverem.
        let nome = (engine is FFmpegEngine) ? "Próprio" : "VLC"
        hud.show(.text("Motor: \(nome)"))
        hud.hideAfterDelay(1.4)

        installGestures()
        bindEngine()
        updateNavigation()
        loadAndPlay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Sair com a janela flutuante aberta é legítimo: o vídeo continua nela.
        guard pip?.isActive != true else { return }
        volumeObservation?.invalidate()
        volumeObservation = nil
        cancelSleepTimer()
        engine.teardown()
    }

    // MARK: - Motor

    private func bindEngine() {
        engine.onTimeUpdate = { [weak self] time in
            guard let self else { return }
            self.controls.update(currentTime: time, duration: self.engine.duration)
            self.saveResumePoint(time)
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
            if case .failed(let message) = state { self.presentError(message) }
            if state == .ended { self.handlePlaybackEnded() }
        }
    }

    private func loadAndPlay() {
        Task { @MainActor in
            do {
                try await engine.load(item)
                controls.update(currentTime: 0, duration: engine.duration)

                // Retomar é pergunta, não regra: às vezes se quer rever o
                // filme desde o começo, e voltar sozinho ao meio obriga a
                // desfazer na mão toda vez.
                if let retomada = ResumeStore.shared.position(for: item.origin.resumeKey),
                   retomada < engine.duration {
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
            Task { @MainActor in
                await self.engine.seek(to: instante, precise: false)
                self.engine.play()
                self.scheduleControlsHide()
            }
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

        controls.title = item.title
        controls.update(currentTime: 0, duration: 0)
        controls.setVisible(true, animated: true)
        updateNavigation()

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
        view.addGestureRecognizer(pinch)
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
        guard gesturesEnabled, !controls.isVisible else { return }
        controls.setVisible(true, animated: true)
        scheduleControlsHide()
    }

    /// Já visível, o toque simples esconde — o mostrar ficou no `touchesBegan`.
    @objc private func handleSingleTap() {
        guard gesturesEnabled, controls.isVisible else { return }
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

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesturesEnabled, gesture.state == .ended else { return }
        // Espalhar avança o modo, juntar volta.
        gravityIndex = gesture.scale > 1
            ? min(gravityIndex + 1, gravityModes.count - 1)
            : max(gravityIndex - 1, 0)
        applyGravity()
    }

    /// Mesma ação pelo botão da barra de ferramentas, aí sempre avançando.
    private func cycleAspect() {
        gravityIndex = (gravityIndex + 1) % gravityModes.count
        applyGravity()
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
        ])

        if pip?.isSupported == true {
            ferramentas.append(.init(id: "pip", symbol: "pip.enter", title: "Janela flutuante") { [weak self] in
                self?.pip?.toggle()
            })
        }

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

        if pip?.isSupported == true {
            itens.append(UIAction(title: "Janela flutuante",
                                  image: UIImage(systemName: "pip.enter")) { [weak self] _ in
                self?.pip?.toggle()
            })
        }

        itens.append(UIMenu(title: "Motor de vídeo", image: UIImage(systemName: "cpu"),
                            children: engineActions()))
        itens.append(UIMenu(title: "Modo noturno", image: UIImage(systemName: "moon.stars"),
                            children: nightModeActions()))
        itens.append(UIMenu(title: sleepTimerTitle(), image: UIImage(systemName: "timer"),
                            children: sleepTimerActions()))
        return itens
    }

    /// Trocar o motor vale para o próximo vídeo aberto.
    ///
    /// Trocar no meio da reprodução exigiria derrubar e remontar tudo — a tela,
    /// a posição, as faixas — e o ganho não paga o risco. Reabrir o vídeo é um
    /// gesto barato.
    private func engineActions() -> [UIAction] {
        EnginePreference.allCases.map { opcao in
            UIAction(title: opcao.label,
                     subtitle: opcao.detail,
                     state: opcao == EnginePreference.current ? .on : .off) { [weak self] _ in
                EnginePreference.current = opcao
                self?.hud.show(.text("Motor: \(opcao.label)\nvale ao reabrir o vídeo"))
                self?.hud.hideAfterDelay(2.5)
                self?.scheduleControlsHide()
            }
        }
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
                if panAxis == .horizontal { engine.beginScrub() }
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
            }
            panAxis = .undecided
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

        hud.show(.seek(delta: target - panStartTime, target: target, duration: engine.duration))
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
            scheduleControlsHide()
        } else {
            if !isBarScrubbing {
                isBarScrubbing = true
                engine.beginScrub()
            }
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
        controlsHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.controlsAutoHideDelay, execute: work)
    }
}

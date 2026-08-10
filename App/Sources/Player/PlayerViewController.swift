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
        static let controlsAutoHideDelay: TimeInterval = 3.5
    }

    private enum PanAxis { case undecided, horizontal, vertical }

    // MARK: - Estado

    private let engine: PlaybackEngine
    private let item: MediaItem

    private var renderView: UIView!
    private let hud = GestureHUDView()
    private let controls = PlayerControlsView()

    private var panAxis: PanAxis = .undecided
    private var panStartTime: Double = 0
    private var panStartBrightness: CGFloat = 0
    private var panStartVolume: Float = 1
    private var panIsOnLeftHalf = true

    private var pendingSeekTarget: Double?
    private var seekInFlight = false

    private var rateBeforeHold: Float = 1.0
    private var controlsHideWorkItem: DispatchWorkItem?
    private var didPresentError = false
    private var playbackSpeed: Float = 1.0
    /// Sondagem do FFmpeg, usada para listar faixas de áudio e legenda.
    private var mediaInfo: MediaInfo?

    private let gravityModes: [AVLayerVideoGravity] = [.resizeAspect, .resizeAspectFill, .resize]
    private var gravityIndex = 0

    // MARK: - Ciclo de vida

    init(engine: PlaybackEngine, item: MediaItem) {
        self.engine = engine
        self.item = item
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
        view.addSubview(renderView)

        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.isUserInteractionEnabled = false
        view.addSubview(hud)

        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: view.topAnchor),
            renderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            renderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

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
        controls.onSpeedChange = { [weak self] speed in
            guard let self else { return }
            self.playbackSpeed = speed
            if self.engine.state == .playing { self.engine.rate = speed }
            self.hud.show(.rate(speed))
            self.hud.hideAfterDelay()
            self.scheduleControlsHide()
        }
        controls.onCycleAspect = { [weak self] in self?.cycleAspect() }
        controls.onRotate = { [weak self] in self?.toggleOrientation() }
        controls.onShowTracks = { [weak self] kind in self?.showTracks(kind) }
        controls.onLockChange = { [weak self] locked in
            // Com a tela bloqueada nada some sozinho: o usuário bloqueou
            // justamente para nada mudar enquanto ele encosta na tela.
            if locked { self?.controlsHideWorkItem?.cancel() } else { self?.scheduleControlsHide() }
        }

        installGestures()
        bindEngine()
        loadAndPlay()
        probeMediaInfo()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        engine.teardown()
    }

    // MARK: - Motor

    private func bindEngine() {
        engine.onTimeUpdate = { [weak self] time in
            guard let self else { return }
            self.controls.update(currentTime: time, duration: self.engine.duration)
        }
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.controls.apply(state: state)
            if case .failed(let message) = state { self.presentError(message) }
        }
    }

    private func loadAndPlay() {
        Task { @MainActor in
            do {
                try await engine.load(item)
                controls.update(currentTime: 0, duration: engine.duration)
                engine.play()
                scheduleControlsHide()
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func presentError(_ message: String) {
        // `load` falha por duas vias ao mesmo tempo: o throw e a transição para
        // `.failed`. Sem esta trava o usuário levaria dois alertas empilhados.
        guard !didPresentError else { return }
        didPresentError = true

        controls.setVisible(true, animated: true)
        let alert = UIAlertController(title: "Não deu para tocar",
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Voltar", style: .default) { [weak self] _ in
            self?.close()
        })
        present(alert, animated: true)
    }

    private func close() {
        engine.teardown()
        dismiss(animated: true)
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

    /// Com a tela bloqueada, todo gesto é ignorado — é para isso que serve.
    private var gesturesEnabled: Bool { !controls.isLocked }

    @objc private func handleSingleTap() {
        guard gesturesEnabled else { return }
        controls.setVisible(!controls.isVisible, animated: true)
        if controls.isVisible { scheduleControlsHide() }
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
        (renderView as? PlayerLayerView)?.setGravity(mode)
        let texto = label(for: mode)
        controls.setAspectLabel(texto)
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

    // MARK: - Faixas de áudio e legenda

    private func probeMediaInfo() {
        guard case .file(let url, _) = item.origin else { return }
        let path = url.path
        Task { [weak self] in
            let resultado = await Task.detached(priority: .utility) {
                try? MediaProbe.probe(path: path)
            }.value
            self?.mediaInfo = resultado
        }
    }

    private func showTracks(_ kind: PlayerControlsView.TrackKind) {
        controlsHideWorkItem?.cancel()

        let titulo = kind == .audio ? "Faixas de áudio" : "Legendas"
        let sheet = UIAlertController(title: titulo, message: nil, preferredStyle: .actionSheet)

        guard let info = mediaInfo else {
            sheet.message = "Ainda lendo o arquivo…"
            sheet.addAction(UIAlertAction(title: "OK", style: .cancel))
            presentSheet(sheet)
            return
        }

        switch kind {
        case .audio:
            for faixa in info.audio {
                let idioma = MediaInfo.languageName(faixa.language) ?? "Faixa \(faixa.id)"
                let detalhe = "\(faixa.codec.uppercased()) · \(faixa.channelLayout)"
                sheet.addAction(UIAlertAction(title: "\(idioma) — \(detalhe)", style: .default))
            }
        case .subtitle:
            for faixa in info.subtitles {
                let idioma = MediaInfo.languageName(faixa.language) ?? faixa.codec.uppercased()
                let tipo = faixa.isBitmap ? "imagem" : "texto"
                sheet.addAction(UIAlertAction(title: "\(idioma) — \(tipo)", style: .default))
            }
        }

        if sheet.actions.isEmpty {
            sheet.message = "Este arquivo não tem \(kind == .audio ? "outras faixas de áudio" : "legendas embutidas")."
        } else {
            // Honestidade acima de fachada: os itens aparecem porque a sondagem
            // já funciona, mas trocar de faixa exige o motor FFmpeg tocando.
            sheet.message = "A troca de faixa chega junto com o motor FFmpeg."
        }
        sheet.addAction(UIAlertAction(title: "Fechar", style: .cancel))
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
            panStartVolume = engine.volume
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

    private func requestScrubSeek(to time: Double) {
        pendingSeekTarget = time
        guard !seekInFlight else { return }
        seekInFlight = true

        Task { @MainActor in
            while let target = pendingSeekTarget {
                pendingSeekTarget = nil
                await engine.seek(to: target, precise: true)
            }
            seekInFlight = false
        }
    }

    private func commitSeekPan() {
        let target = pendingSeekTarget ?? engine.currentTime
        pendingSeekTarget = nil
        Task { @MainActor in
            await engine.seek(to: target, precise: true)
        }
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
            engine.volume = value
            hud.show(.volume(value))
        }
    }

    // MARK: - Controles

    private func handleControlScrub(to time: Double, finished: Bool) {
        if finished {
            engine.endScrub()
            Task { await engine.seek(to: time, precise: true) }
            scheduleControlsHide()
        } else {
            if !seekInFlight { engine.beginScrub() }
            requestScrubSeek(to: time)
        }
    }

    private func scheduleControlsHide() {
        controlsHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.engine.state == .playing else { return }
            self.controls.setVisible(false, animated: true)
        }
        controlsHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.controlsAutoHideDelay, execute: work)
    }
}

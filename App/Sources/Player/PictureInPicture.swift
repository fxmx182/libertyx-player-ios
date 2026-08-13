import AVKit
import AVFoundation

/// Janela flutuante do iOS.
///
/// Funciona porque desenhamos em `AVSampleBufferDisplayLayer`: desde o iOS 15 o
/// sistema aceita montar o PiP sobre ela, sem exigir um `AVPlayer`. Se o vídeo
/// fosse desenhado em Metal próprio, isto não existiria — foi uma das razões
/// para escolher essa camada lá no começo do motor.
@MainActor
final class PictureInPicture: NSObject {

    private var controller: AVPictureInPictureController?
    private unowned let engine: PlaybackEngine

    /// Avisa quando a janela abre ou fecha, para a interface se ajustar.
    var onActiveChange: ((Bool) -> Void)?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Guardada para montar o controlador só quando for preciso.
    private let playerLayer: AVPlayerLayer?

    /// Caminho nativo: com uma `AVPlayerLayer` o sistema controla pausa,
    /// avanço e barra sozinho — não é preciso implementar delegado nenhum.
    ///
    /// O controlador não é montado aqui. `init(playerLayer:)` devolve nil
    /// enquanto a camada ainda não tem vídeo, e no instante em que a carga
    /// termina ela normalmente não tem — montar cedo demais deixava a janela
    /// flutuante indisponível para sempre naquele vídeo. Montamos no toque.
    init(playerLayer: AVPlayerLayer, engine: PlaybackEngine) {
        self.engine = engine
        self.playerLayer = playerLayer
        super.init()
    }

    @discardableResult
    private func prepararControlador() -> AVPictureInPictureController? {
        if let controller { return controller }
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let playerLayer,
              let novo = AVPictureInPictureController(playerLayer: playerLayer) else { return nil }
        novo.delegate = self
        novo.canStartPictureInPictureAutomaticallyFromInline = true
        controller = novo
        return novo
    }

    init(engine: PlaybackEngine, layer: AVSampleBufferDisplayLayer) {
        self.engine = engine
        self.playerLayer = nil
        super.init()

        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        let fonte = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self)

        let novo = AVPictureInPictureController(contentSource: fonte)
        novo.delegate = self
        // Entrar sozinho ao sair do app é o comportamento esperado de um
        // player: o usuário troca de app e o vídeo acompanha.
        novo.canStartPictureInPictureAutomaticallyFromInline = true
        controller = novo
    }

    /// `true` se a janela chegou a abrir; `false` se o sistema recusou.
    @discardableResult
    func toggle() -> Bool {
        guard let controller = prepararControlador() else {
            LabLog.problem("PiP indisponível: o sistema não montou o controlador")
            return false
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
        return true
    }
}

// MARK: - Reprodução dentro da janela

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        playing ? engine.play() : engine.pause()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController) -> CMTimeRange {
        // Duração desconhecida faz o iOS desenhar controles de transmissão ao
        // vivo, sem barra de progresso.
        guard engine.duration > 0 else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        return CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 600),
                           duration: CMTime(seconds: engine.duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController) -> Bool {
        engine.state != .playing
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        let destino = engine.currentTime + skipInterval.seconds
        Task { @MainActor in
            await engine.seek(to: destino, precise: false)
            completionHandler()
        }
    }
}

// MARK: - Ciclo da janela

extension PictureInPicture: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange?(false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        LabLog.problem("PiP não iniciou: \(error.localizedDescription)")
        onActiveChange?(false)
    }
}

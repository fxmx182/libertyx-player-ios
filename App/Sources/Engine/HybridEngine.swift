import UIKit
import AVFoundation

/// Escolhe o motor pelo arquivo, sem o usuário decidir nada.
///
/// Tenta primeiro o **AVPlayer da Apple**: ele busca com tolerância zero, o que
/// dá quadro exato, e tem janela flutuante nativa. É excelente justamente nos
/// MP4 gravados pelo celular — onde rolar quadro a quadro faz diferença.
///
/// Recusando o arquivo, entra o **VLC**, que abre praticamente tudo e é muito
/// superior em rede. É o caso dos MKV e dos vídeos do servidor, onde precisão
/// de quadro importa menos e robustez importa mais.
///
/// O motor só pode ser escolhido depois de tentar abrir o arquivo, mas a tela
/// de vídeo precisa existir antes disso. Por isso esta classe entrega um
/// contêiner vazio e instala dentro dele a superfície do motor que vencer.
@MainActor
final class HybridEngine: NSObject, PlaybackEngine {

    private let container = UIView()
    private var active: PlaybackEngine?

    /// Camada do AVPlayer, quando é ele que está tocando — é sobre ela que a
    /// janela flutuante do sistema é montada.
    private(set) var pictureInPictureLayer: AVPlayerLayer?

    // MARK: - Estado repassado

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onTimeUpdate: ((Double) -> Void)?
    var onStateChange: ((PlaybackState) -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    var onSubtitle: ((String?) -> Void)?

    var currentTime: Double { active?.currentTime ?? 0 }
    var duration: Double { active?.duration ?? 0 }

    var rate: Float {
        get { active?.rate ?? 1 }
        set { active?.rate = newValue }
    }

    var volume: Float {
        get { active?.volume ?? 1 }
        set { active?.volume = newValue }
    }

    var isMuted: Bool {
        get { active?.isMuted ?? false }
        set { active?.isMuted = newValue }
    }

    var audioTracks: [MediaTrack] { active?.audioTracks ?? [] }
    var subtitleTracks: [MediaTrack] { active?.subtitleTracks ?? [] }
    var currentAudioTrack: Int32? { active?.currentAudioTrack }
    var currentSubtitleTrack: Int32? { active?.currentSubtitleTrack }

    // MARK: - Carga

    func load(_ item: MediaItem) async throws {
        state = .loading

        // SMB nem chega a ser tentado no AVPlayer: ele não fala o protocolo, e
        // a tentativa só custaria tempo antes de cair no VLC de qualquer jeito.
        if case .smb = item.origin {
            try await adotar(VLCEngine(), item: item)
            return
        }

        let apple = AVPlayerEngine()
        do {
            try await apple.load(item)
            try await adotar(apple, item: item, jaCarregado: true)
            LabLog.open("motor: AVPlayer (busca exata)")
        } catch {
            // A recusa do AVFoundation é informação, não falha: significa
            // formato ou codec que ele não abre, e é exatamente aí que o VLC
            // entra. O usuário não precisa saber que houve uma tentativa.
            LabLog.open("AVPlayer recusou (\(error.localizedDescription)); usando VLC")
            apple.teardown()
            try await adotar(VLCEngine(), item: item)
        }
    }

    private func adotar(_ motor: PlaybackEngine, item: MediaItem,
                        jaCarregado: Bool = false) async throws {
        if !jaCarregado {
            try await motor.load(item)
        }

        // `PlaybackEngine` é limitado a classes, então atribuir aos callbacks
        // por uma referência constante funciona.
        motor.onTimeUpdate = { [weak self] tempo in self?.onTimeUpdate?(tempo) }
        motor.onBufferingChange = { [weak self] carregando in self?.onBufferingChange?(carregando) }
        motor.onSubtitle = { [weak self] texto in self?.onSubtitle?(texto) }
        motor.onStateChange = { [weak self] novo in self?.state = novo }

        let superficie = motor.makeRenderView()
        superficie.translatesAutoresizingMaskIntoConstraints = false
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(superficie)
        NSLayoutConstraint.activate([
            superficie.topAnchor.constraint(equalTo: container.topAnchor),
            superficie.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            superficie.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            superficie.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        pictureInPictureLayer = (superficie as? PlayerLayerView)?.playerLayer
        active = motor
        state = motor.state
    }

    // MARK: - Repasse

    func play() { active?.play() }
    func pause() { active?.pause() }
    func seek(to time: Double, precise: Bool) async { await active?.seek(to: time, precise: precise) }
    func scrub(to time: Double) { active?.scrub(to: time) }
    func beginScrub() { active?.beginScrub() }
    func endScrub() { active?.endScrub() }
    func snapshot() -> UIImage? { active?.snapshot() }
    func selectAudioTrack(_ id: Int32) async { await active?.selectAudioTrack(id) }
    func selectSubtitleTrack(_ id: Int32?) async { await active?.selectSubtitleTrack(id) }

    func makeRenderView() -> UIView { container }

    func teardown() {
        active?.teardown()
        active = nil
        pictureInPictureLayer = nil
        state = .idle
    }
}

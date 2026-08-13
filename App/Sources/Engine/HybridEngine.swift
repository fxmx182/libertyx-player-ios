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

    private let container = GravityForwardingView()
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
        vigia?.cancel()
        jaTrocouPorTravamento = false

        // SMB volta inteiro para o VLC.
        //
        // A ponte que faz o AVPlayer ler do servidor está escrita e compila,
        // mas na prática deu tela preta — e vídeo que tocava parou de tocar.
        // Ganho possível não paga perda certa: enquanto a ponte não for
        // provada, ela fica fora do caminho.
        if case .smb = item.origin {
            try await adotar(VLCEngine(), item: item)
            return
        }

        // Canal de TV também: o Jellyfin serve MPEG-TS contínuo sobre HTTP, e
        // o AVPlayer só sabe HLS.
        if item.isLiveStream {
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

    // MARK: - Vigia de travamento

    /// O item em reprodução, guardado para poder trocar de motor no meio.
    private var itemAtual: MediaItem?
    private var vigia: Task<Void, Never>?
    private var jaTrocouPorTravamento = false

    /// Um AVPlayer parado não reclama.
    ///
    /// Quando ele não consegue buscar os pedaços de um HLS — proxy no caminho,
    /// segmento recusado, o que for — ele não falha nem avisa: fica na tela
    /// preta esperando para sempre. Nenhum estado muda, então a tela não tem
    /// como saber que deu errado.
    ///
    /// O vigia mede o que importa de verdade: o tempo andou? Se em dez
    /// segundos tocando o relógio não saiu do lugar, o VLC assume de onde
    /// deveríamos estar. É o mesmo julgamento de sempre — robustez ganha de
    /// precisão quando a alternativa é não tocar nada.
    private func armarVigia() {
        vigia?.cancel()
        guard !jaTrocouPorTravamento, active is AVPlayerEngine, let item = itemAtual else { return }

        let partida = currentTime
        vigia = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.active is AVPlayerEngine, self.state == .playing else { return }
            guard abs(self.currentTime - partida) < 0.25 else { return }

            LabLog.problem("AVPlayer travado em \(item.title); passando para o VLC")
            self.jaTrocouPorTravamento = true
            let retomar = max(partida, 0)
            self.active?.teardown()
            try? await self.adotar(VLCEngine(), item: item)
            self.play()
            if retomar > 1 {
                await self.seek(to: retomar, precise: false)
            }
        }
    }

    private func adotar(_ motor: PlaybackEngine, item: MediaItem,
                        jaCarregado: Bool = false) async throws {
        itemAtual = item
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

        // O motor só é escolhido depois de abrir o arquivo, então a superfície
        // real chega aqui — e com ela, o enquadramento que o usuário já tinha
        // escolhido antes desta troca.
        container.reapplyGravity()

        pictureInPictureLayer = (superficie as? PlayerLayerView)?.playerLayer
        active = motor
        state = motor.state
    }

    // MARK: - Repasse

    func play() {
        active?.play()
        armarVigia()
    }
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
        vigia?.cancel()
        vigia = nil
        active?.teardown()
        active = nil
        pictureInPictureLayer = nil
        state = .idle
    }
}

/// O contêiner que o `HybridEngine` entrega à tela.
///
/// A tela pede o enquadramento a quem ela recebeu de `makeRenderView()` — e o
/// que ela recebe aqui é uma casca, porque o motor de verdade só é conhecido
/// depois de abrir o arquivo. Sem repassar o pedido, o botão "Enquadrar"
/// simplesmente não fazia nada: a casca não sabia responder e o `as?` falhava
/// em silêncio.
final class GravityForwardingView: UIView, VideoGravityAdjustable {

    private var ultimo: AVLayerVideoGravity = .resizeAspect

    func setGravity(_ gravity: AVLayerVideoGravity) {
        ultimo = gravity
        superficie?.setGravity(gravity)
    }

    /// Reaplica o que já estava escolhido a uma superfície recém-chegada.
    func reapplyGravity() {
        superficie?.setGravity(ultimo)
    }

    private var superficie: VideoGravityAdjustable? {
        subviews.compactMap { $0 as? VideoGravityAdjustable }.first
    }
}

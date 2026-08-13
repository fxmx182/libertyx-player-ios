import AVFoundation
import UIKit

/// Motor de referência sobre AVFoundation.
///
/// Serve para dois propósitos: fazer o app existir enquanto o motor FFmpeg não
/// está pronto, e ser o baseline de comparação. Ele já faz seek com tolerância
/// zero (frame-exato) para os codecs que a Apple suporta nativamente — o que o
/// VLC do iOS não faz. O que ele NÃO faz, e é por isso que o FFmpeg vem depois:
/// MKV, áudio DTS/TrueHD/AC3, legendas ASS, e leitura direta de SMB.
@MainActor
final class AVPlayerEngine: NSObject, PlaybackEngine {

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var scopedURL: URL?
    private var isScrubbing = false
    private var rateBeforeScrub: Float = 1.0

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

    // Este motor ficou como referência de comparação; seleção de faixa é
    // atribuição do motor FFmpeg, que enxerga todos os streams do contêiner.
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }
    func snapshot() -> UIImage? { nil }

    var audioTracks: [MediaTrack] { [] }
    var subtitleTracks: [MediaTrack] { [] }
    var currentAudioTrack: Int32? { nil }
    var currentSubtitleTrack: Int32? { nil }
    func selectAudioTrack(_ id: Int32) async {}
    func selectSubtitleTrack(_ id: Int32?) async {}

    var currentTime: Double {
        let t = player.currentTime()
        return t.isNumeric ? t.seconds : 0
    }

    var duration: Double {
        guard let d = player.currentItem?.duration, d.isNumeric else { return 0 }
        return d.seconds
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    override init() {
        super.init()
        configureAudioSession()
        player.automaticallyWaitsToMinimizeStalling = false
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Não é fatal: o vídeo ainda roda, só o comportamento em background muda.
            print("[LabPlayer] AVAudioSession: \(error.localizedDescription)")
        }
    }

    /// Ponte de leitura quando a origem é SMB. Precisa viver enquanto o asset
    /// viver — se ela sumir, o AVPlayer fica sem quem responda aos pedidos.
    private var smbBridge: SMBResourceLoader?
    /// Fila própria: o delegado é chamado em rajadas e não pode disputar a
    /// thread principal com a interface.
    private let smbQueue = DispatchQueue(label: "com.mauricio.labplayer.smbLoader")

    func load(_ item: MediaItem) async throws {
        state = .loading
        releaseScope()
        smbBridge?.teardown()
        smbBridge = nil

        let url: URL
        switch item.origin {
        case .file(let fileURL, let bookmark):
            url = try resolveFile(fileURL, bookmark: bookmark)
        case .remote(let remoteURL):
            url = remoteURL
        case .smb(let referencia, let caminho):
            // O AVFoundation não fala SMB — mas aceita que a gente fale por
            // ele. O delegado de recursos entrega os bytes; o formato continua
            // sendo problema dele.
            guard SMBResourceLoader.canHandle(path: caminho),
                  let servidor = SMBServerStore.shared.servers.first(where: { $0.id == referencia.serverID }),
                  let ponte = SMBResourceLoader(share: referencia.share, path: caminho,
                                                server: servidor,
                                                password: SMBServerStore.shared.password(for: servidor)),
                  let falsa = ponte.makeURL() else {
                state = .failed(PlaybackError.unsupportedOrigin.localizedDescription)
                throw PlaybackError.unsupportedOrigin
            }
            smbBridge = ponte
            url = falsa
        }

        // Duração exata só faz sentido em arquivo.
        //
        // Num HLS ela pede à AVFoundation que reconstrua a linha de tempo a
        // partir da mídia, e é isto que fazia o filme do servidor andar três
        // segundos e congelar. O reprodutor nativo do app oficial do Jellyfin
        // toca o mesmo stream sem nenhuma opção — foi comparando com ele que a
        // diferença apareceu.
        let ehTransmissao: Bool
        if case .remote = item.origin { ehTransmissao = true } else { ehTransmissao = false }

        let asset = ehTransmissao
            ? AVURLAsset(url: url)
            : AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // Precisa ser registrado antes de qualquer carga: é o primeiro pedido
        // do asset que descobre que ninguém sabe abrir este esquema.
        if let smbBridge {
            asset.resourceLoader.setDelegate(smbBridge, queue: smbQueue)
        }

        // Em arquivo, perguntar antes evita tela preta: sabendo que ele não
        // abre, o VLC assume sem o usuário ver nada. Numa transmissão a
        // pergunta é cara e enganosa — a resposta depende de rede, e obrigá-la
        // agora atrasa o começo sem garantir nada.
        if !ehTransmissao {
            let playable = try await asset.load(.isPlayable)
            guard playable else {
                let msg = "Formato não suportado pelo motor AVFoundation."
                state = .failed(msg)
                throw PlaybackError.loadFailed(msg)
            }
        }

        let playerItem = AVPlayerItem(asset: asset)
        // Também só em arquivo: numa transmissão isso amarra a busca ao ritmo
        // com que os pedaços chegam.
        playerItem.seekingWaitsForVideoCompositionRendering = !ehTransmissao
        attachObservers(to: playerItem)
        player.replaceCurrentItem(with: playerItem)
        state = .ready
    }

    private func resolveFile(_ url: URL, bookmark: Data?) throws -> URL {
        // O bookmark é da PASTA que autoriza, não do arquivo. Abrimos o escopo
        // dela aqui e o mantemos até `teardown()` — assim a reprodução não
        // depende de a tela de navegação continuar viva, que é frágil: o
        // SwiftUI dispara onDisappear nela ao apresentar o player em tela
        // cheia, e o escopo morreria no meio da leitura.
        if let bookmark {
            var stale = false
            if let pasta = try? URL(resolvingBookmarkData: bookmark,
                                    options: [],
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &stale),
               pasta.startAccessingSecurityScopedResource() {
                scopedURL = pasta
                return url
            }
        }
        // Arquivo escolhido avulso no seletor: o escopo é dele mesmo.
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
            return url
        }
        // Dentro do próprio sandbox do app, não há escopo a abrir.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw PlaybackError.securityScopeDenied
        }
        return url
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func attachObservers(to item: AVPlayerItem) {
        removeObservers()

        // 1/30s: fino o bastante para o HUD de tempo não tremer.
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.onTimeUpdate?(time.seconds)
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay: if self.state == .loading { self.state = .ready }
                case .failed:      self.state = .failed(item.error?.localizedDescription ?? "erro desconhecido")
                default:           break
                }
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(didReachEnd),
            name: .AVPlayerItemDidPlayToEndTime, object: item)
    }

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    @objc private func didReachEnd() {
        state = .ended
    }

    func play() {
        player.play()
        state = .playing
    }

    func pause() {
        player.pause()
        state = .paused
    }

    func seek(to time: Double, precise: Bool) async {
        guard duration > 0 else { return }
        let target = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        // Tolerância zero = frame exato. É mais caro, mas é o ponto do projeto.
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
        onTimeUpdate?(currentTime)
    }

    func scrub(to time: Double) {
        // O AVPlayer não expõe decodificação avulsa; aqui a busca precisa é o
        // mais próximo que dá para chegar.
        Task { await seek(to: time, precise: true) }
    }

    func beginScrub() {
        isScrubbing = true
        rateBeforeScrub = player.rate
        player.rate = 0
    }

    func endScrub() {
        isScrubbing = false
        player.rate = rateBeforeScrub
    }

    func makeRenderView() -> UIView {
        PlayerLayerView(player: player)
    }

    func teardown() {
        removeObservers()
        player.replaceCurrentItem(with: nil)
        releaseScope()
        smbBridge?.teardown()
        smbBridge = nil
        state = .idle
    }
}

/// UIView cuja layer de fundo é uma AVPlayerLayer — evita ter que sincronizar
/// frames manualmente no layout.
final class PlayerLayerView: UIView, VideoGravityAdjustable {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    /// Exposta porque o Picture in Picture do sistema é montado sobre ela.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    /// Modos de enquadramento do gesto de pinça.
    func setGravity(_ gravity: AVLayerVideoGravity) {
        playerLayer.videoGravity = gravity
    }
}

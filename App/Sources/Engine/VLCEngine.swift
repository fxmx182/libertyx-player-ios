import UIKit
import AVFoundation
import VLCKitSPM

/// Motor de reprodução sobre o VLCKit.
///
/// Substitui o motor próprio nas partes que se mostraram difíceis de acertar
/// do zero: sincronia entre som e imagem, buffer de rede e recuperação de
/// erro. São vinte anos de correções acumuladas contra alguns dias de código
/// meu — e o sintoma que mais atrapalhava, o vídeo do servidor travando,
/// vinha justamente daí.
///
/// Ganho secundário grande: o VLC fala SMB nativamente. Toda a ponte de
/// leitura por blocos, prazos e cache que eu tinha escrito vira uma URL
/// `smb://`.
@MainActor
final class VLCEngine: NSObject, PlaybackEngine {

    private let player = VLCMediaPlayer()
    private let container = VLCRenderView()
    private var pendingSeekWork: DispatchWorkItem?
    private var savedVolume: Float = 1.0

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onTimeUpdate: ((Double) -> Void)?
    var onStateChange: ((PlaybackState) -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    /// Nunca chamado: o VLC desenha a legenda dentro do próprio vídeo, então
    /// não há texto para a interface exibir por fora.
    var onSubtitle: ((String?) -> Void)?

    // MARK: - Estado básico

    var currentTime: Double { Double(player.time.intValue) / 1000 }

    var duration: Double {
        let ms = player.media?.length.intValue ?? 0
        return ms > 0 ? Double(ms) / 1000 : 0
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    /// O VLC trabalha com 0–200; acima de 100 é ganho além do original.
    var volume: Float {
        get { savedVolume }
        set {
            savedVolume = max(0, min(1, newValue))
            player.audio?.volume = Int32(savedVolume * 100)
        }
    }

    var isMuted: Bool {
        get { player.audio?.isMuted ?? false }
        set { player.audio?.isMuted = newValue }
    }

    override init() {
        super.init()
        player.delegate = self
        player.drawable = container
        container.attach(player)
    }

    // MARK: - Carga

    func load(_ item: MediaItem) async throws {
        state = .loading

        guard let url = try Self.resolveURL(for: item.origin) else {
            throw PlaybackError.unsupportedOrigin
        }

        let media = VLCMedia(url: url)
        // Buffer de rede generoso: é o que evita o vídeo travar quando a
        // leitura do servidor engasga. O padrão do VLC é curto demais para
        // arquivos de alta taxa num compartilhamento doméstico.
        if case .smb = item.origin {
            media.addOption(":network-caching=3000")
        } else {
            media.addOption(":file-caching=500")
        }

        player.media = media
        state = .ready
        LabLog.open("VLC pronto: \(item.title)")
    }

    /// Monta a URL que o VLC entende.
    ///
    /// No caso do SMB, as credenciais vão embutidas — é como o VLC as recebe.
    /// Elas continuam vindo do Keychain e nunca são gravadas em disco assim.
    private static func resolveURL(for origin: MediaOrigin) throws -> URL? {
        switch origin {
        case .file(let url, _):
            return url

        case .remote(let url):
            return url

        case .smb(let referencia, let caminho):
            guard let servidor = SMBServerStore.shared.servers.first(where: { $0.id == referencia.serverID }) else {
                throw PlaybackError.loadFailed("servidor não encontrado")
            }
            var credenciais = ""
            if !servidor.isGuest {
                let senha = SMBServerStore.shared.password(for: servidor) ?? ""
                // Codificar é obrigatório: senha com @ ou / quebraria a URL.
                let usuario = escape(servidor.username)
                credenciais = senha.isEmpty ? "\(usuario)@" : "\(usuario):\(escape(senha))@"
            }
            let partes = caminho.split(separator: "/").map { escape(String($0)) }.joined(separator: "/")
            let texto = "smb://\(credenciais)\(servidor.host)/\(escape(referencia.share))/\(partes)"
            return URL(string: texto)
        }
    }

    private static func escape(_ texto: String) -> String {
        texto.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? texto
    }

    // MARK: - Transporte

    func play() {
        player.play()
        if state != .playing { state = .playing }
    }

    func pause() {
        // `pause()` do VLC alterna; chamar com o vídeo já parado voltaria a
        // tocar, que é como se perde uma pausa.
        if player.isPlaying { player.pause() }
        state = .paused
    }

    func seek(to time: Double, precise: Bool) async {
        guard duration > 0 else { return }
        let alvo = max(0, min(time, duration))
        onBufferingChange?(true)
        player.time = VLCTime(int: Int32(alvo * 1000))
        onTimeUpdate?(alvo)
        onBufferingChange?(false)
    }

    // MARK: - Rolagem

    func beginScrub() {}

    /// Sem parar a reprodução: o VLC busca rápido o bastante para acompanhar o
    /// dedo, e parar/retomar a cada movimento causaria mais engasgo que fluidez.
    func scrub(to time: Double) {
        guard duration > 0 else { return }
        player.time = VLCTime(int: Int32(max(0, min(time, duration)) * 1000))
        onTimeUpdate?(time)
    }

    func endScrub() {}

    // MARK: - Faixas

    var audioTracks: [MediaTrack] {
        tracks(indexes: player.audioTrackIndexes, names: player.audioTrackNames)
    }

    var subtitleTracks: [MediaTrack] {
        tracks(indexes: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames)
    }

    var currentAudioTrack: Int32? {
        player.currentAudioTrackIndex >= 0 ? player.currentAudioTrackIndex : nil
    }

    var currentSubtitleTrack: Int32? {
        player.currentVideoSubTitleIndex >= 0 ? player.currentVideoSubTitleIndex : nil
    }

    func selectAudioTrack(_ id: Int32) async {
        player.currentAudioTrackIndex = id
    }

    func selectSubtitleTrack(_ id: Int32?) async {
        // -1 é como o VLC representa "sem legenda".
        player.currentVideoSubTitleIndex = id ?? -1
    }

    private func tracks(indexes: [Any]?, names: [Any]?) -> [MediaTrack] {
        guard let indexes, let names, indexes.count == names.count else { return [] }
        var resultado: [MediaTrack] = []

        for (indice, nome) in zip(indexes, names) {
            guard let numero = (indice as? NSNumber)?.int32Value,
                  let titulo = nome as? String else { continue }
            // O índice -1 é a entrada "Desativado" que o VLC inclui; a
            // interface já oferece essa opção por conta própria.
            guard numero >= 0 else { continue }
            resultado.append(MediaTrack(id: numero, codec: "", language: nil, title: titulo))
        }
        return resultado
    }

    // MARK: - Captura

    func snapshot() -> UIImage? {
        // O VLC desenha por aceleração de hardware, então capturar a hierarquia
        // de views devolveria um retângulo preto. `drawHierarchy` é o caminho
        // que enxerga o conteúdo já composto na tela.
        let renderer = UIGraphicsImageRenderer(bounds: container.bounds)
        let imagem = renderer.image { _ in
            container.drawHierarchy(in: container.bounds, afterScreenUpdates: false)
        }
        return imagem.size.width > 0 ? imagem : nil
    }

    func makeRenderView() -> UIView { container }

    func teardown() {
        player.stop()
        player.delegate = nil
        state = .idle
    }
}

// MARK: - Estado vindo do VLC

extension VLCEngine: VLCMediaPlayerDelegate {

    func mediaPlayerStateChanged(_ notification: Notification) {
        switch player.state {
        case .opening:   state = .loading
        case .buffering: onBufferingChange?(true)
        case .playing:
            onBufferingChange?(false)
            state = .playing
        case .paused:    state = .paused
        case .stopped:   state = .idle
        case .ended:     state = .ended
        case .error:     state = .failed("o VLC não conseguiu abrir este arquivo")
        default:         break
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        onBufferingChange?(false)
        onTimeUpdate?(currentTime)
    }
}

/// Superfície de desenho do VLC.
///
/// O enquadramento é do próprio VLC (`videoAspectRatio` / `scaleFactor`), e não
/// de uma layer nossa — por isso esta view é praticamente vazia.
final class VLCRenderView: UIView, VideoGravityAdjustable {

    private weak var player: VLCMediaPlayer?

    init(player: VLCMediaPlayer? = nil) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    func attach(_ player: VLCMediaPlayer) { self.player = player }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        guard let player else { return }
        switch gravity {
        case .resizeAspectFill:
            // Preencher cortando: o VLC faz isso ampliando a imagem.
            player.scaleFactor = 0
            player.videoCropGeometry = nil
            player.videoAspectRatio = nil
            player.scaleFactor = 1.4
        case .resize:
            player.scaleFactor = 0
            player.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: ("16:9" as NSString).utf8String)
        default:
            player.scaleFactor = 0
            player.videoAspectRatio = nil
            player.videoCropGeometry = nil
        }
    }
}

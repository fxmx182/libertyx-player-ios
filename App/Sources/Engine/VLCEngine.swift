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
    private var savedVolume: Float = 1.0
    /// Avisa a interface só na mudança.
    ///
    /// Emitir a cada atualização de tempo fazia o transporte piscar; emitir só
    /// quando o VLC anuncia "tocando" deixava o indicador aceso para sempre,
    /// porque ele emite "carregando" durante a reprodução normal e nem sempre
    /// volta a anunciar. Reagir à transição resolve os dois.
    private var buffering = false {
        didSet {
            guard buffering != oldValue else { return }
            onBufferingChange?(buffering)
        }
    }

    private var pendingScrub: Double?
    private var scrubWork: DispatchWorkItem?
    private var lastScrubApplied: CFTimeInterval = 0

    /// Permissão de leitura do arquivo, mantida enquanto a reprodução durar.
    ///
    /// No iOS quem autoriza é a pasta escolhida no seletor, e o acesso só vale
    /// com o escopo aberto. Sem isto o VLC recebe o caminho e não consegue ler
    /// — o contêiner é reconhecido, mas nenhuma faixa aparece, que é o sintoma
    /// exato de leitura barrada disfarçada de arquivo inválido.
    private var access: ScopedAccess?

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

        // Abre o escopo ANTES de entregar o caminho ao VLC, e o mantém: ele lê
        // o arquivo durante todo o filme, não só na abertura.
        if case .file(let fileURL, let bookmark) = item.origin {
            access = ScopedAccess(url: fileURL, bookmark: bookmark)
            guard access?.path != nil else { throw PlaybackError.securityScopeDenied }
        } else {
            access = nil
        }

        guard let url = try Self.resolveURL(for: item.origin) else {
            throw PlaybackError.unsupportedOrigin
        }

        let media = VLCMedia(url: url)
        Self.configurarBuffer(media, origem: item.origin)

        player.media = media
        state = .ready
        LabLog.open("VLC pronto: \(item.title)")
    }

    /// Quanto o VLC guarda adiantado antes de precisar.
    ///
    /// Dois mecanismos diferentes, e é preciso os dois no servidor:
    ///
    /// - **`network-caching`** é o fôlego do reprodutor: quantos milissegundos
    ///   de vídeo já decodificado ele mantém à frente. É o que absorve uma
    ///   engasgada da rede sem a imagem parar.
    /// - **`prefetch`** é o fôlego da leitura: um bloco grande em memória lido
    ///   adiantado, para que o pedido seguinte não vire uma ida ao servidor.
    ///   Sem ele, cada leitura é uma viagem de rede feita no exato momento em
    ///   que os bytes fazem falta.
    ///
    /// O que faz diferença ao arrastar a barra é o segundo: depois de uma
    /// busca, o bloco novo chega de uma vez em vez de gota a gota. Em troca,
    /// o vídeo demora um pouco mais para começar — é o preço de nunca engasgar
    /// no meio, e num filme inteiro esse preço se paga logo nos primeiros
    /// segundos.
    private static func configurarBuffer(_ media: VLCMedia, origem: MediaOrigin) {
        switch origem {
        case .smb, .remote:
            media.addOption(":network-caching=5000")
            // 32 MB adiantados: uns 20 segundos de um filme 1080p comum.
            media.addOption(":prefetch-buffer-size=32768")
            // Blocos de 256 KB em vez dos 16 KB padrão — menos idas ao
            // servidor, cada uma trazendo muito mais.
            media.addOption(":prefetch-read-size=262144")
            // Busca curta aproveita o que já está em memória em vez de jogar
            // fora e ler tudo de novo; é o caso de ajustar a posição no fino.
            media.addOption(":prefetch-seek-threshold=1048576")

        case .file:
            media.addOption(":file-caching=500")
        }
    }

    /// Monta a URL que o VLC entende.
    ///
    /// No caso do SMB, as credenciais vão embutidas — é como o VLC as recebe.
    /// Elas continuam vindo do Keychain e nunca são gravadas em disco assim.
    static func resolveURL(for origin: MediaOrigin) throws -> URL? {
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
        // Sem acender a roda: o VLC busca rápido, e o pisca-pisca do indicador
        // incomodava mais do que a espera que ele anunciava.
        player.time = VLCTime(int: Int32(alvo * 1000))
        onTimeUpdate?(alvo)
    }

    // MARK: - Rolagem

    func beginScrub() {}

    /// Rolagem com ritmo controlado.
    ///
    /// O dedo gera dezenas de eventos por segundo; mandar cada um para o VLC
    /// faz ele abortar e reiniciar a busca sem parar, e a imagem trava em vez
    /// de acompanhar. Aplicando no máximo a cada 80 ms, cada busca tem tempo de
    /// mostrar o quadro antes da próxima — o movimento fica contínuo.
    func scrub(to time: Double) {
        guard duration > 0 else { return }
        let alvo = max(0, min(time, duration))
        pendingScrub = alvo
        onTimeUpdate?(alvo)

        let agora = CACurrentMediaTime()
        guard agora - lastScrubApplied >= 0.08 else {
            agendarScrubPendente()
            return
        }
        aplicarScrub(alvo, em: agora)
    }

    private func aplicarScrub(_ alvo: Double, em instante: CFTimeInterval) {
        lastScrubApplied = instante
        pendingScrub = nil
        player.time = VLCTime(int: Int32(alvo * 1000))
    }

    /// Garante que o último ponto arrastado seja aplicado mesmo que o dedo
    /// pare — senão a imagem ficaria num ponto anterior ao que a barra mostra.
    private func agendarScrubPendente() {
        guard scrubWork == nil else { return }
        let trabalho = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrubWork = nil
            if let alvo = self.pendingScrub {
                self.aplicarScrub(alvo, em: CACurrentMediaTime())
            }
        }
        scrubWork = trabalho
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: trabalho)
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
        // Solta a permissão só depois de parar: fechar antes deixaria o VLC
        // lendo um arquivo que ele já não pode mais acessar.
        access = nil
        state = .idle
    }
}

// MARK: - Estado vindo do VLC

extension VLCEngine: VLCMediaPlayerDelegate {

    func mediaPlayerStateChanged(_ notification: Notification) {
        switch player.state {
        case .opening:   state = .loading
        case .buffering: buffering = true
        case .playing:
            buffering = false
            // O objeto de áudio do VLC só existe depois que a saída sobe;
            // reaplicar aqui garante que o ganho interno fique em 100% e o
            // volume que vale seja o do aparelho.
            player.audio?.volume = Int32(savedVolume * 100)
            state = .playing
        case .paused:    state = .paused
        case .stopped:   state = .idle
        case .ended:     state = .ended
        case .error:     state = .failed("o VLC não conseguiu abrir este arquivo")
        default:         break
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        // Tempo andando é a prova de que não está carregando — mais confiável
        // que o estado que o VLC anuncia. Como só emite na transição, isto não
        // volta a fazer o transporte piscar.
        buffering = false
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

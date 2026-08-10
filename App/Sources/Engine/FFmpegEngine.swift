import Foundation
import AVFoundation
import UIKit

/// Motor de reprodução sobre FFmpeg.
///
/// Toca o que o AVFoundation recusa — MKV, DTS, TrueHD, HEVC em perfis
/// exóticos — e, principalmente, toca direto de um servidor SMB, lendo só os
/// pedaços necessários.
///
/// O laço roda numa fila própria e é **regulado pelo vídeo**: cada quadro
/// espera o relógio do áudio alcançá-lo antes de ser exibido. Esse mesmo
/// bloqueio serve de freio para a decodificação inteira — sem ele, o
/// decodificador correria à frente e encheria a memória com o filme todo.
@MainActor
final class FFmpegEngine: NSObject, PlaybackEngine {

    private let queue = DispatchQueue(label: "com.mauricio.labplayer.engine", qos: .userInitiated)
    private let audio = AudioRenderer()
    private let renderView = VideoRenderView()

    private var session: FFmpegPlaybackSession?
    private lazy var clock = PlaybackClock(audio: audio)
    private var wantsPlayback = false
    private var lastKnownTime: Double = 0
    private var isSeeking = false
    private var scrubbingWasPlaying = false
    private var scrubInFlight = false
    private var pendingScrubTarget: Double?

    /// Avisa a interface que está buscando ou enchendo o buffer, para ela
    /// mostrar que a espera é carregamento e não travamento.
    var onBufferingChange: ((Bool) -> Void)?
    var onSubtitle: ((String?) -> Void)?
    /// Instante em que a legenda atual deve sair da tela.
    private var subtitleExpiry: Double = 0
    private var pendingSubtitles: [(text: String?, start: Double, end: Double)] = []

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onTimeUpdate: ((Double) -> Void)?
    var onStateChange: ((PlaybackState) -> Void)?

    private(set) var duration: Double = 0
    var currentTime: Double { lastKnownTime }

    var rate: Float = 1.0 {
        didSet { audio.rate = rate }
    }

    var volume: Float {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    var isMuted: Bool {
        get { audio.isMuted }
        set { audio.isMuted = newValue }
    }

    /// Último quadro exibido, guardado para captura de tela e para o PiP saber
    /// o tamanho do vídeo.
    private var lastPixelBuffer: CVPixelBuffer?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func snapshot() -> UIImage? {
        guard let lastPixelBuffer else { return nil }
        let imagem = CIImage(cvPixelBuffer: lastPixelBuffer)
        guard let cg = ciContext.createCGImage(imagem, from: imagem.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A camada onde o vídeo é desenhado — o PiP do iOS é montado sobre ela.
    var displayLayer: AVSampleBufferDisplayLayer { renderView.displayLayer }

    // MARK: - Carga

    func load(_ item: MediaItem) async throws {
        state = .loading
        stopLoop()

        let nova: FFmpegPlaybackSession
        switch item.origin {
        case .file:
            nova = try await openLocal(item.origin)
        case .smb(let referencia, let caminho):
            nova = try await openSMB(referencia, path: caminho)
        case .remote(let url):
            nova = try await FFmpegRunner.run { try FFmpegPlaybackSession(path: url.absoluteString) }
        }

        session = nova
        duration = nova.duration
        lastKnownTime = 0

        clock.expectsAudio = nova.audioFormat != nil

        if let formato = nova.audioFormat {
            do {
                try audio.prepare(sampleRate: formato.sampleRate, channels: formato.channelCount)
            } catch {
                clock.expectsAudio = false
                // Sem áudio o vídeo ainda serve; travar tudo por causa da
                // saída de som seria pior. O relógio cai para o de parede.
                LabLog.problem("saída de áudio indisponível: \(error.localizedDescription)")
            }
        }
        LabLog.open("sessão pronta: \(item.title)")
        state = .ready
    }

    private func openLocal(_ origin: MediaOrigin) async throws -> FFmpegPlaybackSession {
        // O escopo de segurança tem que estar aberto durante toda a
        // reprodução, não só na abertura — por isso ele é retido pela sessão.
        guard case .file(let url, let bookmark) = origin else {
            throw PlaybackError.unsupportedOrigin
        }
        let guarda = ScopedAccess(url: url, bookmark: bookmark)
        guard let caminho = guarda.path else { throw PlaybackError.securityScopeDenied }

        return try await FFmpegRunner.run {
            try FFmpegPlaybackSession(path: caminho, keepAlive: guarda)
        }
    }

    private func openSMB(_ referencia: SMBShareRef, path: String) async throws -> FFmpegPlaybackSession {
        guard let servidor = SMBServerStore.shared.servers.first(where: { $0.id == referencia.serverID }) else {
            throw PlaybackError.loadFailed("servidor não encontrado")
        }
        let senha = SMBServerStore.shared.password(for: servidor)
        let conexao = SMBConnection(server: servidor, password: senha)
        return try await conexao.makeSession(share: referencia.share, path: path)
    }

    // MARK: - Transporte

    func play() {
        guard session != nil else { return }
        wantsPlayback = true
        clock.start(at: lastKnownTime, rate: Double(rate))
        audio.play()
        state = .playing
        startLoop()
    }

    func pause() {
        wantsPlayback = false
        // Parar o laço é o que faltava: sem isso ele segue decodificando, e
        // como o relógio congelou todo quadro parece estar no futuro — o laço
        // dorme o teto de 100 ms antes de cada um e o vídeo continua andando
        // a 10 quadros por segundo. Câmera lenta em vez de pausa.
        stopLoop()
        clock.pause(at: lastKnownTime)
        audio.pause()
        state = .paused
    }

    func seek(to time: Double, precise: Bool) async {
        guard let session else { return }
        let alvo = max(0, min(time, duration))

        // Aborta a leitura de rede em andamento antes de qualquer coisa: sem
        // isso a busca fica na fila atrás de um download que pode levar
        // segundos, e a barra parece travada.
        session.requestInterrupt()
        stopLoop()
        isSeeking = true
        onBufferingChange?(true)
        renderView.flush()
        audio.reset(to: alvo)

        // Legendas do trecho antigo não valem mais nada depois de saltar.
        pendingSubtitles.removeAll()
        subtitleExpiry = 0
        onSubtitle?(nil)

        await withCheckedContinuation { continuation in
            queue.async {
                try? session.seek(to: alvo)
                continuation.resume()
            }
        }

        lastKnownTime = alvo
        clock.reset(to: alvo)
        onTimeUpdate?(alvo)
        isSeeking = false
        onBufferingChange?(false)

        if wantsPlayback {
            audio.play()
            startLoop(discardBefore: alvo)
        }
    }

    // MARK: - Faixas

    var audioTracks: [MediaTrack] { session?.audioTracks ?? [] }
    var subtitleTracks: [MediaTrack] { session?.subtitleTracks ?? [] }
    var currentAudioTrack: Int32? { session?.currentAudioTrack }
    var currentSubtitleTrack: Int32? { session?.currentSubtitleTrack }

    func selectAudioTrack(_ id: Int32) async {
        guard let session, id != session.currentAudioTrack else { return }
        let tocando = wantsPlayback
        let posicao = lastKnownTime

        session.requestInterrupt()
        stopLoop()
        onBufferingChange?(true)

        // A faixa nova pode ter outra taxa e outro número de canais, então a
        // saída de áudio é remontada do zero.
        audio.stop()
        let formato: AVAudioFormat? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: try? session.selectAudio(id))
            }
        }
        if let formato {
            try? audio.prepare(sampleRate: formato.sampleRate, channels: formato.channelCount)
            clock.expectsAudio = true
        } else {
            clock.expectsAudio = false
        }

        onBufferingChange?(false)
        // Volta ao ponto onde estava: sem isso, trocar de idioma reiniciaria o
        // filme, já que o decodificador novo começa do zero.
        await seek(to: posicao, precise: false)
        if tocando { play() }
    }

    func selectSubtitleTrack(_ id: Int32?) async {
        guard let session else { return }
        onSubtitle?(nil)
        await withCheckedContinuation { continuation in
            queue.async {
                try? session.selectSubtitle(id)
                continuation.resume()
            }
        }
        // Sem reposicionar, a legenda só apareceria a partir do próximo pacote
        // de legenda do arquivo — que pode estar minutos à frente.
        await seek(to: lastKnownTime, precise: false)
    }

    // MARK: - Rolagem integral

    /// Enquanto o dedo arrasta, a reprodução para e a tela passa a mostrar o
    /// quadro do instante sob o dedo. Parar é essencial: o laço e a rolagem
    /// usam a mesma sessão, e disputá-la embaralharia os dois.
    func beginScrub() {
        scrubbingWasPlaying = wantsPlayback
        wantsPlayback = false
        stopLoop()
        audio.pause()
        state = .paused
    }

    func scrub(to time: Double) {
        guard let session else { return }
        let alvo = max(0, min(time, duration))

        // Só o destino mais recente importa: o dedo já se moveu enquanto o
        // quadro anterior era decodificado. Sem esta coalescência a fila cresce
        // e a imagem fica segundos atrás do dedo — exatamente o defeito que
        // este projeto existe para não ter.
        pendingScrubTarget = alvo
        lastKnownTime = alvo
        onTimeUpdate?(alvo)

        guard !scrubInFlight else { return }
        scrubInFlight = true

        queue.async { [weak self] in
            while true {
                let destino: Double? = DispatchQueue.main.sync {
                    guard let self else { return nil }
                    defer { self.pendingScrubTarget = nil }
                    return self.pendingScrubTarget
                }
                guard let destino else { break }

                if let quadro = try? session.frame(at: destino) {
                    DispatchQueue.main.async { self?.renderView.display(quadro) }
                }
            }
            DispatchQueue.main.async { self?.scrubInFlight = false }
        }
    }

    func endScrub() {
        Task { @MainActor in
            await seek(to: lastKnownTime, precise: true)
            if scrubbingWasPlaying {
                wantsPlayback = true
                play()
            }
        }
    }

    func makeRenderView() -> UIView { renderView }

    func teardown() {
        stopLoop()
        audio.stop()
        session = nil
        state = .idle
    }

    // MARK: - Laço de reprodução

    /// `discardBefore` descarta o que vier antes desse instante.
    ///
    /// Depois de uma busca isso é essencial: o FFmpeg entrega a partir do
    /// keyframe ANTERIOR ao alvo, então os primeiros blocos de áudio são de
    /// antes do ponto pedido. Sem descartá-los, o som começa atrás do vídeo e
    /// fica atrás pelo resto da reprodução — era a causa do "áudio atrasado ao
    /// adiantar".
    private func startLoop(discardBefore: Double? = nil) {
        let geracao = clock.invalidate()
        guard let session else { return }
        let relogio = clock

        queue.async { [weak self] in
            self?.runLoop(session: session, clock: relogio,
                          generation: geracao, discardBefore: discardBefore)
        }
    }

    /// Não espera o laço terminar: ele percebe a geração obsoleta e sai
    /// sozinho no próximo quadro.
    private func stopLoop() {
        clock.invalidate()
    }

    /// Roda fora da thread principal.
    ///
    /// Nada aqui consulta a thread principal de forma síncrona. Uma versão
    /// anterior fazia isso duas vezes por quadro — a 30 fps, 60 bloqueios por
    /// segundo esperando a interface ficar livre, e o vídeo engasgava a cada
    /// toque na tela. Relógio e geração vivem em objetos com trava própria,
    /// consultáveis de qualquer thread.
    nonisolated private func runLoop(session: FFmpegPlaybackSession,
                                     clock: PlaybackClock,
                                     generation: Int,
                                     discardBefore: Double? = nil) {
        var quadrosExibidos = 0
        var blocosDeAudio = 0
        var primeiroQuadro = true
        // Tolerância pequena: um quadro de vídeo dura ~40 ms, e exigir
        // igualdade exata descartaria o quadro certo por arredondamento.
        let piso = discardBefore.map { $0 - 0.05 }

        while clock.generation == generation {
            let unidade: FFmpegPlaybackSession.Unit?
            do {
                unidade = try session.nextUnit()
            } catch {
                LabLog.problem("nextUnit falhou: \(error.localizedDescription)")
                unidade = nil
            }

            guard let unidade else {
                // Leitura abortada por uma busca também devolve nil. Sem esta
                // checagem, buscar no meio do filme seria interpretado como
                // fim do arquivo e pularia para o próximo vídeo.
                guard clock.generation == generation else {
                    LabLog.loop("leitura interrompida por busca")
                    return
                }
                LabLog.loop("fim do arquivo após \(quadrosExibidos) quadros e \(blocosDeAudio) blocos de áudio")
                Task { @MainActor [weak self] in self?.state = .ended }
                return
            }

            switch unidade {
            case .audio(let buffer, let instante):
                // Som de antes do ponto buscado não deve tocar: ele empurraria
                // todo o áudio para trás do vídeo.
                if let piso, instante < piso { continue }
                blocosDeAudio += 1
                if blocosDeAudio == 1 { LabLog.loop("primeiro áudio em \(String(format: "%.3f", instante))s") }
                clock.markAudioScheduled(until: instante)
                Task { @MainActor [weak self] in
                    self?.audio.schedule(buffer)
                    self?.reportTime(instante)
                }

            case .subtitle(let texto, let inicio, let fim):
                // A legenda é decodificada bem antes da hora de aparecer. Quem
                // decide quando exibir é o mesmo relógio do vídeo, no laço de
                // quadros — aqui só guardamos.
                Task { @MainActor [weak self] in
                    self?.enqueueSubtitle(texto, start: inicio, end: fim)
                }

            case .video(let pixelBuffer, let instante):
                if let piso, instante < piso { continue }
                // O primeiro quadro vai para a tela sem esperar. Além de tirar
                // o preto imediatamente, evita a armadilha de ficar esperando
                // um relógio que só começa a andar quando o áudio toca.
                if primeiroQuadro {
                    primeiroQuadro = false
                    LabLog.loop("primeiro quadro em \(String(format: "%.3f", instante))s, relógio em \(String(format: "%.3f", clock.now))s")
                } else {
                    // Espera o relógio alcançar o quadro. É também o freio da
                    // decodificação: sem esta pausa, o laço leria o arquivo
                    // inteiro o mais rápido possível e estouraria a memória.
                    let atraso = instante - clock.now
                    if atraso > 0 {
                        // Teto baixo de propósito. A busca é despachada na
                        // mesma fila do laço e só roda quando ele sai; dormir
                        // meio segundo significava meio segundo de barra
                        // travada a cada arrasto. Em 100 ms o laço volta,
                        // percebe a geração obsoleta e libera a fila.
                        Thread.sleep(forTimeInterval: min(atraso, 0.1))
                    }
                    // Mais de 200 ms atrasado: descartar é melhor que exibir
                    // tarde e acumular atraso quadro a quadro.
                    if atraso <= -0.2 { continue }
                }

                quadrosExibidos += 1
                if quadrosExibidos % 120 == 0 {
                    LabLog.loop("quadro \(quadrosExibidos) em \(String(format: "%.1f", instante))s, relógio \(String(format: "%.1f", clock.now))s")
                }

                Task { @MainActor [weak self] in
                    self?.lastPixelBuffer = pixelBuffer
                    self?.renderView.display(pixelBuffer)
                    self?.reportTime(instante)
                }
            }
        }
        LabLog.loop("laço encerrado (geração obsoleta) após \(quadrosExibidos) quadros")
    }

    private func reportTime(_ time: Double) {
        lastKnownTime = time
        onTimeUpdate?(time)

        // Tira a legenda da tela na hora certa. Sem isto, a última linha
        // ficaria pendurada até a próxima aparecer — que pode ser minutos
        // depois, num trecho sem diálogo.
        if subtitleExpiry > 0, time >= subtitleExpiry {
            subtitleExpiry = 0
            onSubtitle?(nil)
        }
        if let proxima = pendingSubtitles.first, time >= proxima.start {
            pendingSubtitles.removeFirst()
            subtitleExpiry = proxima.end
            onSubtitle?(proxima.text)
        }
    }

    private func enqueueSubtitle(_ text: String?, start: Double, end: Double) {
        pendingSubtitles.append((text, start, end))
        // A fila é pequena por natureza; este teto só protege contra arquivos
        // com legendas malformadas em rajada.
        if pendingSubtitles.count > 64 { pendingSubtitles.removeFirst() }
    }
}

/// Mantém aberto o escopo de segurança enquanto a reprodução durar.
///
/// Uma classe, e não uma função com `defer`, porque o escopo precisa durar o
/// tempo todo do vídeo — encerrá-lo na abertura faz a leitura falhar no meio,
/// com um erro que parece corrupção de arquivo.
final class ScopedAccess {
    private var scoped: URL?
    let path: String?

    init(url: URL, bookmark: Data?) {
        if let bookmark {
            var obsoleto = false
            if let pasta = try? URL(resolvingBookmarkData: bookmark, options: [],
                                    relativeTo: nil, bookmarkDataIsStale: &obsoleto),
               pasta.startAccessingSecurityScopedResource() {
                scoped = pasta
            }
        }
        if scoped == nil, url.startAccessingSecurityScopedResource() {
            scoped = url
        }
        path = FileManager.default.isReadableFile(atPath: url.path) ? url.path : nil
    }

    deinit {
        scoped?.stopAccessingSecurityScopedResource()
    }
}

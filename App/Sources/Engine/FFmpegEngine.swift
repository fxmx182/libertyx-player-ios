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
    private var loopGeneration = 0
    private var wantsPlayback = false

    /// Relógio de reserva para arquivos sem áudio.
    private var wallClockOrigin: CFTimeInterval = 0
    private var wallClockBase: Double = 0
    private var lastKnownTime: Double = 0

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

        if let formato = nova.audioFormat {
            try audio.prepare(sampleRate: formato.sampleRate, channels: formato.channelCount)
        }
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
        wallClockOrigin = CACurrentMediaTime()
        wallClockBase = lastKnownTime
        audio.play()
        state = .playing
        startLoop()
    }

    func pause() {
        wantsPlayback = false
        audio.pause()
        state = .paused
    }

    func seek(to time: Double, precise: Bool) async {
        guard let session else { return }
        let alvo = max(0, min(time, duration))

        stopLoop()
        renderView.flush()
        audio.reset(to: alvo)

        await withCheckedContinuation { continuation in
            queue.async {
                try? session.seek(to: alvo)
                continuation.resume()
            }
        }

        lastKnownTime = alvo
        wallClockOrigin = CACurrentMediaTime()
        wallClockBase = alvo
        onTimeUpdate?(alvo)

        if wantsPlayback {
            audio.play()
            startLoop()
        }
    }

    func beginScrub() { pause() }

    func endScrub() {
        guard state == .paused, wantsPlayback else { return }
        play()
    }

    func makeRenderView() -> UIView { renderView }

    func teardown() {
        stopLoop()
        audio.stop()
        session = nil
        state = .idle
    }

    // MARK: - Laço de reprodução

    private func startLoop() {
        loopGeneration += 1
        let geracao = loopGeneration
        guard let session else { return }

        queue.async { [weak self] in
            self?.runLoop(session: session, generation: geracao)
        }
    }

    private func stopLoop() {
        loopGeneration += 1
    }

    /// Roda fora da thread principal. `generation` é o que permite abandonar um
    /// laço antigo depois de uma busca sem esperar por ele.
    nonisolated private func runLoop(session: FFmpegPlaybackSession, generation: Int) {
        while true {
            let ainda = DispatchQueue.main.sync { [weak self] in
                self?.loopGeneration == generation
            }
            guard ainda else { return }

            let unidade: FFmpegPlaybackSession.Unit?
            do    { unidade = try session.nextUnit() }
            catch { unidade = nil }

            guard let unidade else {
                Task { @MainActor [weak self] in self?.state = .ended }
                return
            }

            switch unidade {
            case .audio(let buffer, let instante):
                Task { @MainActor [weak self] in
                    self?.audio.schedule(buffer)
                    self?.reportTime(instante)
                }

            case .video(let pixelBuffer, let instante):
                // Espera o relógio alcançar o quadro. É também o freio da
                // decodificação: sem esta pausa, o laço leria o arquivo inteiro
                // o mais rápido possível e estouraria a memória.
                let atraso = DispatchQueue.main.sync { [weak self] in
                    (self?.clock).map { instante - $0 } ?? 0
                }
                if atraso > 0 {
                    Thread.sleep(forTimeInterval: min(atraso, 0.5))
                }
                // Mais de 200 ms atrasado: descartar é melhor que exibir tarde
                // e acumular atraso quadro a quadro.
                guard atraso > -0.2 else { continue }

                Task { @MainActor [weak self] in
                    self?.renderView.display(pixelBuffer)
                    self?.reportTime(instante)
                }
            }
        }
    }

    /// Posição atual: o áudio manda; o relógio de parede só cobre o intervalo
    /// em que o áudio ainda não começou a render, ou arquivos mudos.
    private var clock: Double {
        if let doAudio = audio.currentTime { return doAudio }
        guard state == .playing else { return lastKnownTime }
        return wallClockBase + (CACurrentMediaTime() - wallClockOrigin) * Double(rate)
    }

    private func reportTime(_ time: Double) {
        lastKnownTime = time
        onTimeUpdate?(time)
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

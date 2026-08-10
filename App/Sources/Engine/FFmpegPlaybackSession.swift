import Foundation
import AVFoundation
import CoreVideo

/// Escolhe o formato de pixel do decodificador.
///
/// Precisa ser função de topo: é um ponteiro de função em C. Sem ela, o FFmpeg
/// escolhe o formato de software mesmo com contexto de hardware configurado, e
/// a aceleração simplesmente não acontece — silenciosamente.
private func selecionarFormatoDeHardware(
    _ context: UnsafeMutablePointer<AVCodecContext>?,
    _ formatos: UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat {
    var cursor = formatos
    while let atual = cursor?.pointee, atual != AV_PIX_FMT_NONE {
        if atual == AV_PIX_FMT_VIDEOTOOLBOX { return atual }
        cursor = cursor?.advanced(by: 1)
    }
    return formatos?.pointee ?? AV_PIX_FMT_NONE
}

/// Permite abortar leituras que o FFmpeg está fazendo agora.
///
/// Sem isto, pedir uma busca no meio de uma leitura de rede significa esperar
/// aquela leitura terminar — que num share SMB lento é o tempo todo em que a
/// barra fica travada.
final class InterruptToken {
    private let lock = NSLock()
    private var aborted = false

    var isAborted: Bool {
        lock.lock(); defer { lock.unlock() }
        return aborted
    }

    func abort() { lock.lock(); aborted = true; lock.unlock() }
    func clear() { lock.lock(); aborted = false; lock.unlock() }
}

/// O FFmpeg consulta esta função entre operações de I/O; devolver 1 faz ele
/// desistir e retornar erro em vez de seguir bloqueado.
private func verificarInterrupcao(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    let token = Unmanaged<InterruptToken>.fromOpaque(opaque).takeUnretainedValue()
    return token.isAborted ? 1 : 0
}

/// Demuxa e decodifica um arquivo, entregando quadros prontos para exibir e
/// blocos de áudio prontos para tocar.
///
/// Deliberadamente sem threads próprias: quem chama roda o laço na thread que
/// quiser. Concentrar o estado do FFmpeg num só lugar, sem concorrência
/// interna, elimina a classe de bug mais difícil de diagnosticar num player.
final class FFmpegPlaybackSession {

    enum Unit {
        case video(CVPixelBuffer, time: Double)
        case audio(AVAudioPCMBuffer, time: Double)
        case subtitle(text: String?, start: Double, end: Double)
    }

    // Contextos do FFmpeg
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var videoContext: UnsafeMutablePointer<AVCodecContext>?
    private var audioContext: UnsafeMutablePointer<AVCodecContext>?
    private var hardwareDevice: UnsafeMutablePointer<AVBufferRef>?
    private var resampler: OpaquePointer?
    private var scaler: OpaquePointer?

    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?

    private var subtitleContext: UnsafeMutablePointer<AVCodecContext>?
    private var videoIndex: Int32 = -1
    private var audioIndex: Int32 = -1
    private var subtitleIndex: Int32 = -1
    private var videoTimeBase = AVRational(num: 0, den: 1)
    private var audioTimeBase = AVRational(num: 0, den: 1)
    private var subtitleTimeBase = AVRational(num: 0, den: 1)

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    var currentAudioTrack: Int32? { audioIndex >= 0 ? audioIndex : nil }
    var currentSubtitleTrack: Int32? { subtitleIndex >= 0 ? subtitleIndex : nil }

    private var pixelBufferPool: CVPixelBufferPool?
    private var pending: [Unit] = []
    private var finished = false
    private let interrupt = InterruptToken()

    /// Mantida viva enquanto a sessão existir: o AVIOContext guarda só um
    /// ponteiro sem posse para a fonte de bytes do SMB.
    private let byteSource: AnyObject?

    private(set) var duration: Double = 0
    /// Instante do primeiro quadro do arquivo. Todos os tempos entregues são
    /// relativos a ele, de modo que a reprodução sempre comece em zero.
    private(set) var startTime: Double = 0
    private(set) var audioFormat: AVAudioFormat?

    var hasVideo: Bool { videoIndex >= 0 }
    var hasAudio: Bool { audioIndex >= 0 }

    // MARK: - Abertura

    /// `keepAlive` guarda o que precisa sobreviver enquanto a sessão existir —
    /// o escopo de segurança do arquivo local, ou a fonte de bytes do SMB.
    init(path: String, keepAlive: AnyObject? = nil) throws {
        byteSource = keepAlive
        var context: UnsafeMutablePointer<AVFormatContext>?
        try ffCheck("abrir arquivo", avformat_open_input(&context, path, nil, nil))
        formatContext = context
        try configure()
    }

    init(source: AVIOSource, keepAlive: AnyObject?) throws {
        byteSource = keepAlive
        guard let alocado = avformat_alloc_context() else {
            throw FFmpegError(code: labp_averror_enomem(), operation: "alocar contexto")
        }
        alocado.pointee.pb = source.context
        alocado.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        var context: UnsafeMutablePointer<AVFormatContext>? = alocado
        try ffCheck("abrir stream", avformat_open_input(&context, nil, nil, nil))
        formatContext = context
        try configure()
    }

    private func configure() throws {
        guard let formatContext else {
            throw FFmpegError(code: labp_averror_einval(), operation: "contexto vazio")
        }
        formatContext.pointee.interrupt_callback.callback = verificarInterrupcao
        formatContext.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(interrupt).toOpaque()

        try ffCheck("ler faixas", avformat_find_stream_info(formatContext, nil))

        duration = formatContext.pointee.duration.isNoPTS
            ? 0
            : Double(formatContext.pointee.duration) / Double(AV_TIME_BASE)

        // Nem todo arquivo começa no instante zero: MKV e MPEG-TS costumam
        // trazer o primeiro quadro carimbado em 10 s ou mais. Sem descontar
        // essa origem, o laço compara o carimbo com um relógio que começa em
        // zero, conclui que todo quadro está no futuro e espera para sempre —
        // tela parada com o app vivo.
        startTime = formatContext.pointee.start_time.isNoPTS
            ? 0
            : Double(formatContext.pointee.start_time) / Double(AV_TIME_BASE)

        packet = av_packet_alloc()
        frame = av_frame_alloc()
        guard packet != nil, frame != nil else {
            throw FFmpegError(code: labp_averror_enomem(), operation: "alocar buffers")
        }

        collectTracks()
        try openVideo()
        try openAudio()

        guard hasVideo || hasAudio else {
            throw PlaybackError.loadFailed("arquivo sem faixas reproduzíveis")
        }

        LabLog.open("""
            vídeo=\(hasVideo) hardware=\(hardwareDevice != nil) \
            áudio=\(hasAudio) duração=\(String(format: "%.1f", duration))s \
            início=\(String(format: "%.3f", startTime))s
            """)
    }

    /// Levanta as faixas do contêiner uma vez, na abertura.
    ///
    /// Vem daqui e não de uma sondagem à parte porque a sessão já tem o
    /// arquivo aberto — abrir de novo só para listar custaria outra rodada de
    /// leituras pela rede, e era o motivo de arquivos de SMB aparecerem sem
    /// faixa nenhuma.
    private func collectTracks() {
        guard let formatContext else { return }

        let bitmap: Set<String> = ["dvd_subtitle", "hdmv_pgs_subtitle", "dvb_subtitle", "xsub"]

        for indice in 0..<Int(formatContext.pointee.nb_streams) {
            guard let stream = formatContext.pointee.streams[indice],
                  let params = stream.pointee.codecpar else { continue }

            let codec = String(cString: avcodec_get_name(params.pointee.codec_id))
            let faixa = MediaTrack(
                id: stream.pointee.index,
                codec: codec,
                language: metadata(stream.pointee.metadata, "language"),
                title: metadata(stream.pointee.metadata, "title"),
                isBitmap: bitmap.contains(codec)
            )

            switch params.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:    audioTracks.append(faixa)
            case AVMEDIA_TYPE_SUBTITLE: subtitleTracks.append(faixa)
            default: continue
            }
        }
    }

    private func metadata(_ dicionario: OpaquePointer?, _ chave: String) -> String? {
        guard let dicionario, let entrada = av_dict_get(dicionario, chave, nil, 0),
              let valor = entrada.pointee.value else { return nil }
        let texto = String(cString: valor)
        return texto.isEmpty ? nil : texto
    }

    private func openVideo() throws {
        guard let formatContext else { return }
        var decoder: UnsafePointer<AVCodec>?
        let indice = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)
        guard indice >= 0, let decoder,
              let stream = formatContext.pointee.streams[Int(indice)],
              let params = stream.pointee.codecpar else { return }

        guard let context = avcodec_alloc_context3(decoder) else { return }
        try ffCheck("parâmetros de vídeo", avcodec_parameters_to_context(context, params))

        // VideoToolbox primeiro. Falhando, seguimos em software: melhor um
        // vídeo pesado tocando do que um erro na tela.
        if av_hwdevice_ctx_create(&hardwareDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0,
           let hardwareDevice {
            context.pointee.hw_device_ctx = av_buffer_ref(hardwareDevice)
            context.pointee.get_format = selecionarFormatoDeHardware
        }
        context.pointee.thread_count = 0

        guard avcodec_open2(context, decoder, nil) >= 0 else {
            var descartar: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&descartar)
            return
        }

        videoContext = context
        videoIndex = indice
        videoTimeBase = stream.pointee.time_base
    }

    private func openAudio(preferred: Int32? = nil) throws {
        guard let formatContext else { return }
        var decoder: UnsafePointer<AVCodec>?

        let indice: Int32
        if let preferred {
            indice = preferred
            guard let params = formatContext.pointee.streams[Int(preferred)]?.pointee.codecpar,
                  let achado = avcodec_find_decoder(params.pointee.codec_id) else { return }
            decoder = achado
        } else {
            indice = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
        }

        guard indice >= 0, let decoder,
              let stream = formatContext.pointee.streams[Int(indice)],
              let params = stream.pointee.codecpar else { return }

        guard let context = avcodec_alloc_context3(decoder) else { return }
        try ffCheck("parâmetros de áudio", avcodec_parameters_to_context(context, params))
        guard avcodec_open2(context, decoder, nil) >= 0 else {
            var descartar: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&descartar)
            return
        }

        // O AVAudioEngine quer Float32 não-intercalado; DTS, AC3 e companhia
        // entregam qualquer outra coisa. O resampler faz a ponte.
        let canais = max(1, min(2, context.pointee.ch_layout.nb_channels))
        var saida = AVChannelLayout()
        av_channel_layout_default(&saida, canais)

        var entrada = context.pointee.ch_layout
        let taxa = context.pointee.sample_rate

        try ffCheck("configurar resampler",
                    swr_alloc_set_opts2(&resampler,
                                        &saida, AV_SAMPLE_FMT_FLTP, taxa,
                                        &entrada, context.pointee.sample_fmt, taxa,
                                        0, nil))
        try ffCheck("iniciar resampler", swr_init(resampler))

        audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(taxa),
                                    channels: AVAudioChannelCount(canais))
        audioContext = context
        audioIndex = indice
        audioTimeBase = stream.pointee.time_base
    }

    // MARK: - Laço

    /// Próxima unidade decodificada, ou `nil` no fim do arquivo.
    func nextUnit() throws -> Unit? {
        if !pending.isEmpty { return pending.removeFirst() }
        guard !finished, let formatContext, let packet else { return nil }

        while pending.isEmpty {
            let resultado = av_read_frame(formatContext, packet)
            if resultado < 0 {
                // Fim dos pacotes: os decodificadores ainda podem ter quadros
                // guardados. Sem esta drenagem, o final do vídeo é cortado.
                finished = true
                drain(videoContext, isVideo: true)
                drain(audioContext, isVideo: false)
                break
            }

            if packet.pointee.stream_index == videoIndex {
                decode(videoContext, packet: packet, isVideo: true)
            } else if packet.pointee.stream_index == audioIndex {
                decode(audioContext, packet: packet, isVideo: false)
            } else if packet.pointee.stream_index == subtitleIndex {
                decodeSubtitle(packet)
            }
            av_packet_unref(packet)
        }

        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func decode(_ context: UnsafeMutablePointer<AVCodecContext>?,
                        packet: UnsafeMutablePointer<AVPacket>?,
                        isVideo: Bool) {
        guard let context, avcodec_send_packet(context, packet) >= 0 else { return }
        receive(context, isVideo: isVideo)
    }

    private func drain(_ context: UnsafeMutablePointer<AVCodecContext>?, isVideo: Bool) {
        guard let context else { return }
        avcodec_send_packet(context, nil)
        receive(context, isVideo: isVideo)
    }

    private func receive(_ context: UnsafeMutablePointer<AVCodecContext>, isVideo: Bool) {
        guard let frame else { return }
        while true {
            let resultado = avcodec_receive_frame(context, frame)
            if resultado.isTryAgain || resultado.isEndOfFile { return }
            guard resultado >= 0 else { return }

            let base = isVideo ? videoTimeBase : audioTimeBase
            let pts = frame.pointee.best_effort_timestamp
            let bruto = pts.isNoPTS ? 0 : Double(pts) * av_q2d(base)
            let instante = max(0, bruto - startTime)

            if isVideo {
                if let pixelBuffer = makePixelBuffer(from: frame) {
                    pending.append(.video(pixelBuffer, time: instante))
                }
            } else if let buffer = makeAudioBuffer(from: frame) {
                pending.append(.audio(buffer, time: instante))
            }
            av_frame_unref(frame)
        }
    }

    // MARK: - Conversão de vídeo

    private func makePixelBuffer(from frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        // Caminho do hardware: o VideoToolbox já devolve um CVPixelBuffer
        // pronto em data[3]. Zero cópia, zero conversão.
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
           let opaco = frame.pointee.data.3 {
            return Unmanaged<CVPixelBuffer>
                .fromOpaque(UnsafeRawPointer(opaco))
                .takeUnretainedValue()
        }
        return convertWithScaler(frame)
    }

    private func convertWithScaler(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let largura = frame.pointee.width
        let altura = frame.pointee.height
        guard largura > 0, altura > 0 else { return nil }

        if pixelBufferPool == nil {
            let atributos: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(largura),
                kCVPixelBufferHeightKey as String: Int(altura),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                          atributos as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            pixelBufferPool = pool
        }
        guard let pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool,
                                                 &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        if scaler == nil {
            scaler = sws_getContext(largura, altura, AVPixelFormat(frame.pointee.format),
                                    largura, altura, AV_PIX_FMT_BGRA,
                                    SWS_BILINEAR, nil, nil, nil)
        }
        guard let scaler else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let destino = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        var destinos: [UnsafeMutablePointer<UInt8>?] = [destino.assumingMemoryBound(to: UInt8.self),
                                                        nil, nil, nil]
        var passos = [Int32(CVPixelBufferGetBytesPerRow(pixelBuffer)), 0, 0, 0]

        withUnsafeBytes(of: &frame.pointee.data) { dados in
            withUnsafeBytes(of: &frame.pointee.linesize) { linhas in
                let origem = dados.baseAddress!.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                let passosOrigem = linhas.baseAddress!.assumingMemoryBound(to: Int32.self)
                _ = sws_scale(scaler, origem, passosOrigem, 0, altura, &destinos, &passos)
            }
        }
        return pixelBuffer
    }

    // MARK: - Conversão de áudio

    private func makeAudioBuffer(from frame: UnsafeMutablePointer<AVFrame>) -> AVAudioPCMBuffer? {
        guard let resampler, let audioFormat else { return nil }

        let maximo = swr_get_out_samples(resampler, frame.pointee.nb_samples)
        guard maximo > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat,
                                            frameCapacity: AVAudioFrameCount(maximo)),
              let canais = buffer.floatChannelData else { return nil }

        let numeroDeCanais = Int(audioFormat.channelCount)
        var saidas = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: numeroDeCanais)
        for indice in 0..<numeroDeCanais {
            saidas[indice] = UnsafeMutableRawPointer(canais[indice]).assumingMemoryBound(to: UInt8.self)
        }

        var convertidos: Int32 = 0
        withUnsafeBytes(of: &frame.pointee.data) { dados in
            let origem = dados.baseAddress!.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            convertidos = swr_convert(resampler, &saidas, maximo, origem, frame.pointee.nb_samples)
        }
        guard convertidos > 0 else { return nil }

        buffer.frameLength = AVAudioFrameCount(convertidos)
        return buffer
    }

    /// Decodifica o quadro correspondente a um instante e devolve só ele.
    ///
    /// É o coração da rolagem integral. Buscar leva ao keyframe ANTERIOR ao
    /// alvo — que pode estar até dez segundos atrás — e é por isso que os
    /// players que só fazem isso parecem pular. Aqui seguimos decodificando
    /// para frente até alcançar o instante pedido.
    ///
    /// `limite` existe porque um GOP longo num arquivo pela rede pode custar
    /// caro: passando dele, mostramos o quadro que temos. Melhor uma imagem
    /// levemente adiantada, na hora, do que o dedo esperando o quadro exato.
    func frame(at seconds: Double, limite: Int = 40) throws -> CVPixelBuffer? {
        try seek(to: seconds)

        var decodificados = 0
        var ultimo: CVPixelBuffer?

        while let unidade = try nextUnit() {
            guard case .video(let buffer, let instante) = unidade else { continue }
            decodificados += 1
            ultimo = buffer
            if instante >= seconds || decodificados >= limite { return buffer }
        }
        return ultimo
    }

    // MARK: - Troca de faixas

    /// Fecha o decodificador de áudio atual e abre o da faixa pedida.
    ///
    /// O formato de saída pode mudar (taxa, canais), então quem chama precisa
    /// reconfigurar a saída de áudio — por isso o retorno diz qual é o novo.
    @discardableResult
    func selectAudio(_ streamIndex: Int32) throws -> AVAudioFormat? {
        guard streamIndex != audioIndex else { return audioFormat }

        var antigo = audioContext
        avcodec_free_context(&antigo)
        audioContext = nil
        if resampler != nil { swr_free(&resampler) }
        audioIndex = -1
        audioFormat = nil

        try openAudio(preferred: streamIndex)
        pending.removeAll(where: { if case .audio = $0 { return true } else { return false } })
        return audioFormat
    }

    /// `nil` desliga a legenda.
    func selectSubtitle(_ streamIndex: Int32?) throws {
        var antigo = subtitleContext
        avcodec_free_context(&antigo)
        subtitleContext = nil
        subtitleIndex = -1

        guard let streamIndex, let formatContext,
              let stream = formatContext.pointee.streams[Int(streamIndex)],
              let params = stream.pointee.codecpar,
              let decoder = avcodec_find_decoder(params.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder) else { return }

        try ffCheck("parâmetros de legenda", avcodec_parameters_to_context(context, params))
        guard avcodec_open2(context, decoder, nil) >= 0 else {
            var descartar: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&descartar)
            return
        }
        subtitleContext = context
        subtitleIndex = streamIndex
        subtitleTimeBase = stream.pointee.time_base
    }

    /// Legendas usam a API antiga do FFmpeg (decode_subtitle2), não o par
    /// send/receive — não é descuido, é como a biblioteca expõe até hoje.
    private func decodeSubtitle(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let subtitleContext else { return }

        var legenda = AVSubtitle()
        var obteve: Int32 = 0
        guard avcodec_decode_subtitle2(subtitleContext, &legenda, &obteve, packet) >= 0,
              obteve != 0 else { return }
        defer { avsubtitle_free(&legenda) }

        let pts = packet.pointee.pts
        let bruto = pts.isNoPTS ? 0 : Double(pts) * av_q2d(subtitleTimeBase)
        let inicio = max(0, bruto - startTime) + Double(legenda.start_display_time) / 1000
        let fim = max(0, bruto - startTime) + Double(legenda.end_display_time) / 1000

        var linhas: [String] = []
        for indice in 0..<Int(legenda.num_rects) {
            guard let rect = legenda.rects[indice] else { continue }
            if let ass = rect.pointee.ass {
                linhas.append(Self.textoDeASS(String(cString: ass)))
            } else if let texto = rect.pointee.text {
                linhas.append(String(cString: texto))
            }
        }

        let texto = linhas.filter { !$0.isEmpty }.joined(separator: "\n")
        pending.append(.subtitle(text: texto.isEmpty ? nil : texto, start: inicio, end: fim))
    }

    /// Extrai o texto de uma linha de diálogo ASS.
    ///
    /// O formato é `Camada,Início,Fim,Estilo,Ator,ML,MR,MV,Efeito,Texto` — o
    /// texto é tudo depois da nona vírgula. Blocos `{...}` são comandos de
    /// formatação e `\N` é quebra de linha; sem tratar isso, a legenda aparece
    /// cheia de lixo na tela.
    static func textoDeASS(_ linha: String) -> String {
        var restante = Substring(linha)
        for _ in 0..<9 {
            guard let virgula = restante.firstIndex(of: ",") else { return "" }
            restante = restante[restante.index(after: virgula)...]
        }
        var texto = String(restante)
        while let abre = texto.firstIndex(of: "{"),
              let fecha = texto[abre...].firstIndex(of: "}") {
            texto.removeSubrange(abre...fecha)
        }
        return texto
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Busca

    /// Faz o FFmpeg desistir da leitura em andamento. Chamado de outra thread,
    /// antes de pedir uma busca, para não ficar preso atrás de uma leitura de
    /// rede que pode demorar segundos.
    func requestInterrupt() { interrupt.abort() }

    func seek(to seconds: Double) throws {
        interrupt.clear()
        guard let formatContext else { return }
        // O alvo volta para a régua do arquivo, que pode não começar em zero.
        let alvo = Int64((max(0, seconds) + startTime) * Double(AV_TIME_BASE))

        // BACKWARD garante cair antes do alvo: decodificar para frente é
        // possível, para trás não.
        try ffCheck("buscar", avformat_seek_file(formatContext, -1, Int64.min, alvo, alvo, AVSEEK_FLAG_BACKWARD))

        if let videoContext { avcodec_flush_buffers(videoContext) }
        if let audioContext { avcodec_flush_buffers(audioContext) }
        if let subtitleContext { avcodec_flush_buffers(subtitleContext) }
        pending.removeAll()
        finished = false
    }

    // MARK: - Liberação

    deinit {
        var packetRef = packet
        var frameRef = frame
        av_packet_free(&packetRef)
        av_frame_free(&frameRef)

        if let scaler { sws_freeContext(scaler) }
        if resampler != nil { swr_free(&resampler) }

        var video = videoContext
        var audio = audioContext
        avcodec_free_context(&video)
        avcodec_free_context(&audio)

        if hardwareDevice != nil { av_buffer_unref(&hardwareDevice) }

        var context = formatContext
        avformat_close_input(&context)
    }
}

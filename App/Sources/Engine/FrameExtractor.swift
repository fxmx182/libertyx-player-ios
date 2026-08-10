import Foundation
import CoreGraphics

/// Decodifica o frame exato de um instante do vídeo.
///
/// Esta é a peça central da "rolagem integral", em miniatura. O procedimento é
/// o mesmo que o MX Player usa e que falta ao VLC do iOS:
///
///   1. buscar o keyframe ANTERIOR ao instante desejado;
///   2. decodificar para frente descartando frames;
///   3. parar no primeiro cujo PTS alcança o alvo.
///
/// Um player que só faz o passo 1 salta de 2 a 10 segundos por vez — que é
/// exatamente a queixa que originou este projeto.
///
/// Decodificação por software de propósito: para um quadro avulso, a diferença
/// para o VideoToolbox é irrelevante, e evita a configuração de contexto de
/// hardware, que é onde essa etapa mais costuma quebrar.
enum FrameExtractor {

    /// Nenhuma miniatura precisa de 8K. Reduzir aqui evita alocar centenas de
    /// megabytes por quadro em vídeos grandes.
    private static let maxWidth: Int32 = 640

    static func image(path: String, at seconds: Double) throws -> CGImage {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        try ffCheck("abrir arquivo", avformat_open_input(&formatContext, path, nil, nil))
        defer { avformat_close_input(&formatContext) }
        guard let context = formatContext else {
            throw FFmpegError(code: labp_averror_einval(), operation: "abrir arquivo")
        }
        return try decode(context, at: seconds)
    }

    static func image(source: AVIOSource, at seconds: Double) throws -> CGImage {
        guard let alocado = avformat_alloc_context() else {
            throw FFmpegError(code: labp_averror_enomem(), operation: "alocar contexto")
        }
        alocado.pointee.pb = source.context
        alocado.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        var formatContext: UnsafeMutablePointer<AVFormatContext>? = alocado
        try ffCheck("abrir stream", avformat_open_input(&formatContext, nil, nil, nil))
        defer { avformat_close_input(&formatContext) }
        guard let context = formatContext else {
            throw FFmpegError(code: labp_averror_einval(), operation: "abrir stream")
        }
        return try decode(context, at: seconds)
    }

    // MARK: - Decodificação

    private static func decode(_ context: UnsafeMutablePointer<AVFormatContext>,
                               at seconds: Double) throws -> CGImage {

        try ffCheck("ler faixas", avformat_find_stream_info(context, nil))

        var decoder: UnsafePointer<AVCodec>?
        let streamIndex = try ffCheck(
            "achar faixa de vídeo",
            av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0))

        guard let stream = context.pointee.streams[Int(streamIndex)],
              let params = stream.pointee.codecpar,
              let decoder else {
            throw FFmpegError(code: labp_averror_einval(), operation: "faixa de vídeo")
        }

        guard let codecContext = avcodec_alloc_context3(decoder) else {
            throw FFmpegError(code: labp_averror_enomem(), operation: "alocar decodificador")
        }
        var codecContextRef: UnsafeMutablePointer<AVCodecContext>? = codecContext
        defer { avcodec_free_context(&codecContextRef) }

        try ffCheck("copiar parâmetros", avcodec_parameters_to_context(codecContext, params))
        // Mais de uma thread acelera bastante em H.264/HEVC de alta resolução.
        codecContext.pointee.thread_count = 0
        try ffCheck("abrir decodificador", avcodec_open2(codecContext, decoder, nil))

        let timeBase = stream.pointee.time_base
        let alvo = max(0, seconds)

        // AVSEEK_FLAG_BACKWARD garante que caímos ANTES do alvo — decodificar
        // para frente é possível, para trás não.
        if alvo > 0 {
            let timestamp = Int64(alvo / av_q2d(timeBase))
            try ffCheck("buscar", av_seek_frame(context, streamIndex, timestamp, AVSEEK_FLAG_BACKWARD))
            avcodec_flush_buffers(codecContext)
        }

        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else {
            throw FFmpegError(code: labp_averror_enomem(), operation: "alocar buffers")
        }
        var packetRef: UnsafeMutablePointer<AVPacket>? = packet
        var frameRef: UnsafeMutablePointer<AVFrame>? = frame
        defer {
            av_packet_free(&packetRef)
            av_frame_free(&frameRef)
        }

        // Teto de segurança: um GOP patológico não pode virar laço infinito.
        var quadrosDecodificados = 0
        let limite = 600

        while av_read_frame(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }

            guard avcodec_send_packet(codecContext, packet) >= 0 else { continue }

            while true {
                let resultado = avcodec_receive_frame(codecContext, frame)
                if resultado.isTryAgain || resultado.isEndOfFile { break }
                guard resultado >= 0 else {
                    throw FFmpegError(code: resultado, operation: "decodificar")
                }

                quadrosDecodificados += 1
                let pts = frame.pointee.best_effort_timestamp
                let instante = pts.isNoPTS ? 0 : Double(pts) * av_q2d(timeBase)

                // Chegamos ao alvo — ou já decodificamos demais procurando.
                if instante >= alvo || quadrosDecodificados >= limite {
                    return try convert(frame)
                }
                av_frame_unref(frame)
            }
        }

        // Fim do arquivo antes do alvo: vale o último quadro que temos.
        if frame.pointee.width > 0 { return try convert(frame) }
        throw FFmpegError(code: labp_averror_eof(), operation: "nenhum quadro decodificado")
    }

    /// AVFrame (YUV, normalmente) → CGImage (BGRA).
    private static func convert(_ frame: UnsafeMutablePointer<AVFrame>) throws -> CGImage {
        let larguraOrigem = frame.pointee.width
        let alturaOrigem = frame.pointee.height
        guard larguraOrigem > 0, alturaOrigem > 0 else {
            throw FFmpegError(code: labp_averror_einval(), operation: "quadro vazio")
        }

        let escala = min(1.0, Double(maxWidth) / Double(larguraOrigem))
        // Largura par: alguns formatos de origem exigem alinhamento.
        let largura = Int32((Double(larguraOrigem) * escala).rounded()) & ~1
        let altura = Int32((Double(alturaOrigem) * escala).rounded()) & ~1

        guard let sws = sws_getContext(
            larguraOrigem, alturaOrigem, AVPixelFormat(frame.pointee.format),
            largura, altura, AV_PIX_FMT_BGRA,
            SWS_BILINEAR, nil, nil, nil
        ) else {
            throw FFmpegError(code: labp_averror_einval(), operation: "converter cores")
        }
        defer { sws_freeContext(sws) }

        var destino = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
        var linhas = [Int32](repeating: 0, count: 4)
        try ffCheck("alocar imagem",
                    av_image_alloc(&destino, &linhas, largura, altura, AV_PIX_FMT_BGRA, 1))
        defer { av_freep(&destino[0]) }

        // Os planos do AVFrame são uma tupla em C; o Swift só chega neles
        // reinterpretando a memória.
        withUnsafeBytes(of: &frame.pointee.data) { dataBytes in
            withUnsafeBytes(of: &frame.pointee.linesize) { linesizeBytes in
                let origem = dataBytes.baseAddress!.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                let passos = linesizeBytes.baseAddress!.assumingMemoryBound(to: Int32.self)
                _ = sws_scale(sws, origem, passos, 0, alturaOrigem, &destino, &linhas)
            }
        }

        guard let base = destino[0] else {
            throw FFmpegError(code: labp_averror_enomem(), operation: "buffer de imagem")
        }
        let bytesPorLinha = Int(linhas[0])
        let dados = Data(bytes: base, count: bytesPorLinha * Int(altura))

        guard let provider = CGDataProvider(data: dados as CFData),
              let imagem = CGImage(
                width: Int(largura), height: Int(altura),
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPorLinha,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else {
            throw FFmpegError(code: labp_averror_einval(), operation: "montar imagem")
        }
        return imagem
    }
}

import Foundation

/// Tudo que o FFmpeg sabe dizer sobre um arquivo antes de tocá-lo.
struct MediaInfo {

    struct VideoTrack: Identifiable {
        let id: Int32
        var codec: String
        var width: Int32
        var height: Int32
        var frameRate: Double
        var pixelFormat: String
        var bitrate: Int64
        var language: String?

        var resolution: String { "\(width)×\(height)" }
    }

    struct AudioTrack: Identifiable {
        let id: Int32
        var codec: String
        var channels: Int32
        var channelLayout: String
        var sampleRate: Int32
        var bitrate: Int64
        var language: String?
        var title: String?
    }

    struct SubtitleTrack: Identifiable {
        let id: Int32
        var codec: String
        var language: String?
        var title: String?
        /// Legenda em bitmap (PGS, DVD) precisa ser desenhada, não renderizada
        /// como texto — muda completamente o caminho de exibição.
        var isBitmap: Bool
    }

    var formatName: String
    var formatLongName: String
    var duration: Double
    var bitrate: Int64
    var video: [VideoTrack] = []
    var audio: [AudioTrack] = []
    var subtitles: [SubtitleTrack] = []
}

/// Abre um arquivo com o FFmpeg e lê a estrutura dele.
///
/// Bloqueante: o FFmpeg lê disco/rede aqui. Chame de fora da thread principal.
enum MediaProbe {

    static func probe(path: String) throws -> MediaInfo {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?

        try ffCheck("abrir arquivo",
                    avformat_open_input(&formatContext, path, nil, nil))
        // A partir daqui há contexto alocado; qualquer saída precisa liberá-lo.
        defer { avformat_close_input(&formatContext) }

        guard let context = formatContext else {
            throw FFmpegError(code: labp_averror_einval(), operation: "abrir arquivo")
        }
        return try parse(context)
    }

    /// Mesma leitura, mas sobre uma fonte de bytes qualquer — é assim que um
    /// arquivo em servidor SMB é sondado sem ser baixado.
    static func probe(source: AVIOSource) throws -> MediaInfo {
        guard let alocado = avformat_alloc_context() else {
            throw FFmpegError(code: labp_averror_enomem(), operation: "alocar contexto")
        }
        alocado.pointee.pb = source.context
        // Sem esta flag o FFmpeg tentaria fechar e liberar o nosso AVIOContext,
        // que pertence ao AVIOSource.
        alocado.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        var formatContext: UnsafeMutablePointer<AVFormatContext>? = alocado
        try ffCheck("abrir stream",
                    avformat_open_input(&formatContext, nil, nil, nil))
        defer { avformat_close_input(&formatContext) }

        guard let context = formatContext else {
            throw FFmpegError(code: labp_averror_einval(), operation: "abrir stream")
        }
        return try parse(context)
    }

    private static func parse(_ context: UnsafeMutablePointer<AVFormatContext>) throws -> MediaInfo {
        // Sem isto, contêineres sem cabeçalho descritivo (MPEG-TS, por exemplo)
        // chegam sem codec identificado — o FFmpeg precisa decodificar um
        // pedaço para descobrir o que há dentro.
        try ffCheck("ler informações das faixas",
                    avformat_find_stream_info(context, nil))

        var info = MediaInfo(
            formatName: string(from: context.pointee.iformat?.pointee.name) ?? "?",
            formatLongName: string(from: context.pointee.iformat?.pointee.long_name) ?? "?",
            duration: context.pointee.duration.isNoPTS
                ? 0
                : Double(context.pointee.duration) / Double(AV_TIME_BASE),
            bitrate: context.pointee.bit_rate
        )

        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index],
                  let params = stream.pointee.codecpar else { continue }

            let codecName = string(from: avcodec_get_name(params.pointee.codec_id)) ?? "?"
            let language = metadata(stream.pointee.metadata, "language")
            let title = metadata(stream.pointee.metadata, "title")
            let streamID = stream.pointee.index

            switch params.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                // Capas embutidas em MP3/FLAC entram como stream de vídeo de um
                // frame só. Listá-las como faixa de vídeo confundiria o usuário.
                if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 { continue }

                let rate = av_guess_frame_rate(context, stream, nil)
                info.video.append(.init(
                    id: streamID,
                    codec: codecName,
                    width: params.pointee.width,
                    height: params.pointee.height,
                    frameRate: rate.den > 0 ? av_q2d(rate) : 0,
                    pixelFormat: string(from: av_get_pix_fmt_name(AVPixelFormat(params.pointee.format))) ?? "?",
                    bitrate: params.pointee.bit_rate,
                    language: language
                ))

            case AVMEDIA_TYPE_AUDIO:
                var layout = params.pointee.ch_layout
                var buffer = [CChar](repeating: 0, count: 128)
                av_channel_layout_describe(&layout, &buffer, buffer.count)

                info.audio.append(.init(
                    id: streamID,
                    codec: codecName,
                    channels: layout.nb_channels,
                    channelLayout: String(cString: buffer),
                    sampleRate: params.pointee.sample_rate,
                    bitrate: params.pointee.bit_rate,
                    language: language,
                    title: title
                ))

            case AVMEDIA_TYPE_SUBTITLE:
                let bitmapCodecs: Set<String> = ["dvd_subtitle", "hdmv_pgs_subtitle", "dvb_subtitle", "xsub"]
                info.subtitles.append(.init(
                    id: streamID,
                    codec: codecName,
                    language: language,
                    title: title,
                    isBitmap: bitmapCodecs.contains(codecName)
                ))

            default:
                continue
            }
        }

        return info
    }

    // MARK: - Auxiliares de interop

    private static func string(from pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    private static func metadata(_ dictionary: OpaquePointer?, _ key: String) -> String? {
        guard let dictionary else { return nil }
        guard let entry = av_dict_get(dictionary, key, nil, 0) else { return nil }
        guard let value = entry.pointee.value else { return nil }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }
}

extension MediaInfo {
    /// Nome de idioma legível a partir do código ISO 639 que o contêiner traz.
    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    static func humanBitrate(_ bits: Int64) -> String? {
        guard bits > 0 else { return nil }
        return bits >= 1_000_000
            ? String(format: "%.1f Mb/s", Double(bits) / 1_000_000)
            : "\(bits / 1000) kb/s"
    }
}

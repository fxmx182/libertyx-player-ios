import SwiftUI
import CoreGraphics

/// Detalhes técnicos de um arquivo local, lidos pelo FFmpeg.
///
/// Além de útil (é o que o MX Player mostra), esta tela é a prova de que o
/// motor funciona ponta a ponta: se um MKV aparece aqui com as faixas de áudio
/// e legenda corretas, então abrir contêiner, achar streams e identificar
/// codecs está tudo certo — que é a base de todo o resto.
struct MediaInfoView: View {

    let item: MediaItem

    @Environment(\.dismiss) private var dismiss
    @State private var info: MediaInfo?
    @State private var thumbnail: CGImage?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let info {
                    MediaInfoDetails(info: info,
                                     sizeText: FolderScanner.humanSize(item.fileSize),
                                     thumbnail: thumbnail)
                } else if let failure {
                    ContentUnavailableView("Não foi possível ler",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Lendo o arquivo…")
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
        .task(id: item.id) { await carregar() }
    }

    private func carregar() async {
        guard case .file = item.origin else {
            failure = "Só arquivos locais por enquanto."
            return
        }

        // O FFmpeg bloqueia lendo disco; fora da thread principal. E o escopo
        // de segurança precisa estar aberto durante a leitura, não apenas
        // quando esta tela apareceu.
        let origin = item.origin
        let resultado = await Task.detached(priority: .userInitiated) { () -> Result<MediaInfo, Error> in
            do {
                guard let lido = try FileAccess.withAccess(origin, { try MediaProbe.probe(path: $0) }) else {
                    return .failure(PlaybackError.securityScopeDenied)
                }
                return .success(lido)
            } catch {
                return .failure(error)
            }
        }.value

        switch resultado {
        case .success(let lido):
            info = lido
            await carregarQuadro(duracao: lido.duration)
        case .failure(let erro):
            failure = erro.localizedDescription
        }
    }

    /// 10% da duração: o início de muito filme é tela preta ou logotipo.
    private func carregarQuadro(duracao: Double) async {
        let instante = duracao > 0 ? duracao * 0.1 : 0
        let origin = item.origin
        thumbnail = await Task.detached(priority: .utility) {
            try? FileAccess.withAccess(origin) {
                try FrameExtractor.image(path: $0, at: instante)
            }
        }.value ?? nil
    }
}

/// Mesmos detalhes, sondados direto do servidor SMB — sem baixar o arquivo.
struct SMBMediaInfoView: View {

    let connection: SMBConnection
    let share: String
    let path: String
    let title: String
    let size: UInt64

    @Environment(\.dismiss) private var dismiss
    @State private var info: MediaInfo?
    @State private var thumbnail: CGImage?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let info {
                    MediaInfoDetails(info: info,
                                     sizeText: FolderScanner.humanSize(Int64(size)),
                                     thumbnail: thumbnail)
                } else if let failure {
                    ContentUnavailableView("Não foi possível ler",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Lendo pelo servidor…")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
        .task {
            do {
                let lido = try await connection.probe(share: share, path: path)
                info = lido
                let instante = lido.duration > 0 ? lido.duration * 0.1 : 0
                // O método passou a devolver quadro + duração; aqui só o quadro
                // interessa, já que a duração veio da sondagem acima.
                thumbnail = (try? await connection.thumbnail(share: share, path: path,
                                                            at: instante))?.image
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A lista de detalhes em si, separada de onde os dados vieram.
struct MediaInfoDetails: View {

    let info: MediaInfo
    var sizeText: String?
    var thumbnail: CGImage?

    var body: some View {
        List {
            if let thumbnail {
                Section {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .listRowInsets(EdgeInsets())
                } footer: {
                    // Não é enfeite: esta imagem é a prova de que o FFmpeg
                    // buscou um instante do vídeo e decodificou o quadro exato
                    // dali — o mesmo procedimento da rolagem frame a frame.
                    Text("Quadro decodificado pelo FFmpeg aos \(TimeFormat.clock(info.duration * 0.1)).")
                }
            }

            Section("Contêiner") {
                linha("Formato", info.formatName.uppercased())
                linha("Descrição", info.formatLongName)
                if info.duration > 0 {
                    linha("Duração", TimeFormat.clock(info.duration))
                }
                if let taxa = MediaInfo.humanBitrate(info.bitrate) {
                    linha("Taxa de bits", taxa)
                }
                if let sizeText {
                    linha("Tamanho", sizeText)
                }
            }

            if !info.video.isEmpty {
                Section("Vídeo") {
                    ForEach(info.video) { faixa in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(faixa.codec.uppercased()).font(.callout).fontWeight(.medium)
                            Text("\(faixa.resolution) · \(String(format: "%.3g", faixa.frameRate)) fps · \(faixa.pixelFormat)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let taxa = MediaInfo.humanBitrate(faixa.bitrate) {
                                Text(taxa).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !info.audio.isEmpty {
                Section("Áudio (\(info.audio.count))") {
                    ForEach(info.audio) { faixa in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(faixa.codec.uppercased()).font(.callout).fontWeight(.medium)
                                if let idioma = MediaInfo.languageName(faixa.language) {
                                    Text(idioma).font(.caption)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                }
                            }
                            Text("\(faixa.channelLayout) · \(faixa.sampleRate) Hz")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let titulo = faixa.title {
                                Text(titulo).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !info.subtitles.isEmpty {
                Section("Legendas (\(info.subtitles.count))") {
                    ForEach(info.subtitles) { faixa in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MediaInfo.languageName(faixa.language) ?? faixa.codec.uppercased())
                                if let titulo = faixa.title {
                                    Text(titulo).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(faixa.isBitmap ? "imagem" : "texto")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func linha(_ rotulo: String, _ valor: String) -> some View {
        HStack {
            Text(rotulo).foregroundStyle(.secondary)
            Spacer()
            Text(valor).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

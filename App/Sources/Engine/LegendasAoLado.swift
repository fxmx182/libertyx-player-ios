import Foundation

/// As legendas que moram ao lado do vídeo, em arquivo próprio (`.srt`, `.ass`).
///
/// O VLC acha sozinho as da pasta quando o arquivo está no aparelho, mas no
/// SMB, no WebDAV e no Jellyfin ele não enxerga a pasta. Aqui o app lista a
/// pasta do vídeo, ou pede ao Jellyfin as legendas "externas" dele, copia as
/// que combinam para a pasta temporária — são poucos KB — e o player as
/// entrega ao VLC como arquivo local.
///
/// Combina o que começa com o nome do vídeo, como no Jellyfin e no Plex:
/// `Filme.srt`, `Filme.pt.srt`, `Filme.pt.forced.srt`. O nome do arquivo segue
/// junto, e é por ele que a regra da legenda forçada a reconhece.
@MainActor
enum LegendasAoLado {

    private static let extensoes: Set<String> = ["srt", "ass", "ssa", "vtt"]

    /// Legenda bem maior que isto não é legenda: não vale baixar.
    private static let teto: UInt64 = 2 * 1024 * 1024

    nonisolated static func combina(video: String, arquivo: String) -> Bool {
        guard extensoes.contains((arquivo as NSString).pathExtension.lowercased()) else { return false }
        let base = (video as NSString).deletingPathExtension.lowercased()
        return !base.isEmpty && arquivo.lowercased().hasPrefix(base + ".")
    }

    /// Os arquivos já no aparelho, prontos para o VLC. Nunca falha: sem rede
    /// ou sem legenda, o vídeo toca igual, só sem elas.
    static func buscar(_ origem: MediaOrigin) async -> [URL] {
        let destino = FileManager.default.temporaryDirectory.appendingPathComponent("legendas", isDirectory: true)
        // Só as do vídeo da vez: as dos anteriores não servem mais.
        try? FileManager.default.removeItem(at: destino)
        try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

        let achadas: [(nome: String, dados: Data)]
        do {
            switch origem {
            case .smb(let referencia, let caminho):
                achadas = try await doSMB(referencia, caminho)
            case .webdav(let id, let caminho):
                achadas = try await doWebDAV(id, caminho)
            case .midia(let id, let item):
                guard let conta = ContasDeRede.shared.conta(id) else { return [] }
                achadas = try await ServidorDeMidia(conta: conta, token: ContasDeRede.shared.segredo(conta))
                    .legendasExternas(item)
            // No aparelho o próprio VLC acha; por endereço solto não há pasta.
            case .file, .remote:
                return []
            }
        } catch {
            LabLog.problem("legendas ao lado indisponíveis: \(error.localizedDescription)")
            return []
        }

        return achadas.compactMap { legenda in
            let arquivo = destino.appendingPathComponent(legenda.nome)
            return (try? legenda.dados.write(to: arquivo)) != nil ? arquivo : nil
        }
    }

    private static func doSMB(_ referencia: SMBShareRef, _ caminho: String) async throws -> [(nome: String, dados: Data)] {
        guard let servidor = SMBServerStore.shared.servers.first(where: { $0.id == referencia.serverID }) else {
            return []
        }
        let conexao = SMBConnection(server: servidor, password: SMBServerStore.shared.password(for: servidor))
        let video = (caminho as NSString).lastPathComponent
        let pasta = (caminho as NSString).deletingLastPathComponent
        var achadas: [(nome: String, dados: Data)] = []
        for entrada in try await conexao.list(share: referencia.share, path: pasta)
        where !entrada.isDirectory && entrada.size <= teto && combina(video: video, arquivo: entrada.name) {
            let (leitor, tamanho) = try await conexao.fileReader(share: referencia.share, path: entrada.path)
            achadas.append((entrada.name, try await leitor.read(offset: 0, length: UInt32(tamanho))))
        }
        await conexao.disconnect()
        return achadas
    }

    private static func doWebDAV(_ id: UUID, _ caminho: String) async throws -> [(nome: String, dados: Data)] {
        guard let conta = ContasDeRede.shared.conta(id) else { return [] }
        let webDAV = WebDAV(conta: conta, senha: ContasDeRede.shared.segredo(conta))
        let video = (caminho as NSString).lastPathComponent
        var pasta = (caminho as NSString).deletingLastPathComponent
        if pasta.isEmpty { pasta = "/" }
        var achadas: [(nome: String, dados: Data)] = []
        for entrada in try await webDAV.listar(pasta)
        where !entrada.ehPasta && (entrada.tamanho ?? 0) <= Int64(teto) && combina(video: video, arquivo: entrada.nome) {
            achadas.append((entrada.nome, try await webDAV.baixar(entrada.caminho)))
        }
        return achadas
    }
}

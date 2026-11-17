import Foundation
import SMBClient

/// Um arquivo do servidor SMB, por uma conexão própria — a do VLC é dele.
final class LeitorSMB: LeitorDeTrechos {
    private let conexao: SMBConnection
    private let share: String
    private let caminho: String
    private var aberto: (leitor: FileReader, tamanho: UInt64)?

    init(servidor: SMBServer, senha: String?, share: String, caminho: String) {
        conexao = SMBConnection(server: servidor, password: senha)
        self.share = share
        self.caminho = caminho
    }

    private func arquivo() async throws -> (leitor: FileReader, tamanho: UInt64) {
        if let aberto { return aberto }
        let novo = try await conexao.fileReader(share: share, path: caminho)
        aberto = novo
        return novo
    }

    func tamanho() async throws -> Int64 { Int64(try await arquivo().tamanho) }

    func ler(_ posicao: Int64, _ quantos: Int) async throws -> [UInt8] {
        let (leitor, tamanho) = try await arquivo()
        guard posicao < Int64(tamanho) else { return [] }
        let n = UInt32(min(Int64(quantos), Int64(tamanho) - posicao))
        return [UInt8](try await leitor.read(offset: UInt64(posicao), length: n))
    }

    func fechar() async {
        aberto = nil
        await conexao.disconnect()
    }
}

/// Um arquivo por HTTP com `Range` — a ponte local do WebDAV e do
/// Jellyfin/Emby (que já põe a senha), ou um endereço direto.
final class LeitorHTTP: LeitorDeTrechos {
    private let url: URL
    private var total: Int64?
    private static let sessao = URLSession(configuration: .ephemeral)

    init(url: URL) { self.url = url }

    private func pedir(_ de: Int64, _ ate: Int64) async throws -> ([UInt8], Int64?) {
        var pedido = URLRequest(url: url, timeoutInterval: 20)
        pedido.setValue("bytes=\(de)-\(ate)", forHTTPHeaderField: "Range")
        let (dados, resposta) = try await Self.sessao.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse, http.statusCode == 206 else {
            throw URLError(.badServerResponse)
        }
        let total = (http.value(forHTTPHeaderField: "Content-Range") as NSString?)
            .flatMap { Int64($0.components(separatedBy: "/").last ?? "") }
        return ([UInt8](dados), total)
    }

    func tamanho() async throws -> Int64 {
        if let total { return total }
        guard let medido = try await pedir(0, 0).1 else { throw URLError(.badServerResponse) }
        total = medido
        return medido
    }

    func ler(_ posicao: Int64, _ quantos: Int) async throws -> [UInt8] {
        let tamanho = try await tamanho()
        guard posicao < tamanho else { return [] }
        return try await pedir(posicao, min(tamanho - 1, posicao + Int64(quantos) - 1)).0
    }

    func fechar() async {}
}

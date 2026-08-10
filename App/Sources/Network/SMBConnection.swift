import Foundation
import SMBClient

/// Sessão SMB viva com um servidor.
///
/// `actor` de propósito: o SMBClient guarda estado de sessão e de árvore
/// conectada. Duas telas navegando ao mesmo tempo na mesma conexão
/// embaralhariam qual share está montado — o actor serializa isso.
actor SMBConnection {

    struct Entry: Identifiable, Hashable {
        var id: String { path }
        var name: String
        var path: String
        var isDirectory: Bool
        var size: UInt64
        var modifiedAt: Date
    }

    private let server: SMBServer
    private let password: String?
    private var client: SMBClient?
    private var mountedShare: String?

    init(server: SMBServer, password: String?) {
        self.server = server
        self.password = password
    }

    private func connectedClient() async throws -> SMBClient {
        if let client { return client }

        let novo = server.port == 445
            ? SMBClient(host: server.host)
            : SMBClient(host: server.host, port: server.port)

        // Convidado entra com usuário/senha nulos, não com string vazia — o
        // servidor trata os dois casos de forma diferente.
        if server.isGuest {
            try await novo.login(username: nil, password: nil)
        } else {
            try await novo.login(username: server.username, password: password)
        }

        client = novo
        return novo
    }

    func listShares() async throws -> [String] {
        let client = try await connectedClient()
        return try await client.listShares()
            // IPC$ e afins não guardam arquivo; mostrá-los só confunde.
            .filter { !$0.type.contains(.ipc) && !$0.name.hasSuffix("$") }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func list(share: String, path: String) async throws -> [Entry] {
        let client = try await connectedClient()

        if mountedShare != share {
            if mountedShare != nil { try? await client.disconnectShare() }
            try await client.connectShare(share)
            mountedShare = share
        }

        let arquivos = try await client.listDirectory(path: path)

        return arquivos
            .filter { $0.name != "." && $0.name != ".." && !$0.isHidden }
            .map { arquivo in
                Entry(
                    name: arquivo.name,
                    path: path.isEmpty ? arquivo.name : "\(path)/\(arquivo.name)",
                    isDirectory: arquivo.isDirectory,
                    size: arquivo.size,
                    modifiedAt: arquivo.lastWriteTime
                )
            }
            .sorted { esquerda, direita in
                // Pastas primeiro, depois ordem natural ("Ep 2" antes de "Ep 10").
                if esquerda.isDirectory != direita.isDirectory { return esquerda.isDirectory }
                return esquerda.name.localizedStandardCompare(direita.name) == .orderedAscending
            }
    }

    func disconnect() async {
        guard let client else { return }
        if mountedShare != nil { try? await client.disconnectShare() }
        try? await client.logoff()
        self.client = nil
        mountedShare = nil
    }
}

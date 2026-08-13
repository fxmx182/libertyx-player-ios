import Foundation
import Security

/// Um servidor Jellyfin salvo.
///
/// Mesma divisão do SMB: o que é endereço vai para o UserDefaults, o que é
/// segredo vai para o Keychain. Aqui o segredo é o **token de acesso**, não a
/// senha — o Jellyfin devolve um na autenticação, e depois dele a senha não
/// precisa mais ser guardada em lugar nenhum.
struct JellyfinServer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Base da API, com esquema e porta: `http://192.168.0.10:8096`.
    var baseURL: URL
    var username: String
    /// Identificador do usuário dentro do servidor, devolvido no login.
    var userID: String

    var displayHost: String {
        (baseURL.host ?? baseURL.absoluteString) + (baseURL.port.map { ":\($0)" } ?? "")
    }
}

@MainActor
final class JellyfinStore: ObservableObject {

    static let shared = JellyfinStore()

    @Published private(set) var servers: [JellyfinServer] = []

    private let defaultsKey = "labplayer.jellyfinServers"

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([JellyfinServer].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func save(_ server: JellyfinServer, token: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let token, !token.isEmpty {
            JellyfinKeychain.set(token, for: server.id)
        }
        persist()
    }

    func remove(_ server: JellyfinServer) {
        servers.removeAll { $0.id == server.id }
        JellyfinKeychain.delete(for: server.id)
        persist()
    }

    func token(for server: JellyfinServer) -> String? {
        JellyfinKeychain.get(for: server.id)
    }
}

/// Tokens do Jellyfin no Keychain.
enum JellyfinKeychain {

    private static let service = "com.mauricio.labplayer.jellyfin"

    private static func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func set(_ token: String, for id: UUID) {
        guard let data = token.data(using: .utf8) else { return }
        var attributes = query(for: id)
        SecItemDelete(attributes as CFDictionary)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(for id: UUID) -> String? {
        var attributes = query(for: id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
    }
}

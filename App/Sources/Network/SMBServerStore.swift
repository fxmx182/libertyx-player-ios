import Foundation
import Security

/// Um servidor SMB salvo.
///
/// A senha **não** mora aqui. Este struct vai para o UserDefaults, que é texto
/// claro no backup do aparelho; a senha vai para o Keychain, referenciada pelo
/// `id`.
struct SMBServer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 445
    var username: String
    var isGuest: Bool = false

    var displayHost: String { port == 445 ? host : "\(host):\(port)" }
}

@MainActor
final class SMBServerStore: ObservableObject {

    @Published private(set) var servers: [SMBServer] = []

    private let defaultsKey = "labplayer.smbServers"

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SMBServer].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func save(_ server: SMBServer, password: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let password, !password.isEmpty {
            SMBKeychain.set(password, for: server.id)
        }
        persist()
    }

    func remove(_ server: SMBServer) {
        servers.removeAll { $0.id == server.id }
        SMBKeychain.delete(for: server.id)
        persist()
    }

    func password(for server: SMBServer) -> String? {
        server.isGuest ? nil : SMBKeychain.get(for: server.id)
    }
}

/// Senhas de SMB no Keychain.
///
/// `kSecAttrAccessibleAfterFirstUnlock` e não `WhenUnlocked`: o app precisa
/// poder reconectar ao servidor com a tela bloqueada — cenário normal quando o
/// áudio continua tocando em segundo plano.
enum SMBKeychain {

    private static let service = "com.mauricio.labplayer.smb"

    private static func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func set(_ password: String, for id: UUID) {
        guard let data = password.data(using: .utf8) else { return }
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

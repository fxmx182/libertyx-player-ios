import Foundation

/// Uma conta de servidor que fala HTTP: WebDAV (o Nextcloud entre eles),
/// Jellyfin ou Emby.
///
/// O SMB continua com o próprio cadastro (`SMBServer`): ele tem porta,
/// convidado e procura na rede, que nada disto usa. Aqui o endereço é sempre
/// uma URL completa.
struct ContaDeRede: Codable, Identifiable, Hashable {

    enum Tipo: String, Codable, CaseIterable {
        case webdav, jellyfin, emby

        var nome: String {
            switch self {
            case .webdav:   return "WebDAV"
            case .jellyfin: return "Jellyfin"
            case .emby:     return "Emby"
            }
        }

        var simbolo: String {
            switch self {
            case .webdav:   return "externaldrive.connected.to.line.below"
            case .jellyfin: return "play.tv"
            case .emby:     return "play.rectangle.on.rectangle"
            }
        }

        /// Jellyfin e Emby são o mesmo servidor por dentro — o Jellyfin nasceu
        /// de uma cópia do Emby — e falam a mesma API.
        var ehServidorDeMidia: Bool { self != .webdav }
    }

    var id: UUID = UUID()
    var tipo: Tipo
    var nome: String
    /// Endereço como o usuário digitou, já com `http(s)://`.
    var endereco: String
    var usuario: String
    /// Jellyfin/Emby: o id do usuário no servidor, que entra no caminho de
    /// quase toda chamada. Vem do login.
    var idNoServidor: String?

    var url: URL? { URL(string: endereco) }

    /// Sem o esquema: é o que importa para reconhecer o servidor na lista.
    var enderecoCurto: String {
        endereco.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

@MainActor
final class ContasDeRede: ObservableObject {

    /// Instância única, pelo mesmo motivo do `SMBServerStore`: o motor precisa
    /// de endereço e senha na hora de abrir o arquivo, fora da hierarquia de
    /// views.
    static let shared = ContasDeRede()

    @Published private(set) var contas: [ContaDeRede] = []

    private let chave = "libertyx.contasDeRede"

    init() {
        if let dados = UserDefaults.standard.data(forKey: chave),
           let lidas = try? JSONDecoder().decode([ContaDeRede].self, from: dados) {
            contas = lidas
        }
    }

    func conta(_ id: UUID) -> ContaDeRede? {
        contas.first { $0.id == id }
    }

    /// - Parameter segredo: a senha (WebDAV) ou o token de acesso
    ///   (Jellyfin/Emby). `nil` mantém o que já estava guardado.
    func salvar(_ conta: ContaDeRede, segredo: String?) {
        if let indice = contas.firstIndex(where: { $0.id == conta.id }) {
            contas[indice] = conta
        } else {
            contas.append(conta)
        }
        if let segredo, !segredo.isEmpty {
            // As chaves do Keychain são os UUIDs, únicos entre SMB e estas
            // contas — não há como uma sobrescrever a outra.
            SMBKeychain.set(segredo, for: conta.id)
        }
        persistir()
    }

    func remover(_ conta: ContaDeRede) {
        contas.removeAll { $0.id == conta.id }
        SMBKeychain.delete(for: conta.id)
        persistir()
    }

    func segredo(_ conta: ContaDeRede) -> String? {
        SMBKeychain.get(for: conta.id)
    }

    private func persistir() {
        guard let dados = try? JSONEncoder().encode(contas) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
    }
}

/// Erro de servidor HTTP com uma frase que diga o que fazer.
struct ErroDeServidor: LocalizedError {
    let mensagem: String
    var errorDescription: String? { mensagem }

    static func http(_ codigo: Int) -> ErroDeServidor {
        switch codigo {
        case 401, 403:
            return ErroDeServidor(mensagem: String(localized: "Usuário ou senha recusados pelo servidor."))
        case 404, 405:
            return ErroDeServidor(mensagem: String(localized: "O endereço não aponta para uma pasta deste servidor."))
        default:
            return ErroDeServidor(mensagem: String(localized: "O servidor respondeu com o erro \(codigo)."))
        }
    }
}

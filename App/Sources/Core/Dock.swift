import Foundation

/// O que aparece na dock além de Início e Ajustes, que estão sempre lá.
///
/// Por padrão, só os dois: o Início já leva às pastas e aos servidores, e
/// cada um escolhe o que quer a um toque — o Jellyfin de casa, o Nextcloud,
/// a busca. Fica guardado no aparelho.
@MainActor
final class Dock: ObservableObject {

    static let shared = Dock()

    enum Item: Codable, Hashable {
        case arquivos
        case procurar
        /// Uma conta WebDAV, Jellyfin ou Emby, aberta direto no começo dela.
        case conta(UUID)
    }

    @Published private(set) var itens: [Item] = []

    private let chave = "libertyx.dock.v1"

    init() {
        if let dados = UserDefaults.standard.data(forKey: chave),
           let lidos = try? JSONDecoder().decode([Item].self, from: dados) {
            itens = lidos
        }
    }

    func contem(_ item: Item) -> Bool { itens.contains(item) }

    /// Põe no fim da dock, ou tira.
    func alternar(_ item: Item) {
        if let posicao = itens.firstIndex(of: item) {
            itens.remove(at: posicao)
        } else {
            itens.append(item)
        }
        guard let dados = try? JSONEncoder().encode(itens) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
    }

    /// Sem as contas que já foram apagadas.
    func validos(_ contas: [ContaDeRede]) -> [Item] {
        itens.filter { item in
            guard case .conta(let id) = item else { return true }
            return contas.contains { $0.id == id }
        }
    }
}

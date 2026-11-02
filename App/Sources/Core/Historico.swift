import Foundation

/// Os vídeos abertos por último, de qualquer origem.
///
/// A faixa "Continuar assistindo" vinha das marcas de retomada casadas com a
/// biblioteca local — e vídeo de servidor nunca está na biblioteca, então
/// sumia dali. Aqui fica o próprio item, com a origem inteira: tocar de novo
/// pelo histórico funciona igual para pasta, SMB, WebDAV e Jellyfin. A senha
/// não vem junto: a origem só aponta para a conta salva.
@MainActor
final class Historico: ObservableObject {

    static let shared = Historico()

    @Published private(set) var itens: [MediaItem] = []

    private let chave = "libertyx.historico"
    private let limite = 40

    init() {
        if let dados = UserDefaults.standard.data(forKey: chave),
           let lidos = try? JSONDecoder().decode([MediaItem].self, from: dados) {
            itens = lidos
        }
    }

    /// Vai para o começo; o mesmo vídeo não aparece duas vezes.
    func registrar(_ item: MediaItem) {
        let chaveDoItem = item.origin.resumeKey
        itens.removeAll { $0.origin.resumeKey == chaveDoItem }
        itens.insert(item, at: 0)
        if itens.count > limite { itens.removeLast(itens.count - limite) }
        persistir()
    }

    /// Visto até o fim: sai da lista, e o próximo episódio, se houver, entra
    /// no lugar dele — como o "Continuar" e o "A seguir" do Jellyfin.
    func terminou(chave: String, proximo: MediaItem?) {
        let lugar = itens.firstIndex { $0.origin.resumeKey == chave } ?? 0
        itens.removeAll { $0.origin.resumeKey == chave }
        if let proximo {
            itens.removeAll { $0.origin.resumeKey == proximo.origin.resumeKey }
            itens.insert(proximo, at: min(lugar, itens.count))
        }
        persistir()
    }

    func remover(_ item: MediaItem) {
        let chaveDoItem = item.origin.resumeKey
        itens.removeAll { $0.origin.resumeKey == chaveDoItem }
        persistir()
    }

    private func persistir() {
        guard let dados = try? JSONEncoder().encode(itens) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
    }
}

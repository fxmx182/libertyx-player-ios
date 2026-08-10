import Foundation

/// Onde cada vídeo parou.
///
/// A chave é a `resumeKey` da origem, não o caminho: um pendrive remontado
/// ganha caminho novo a cada vez, e o servidor SMB pode ser alcançado por
/// endereços diferentes. Guardar o caminho faria a retomada se perder
/// justamente nos dois casos que mais importam aqui.
@MainActor
final class ResumeStore {

    static let shared = ResumeStore()

    private let defaultsKey = "labplayer.resume"
    private let limite = 300

    private struct Marca: Codable {
        var position: Double
        var duration: Double
        var updatedAt: Date
    }

    private var marcas: [String: Marca] = [:]

    private init() { load() }

    private func load() {
        guard let dados = UserDefaults.standard.data(forKey: defaultsKey),
              let lidas = try? JSONDecoder().decode([String: Marca].self, from: dados) else { return }
        marcas = lidas
    }

    private func persist() {
        // Poda os mais antigos: sem teto, a lista cresce para sempre.
        if marcas.count > limite {
            let ordenadas = marcas.sorted { $0.value.updatedAt > $1.value.updatedAt }
            marcas = Dictionary(uniqueKeysWithValues: ordenadas.prefix(limite).map { ($0.key, $0.value) })
        }
        guard let dados = try? JSONEncoder().encode(marcas) else { return }
        UserDefaults.standard.set(dados, forKey: defaultsKey)
    }

    /// Posição para retomar, ou `nil` quando não vale a pena.
    ///
    /// Os dois limites existem por experiência de uso: retomar aos 5 segundos
    /// não economiza nada, e retomar a 30 segundos do fim joga o usuário
    /// direto nos créditos.
    func position(for key: String) -> Double? {
        guard let marca = marcas[key] else { return nil }
        guard marca.position > 30 else { return nil }
        if marca.duration > 0, marca.position > marca.duration - 30 { return nil }
        return marca.position
    }

    func save(position: Double, duration: Double, for key: String) {
        guard position.isFinite, position > 0 else { return }
        marcas[key] = Marca(position: position, duration: duration, updatedAt: Date())
        persist()
    }

    /// Chamado ao terminar o vídeo — quem assistiu até o fim não quer voltar
    /// para os créditos na próxima vez.
    func clear(key: String) {
        marcas.removeValue(forKey: key)
        persist()
    }
}

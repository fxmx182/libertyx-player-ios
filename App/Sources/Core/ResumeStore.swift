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
        if Self.terminou(posicao: marca.position, duracao: marca.duration) { return nil }
        return marca.position
    }

    /// Se quem parou aqui já viu o vídeo — a mesma regra do Jellyfin.
    ///
    /// Lá, passar de 90% da duração (o `MaxResumePct` do servidor) ou chegar
    /// a um segundo do fim marca como visto e zera a posição: os créditos não
    /// contam. Usar a mesma conta aqui faz o app e o servidor concordarem
    /// sobre o que sai do "Continuar".
    nonisolated static func terminou(posicao: Double, duracao: Double) -> Bool {
        duracao > 0 && (posicao >= duracao * 0.9 || posicao >= duracao - 1)
    }

    func save(position: Double, duration: Double, for key: String) {
        guard position.isFinite, position > 0 else { return }
        // Nos créditos já conta como visto: a marca sai, em vez de mudar.
        if Self.terminou(posicao: position, duracao: duration) {
            if marcas.removeValue(forKey: key) != nil { persist() }
            return
        }
        marcas[key] = Marca(position: position, duration: duration, updatedAt: Date())
        persist()
    }

    /// Onde o Jellyfin ou o Emby diz que um vídeo parou, para `mesclar`.
    struct DoServidor {
        let key: String
        let position: Double?
        let duration: Double
        let at: Date
        let watched: Bool
    }

    /// O que o servidor diz dos vídeos vistos em outro aparelho.
    ///
    /// Vale a marca mais recente: a daqui só dá lugar à de lá quando a de lá
    /// é mais nova. Visto até o fim, ou recomeçado lá, apaga a daqui. A lista
    /// inteira grava uma vez só: uma biblioteca grande gravaria centenas.
    func mesclar(_ entradas: [DoServidor]) {
        var mudou = false
        for e in entradas {
            let local = marcas[e.key]
            if let local, local.updatedAt >= e.at { continue }
            guard !e.watched, let posicao = e.position, posicao > 0 else {
                if marcas.removeValue(forKey: e.key) != nil { mudou = true }
                continue
            }
            if local?.position == posicao { continue }
            marcas[e.key] = Marca(position: posicao, duration: e.duration, updatedAt: e.at)
            mudou = true
        }
        if mudou { persist() }
    }

    /// As chaves com posição que vale retomar, da mais recente para a mais antiga.
    ///
    /// É a faixa de "continuar assistindo": o que se estava vendo por último
    /// vem primeiro, e o que já terminou ou mal começou fica de fora — pelo
    /// mesmo critério da pergunta de retomar.
    func recent() -> [String] {
        marcas.filter { position(for: $0.key) != nil }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map(\.key)
    }

    /// Quanto já foi visto, de 0 a 1. `nil` quando não há o que retomar.
    func progress(for key: String) -> Double? {
        guard let posicao = position(for: key),
              let marca = marcas[key], marca.duration > 0 else { return nil }
        return min(1, posicao / marca.duration)
    }

    /// Quanto falta, em segundos — o que quem parou no meio quer saber.
    func remaining(for key: String) -> Double? {
        guard let posicao = position(for: key),
              let marca = marcas[key], marca.duration > 0 else { return nil }
        return max(0, marca.duration - posicao)
    }

    /// Chamado ao terminar o vídeo — quem assistiu até o fim não quer voltar
    /// para os créditos na próxima vez.
    func clear(key: String) {
        marcas.removeValue(forKey: key)
        persist()
    }
}

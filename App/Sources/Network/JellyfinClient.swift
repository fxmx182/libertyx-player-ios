import Foundation

/// Cliente da API do Jellyfin.
///
/// A diferença em relação ao SMB não é de protocolo, é de natureza: no SMB nós
/// lemos um disco e adivinhamos o que cada arquivo é; aqui o servidor já sabe.
/// Ele devolve título, ano, capa, duração e onde você parou — tudo pronto.
/// Some a extração de quadro, some o nome de arquivo como título, some a
/// navegação por pastas.
///
/// E há o ganho que motivou tudo isto: o Jellyfin pode reembalar o filme sob
/// demanda. Um MKV com H.264 vira MP4 sem recodificar nada — troca de casca,
/// não de conteúdo — e aí quem toca é o AVPlayer, com busca exata e janela
/// flutuante.
struct JellyfinClient {

    let server: JellyfinServer
    let token: String

    // MARK: - Modelos

    struct Item: Identifiable, Hashable {
        let id: String
        let name: String
        let type: String
        let isFolder: Bool
        /// Em "ticks" de 100 ns, como o .NET conta.
        let runTimeTicks: Int64?
        let positionTicks: Int64?
        let played: Bool
        let year: Int?
        let overview: String?
        let imageTag: String?
        /// Só as bibliotecas têm: "movies", "tvshows", "livetv"…
        let collectionType: String?
        /// O que está passando agora, quando é canal de TV.
        let nowPlaying: String?

        var duration: Double? {
            guard let runTimeTicks, runTimeTicks > 0 else { return nil }
            return Double(runTimeTicks) / 10_000_000
        }

        var resumePosition: Double? {
            guard let positionTicks, positionTicks > 0 else { return nil }
            return Double(positionTicks) / 10_000_000
        }

        /// Um episódio ou filme — algo que se abre no player.
        var isPlayable: Bool {
            !isFolder && ["Movie", "Episode", "Video", "MusicVideo", "TvChannel"].contains(type)
        }
    }

    enum Failure: LocalizedError {
        /// Com o corpo junto: o Jellyfin costuma dizer o que não gostou, e
        /// jogar isso fora deixa "recusado" sem nenhuma pista de por quê.
        case badResponse(Int, String)
        case malformed
        case badURL

        var errorDescription: String? {
            switch self {
            case .badResponse(let code, _) where code == 401:
                return "Usuário ou senha recusados pelo servidor (401)."
            case .badResponse(let code, let detalhe) where detalhe.isEmpty:
                return "O servidor respondeu \(code)."
            case .badResponse(let code, let detalhe):
                return "O servidor respondeu \(code): \(detalhe.prefix(200))"
            case .malformed:
                return "Resposta do servidor em formato inesperado."
            case .badURL:
                return "Endereço do servidor inválido."
            }
        }
    }

    /// Põe os dois cabeçalhos de autenticação no pedido.
    ///
    /// O Jellyfin moderno lê `Authorization`; versões mais antigas só olham
    /// `X-Emby-Authorization`. Mandar os dois custa nada e evita um "recusado"
    /// que não teria explicação nenhuma.
    private static func assinar(_ pedido: inout URLRequest, token: String? = nil) {
        let cabecalho = authHeader(token: token)
        pedido.setValue(cabecalho, forHTTPHeaderField: "Authorization")
        pedido.setValue(cabecalho, forHTTPHeaderField: "X-Emby-Authorization")
        // Sem User-Agent, proxy na frente do servidor às vezes responde 403
        // achando que é robô — e o erro chega aqui como recusa de login.
        pedido.setValue("LabPlayer/\(AppBuild.version) (iOS)", forHTTPHeaderField: "User-Agent")
    }

    // MARK: - Autenticação

    /// O cabeçalho que o Jellyfin exige para se identificar.
    ///
    /// Ele aparece na lista de dispositivos do servidor, então vale ser
    /// reconhecível: é assim que você sabe qual sessão é o seu iPhone.
    private static func authHeader(token: String? = nil) -> String {
        var partes = [
            "MediaBrowser Client=\"LabPlayer\"",
            "Device=\"iPhone\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(AppBuild.version)\"",
        ]
        if let token { partes.append("Token=\"\(token)\"") }
        return partes.joined(separator: ", ")
    }

    /// Estável entre execuções: o servidor usa isto para casar as sessões.
    private static var deviceID: String {
        let chave = "labplayer.jellyfinDeviceID"
        if let existente = UserDefaults.standard.string(forKey: chave) { return existente }
        let novo = UUID().uuidString
        UserDefaults.standard.set(novo, forKey: chave)
        return novo
    }

    /// Faz o login e devolve o que precisa ser guardado.
    static func authenticate(baseURL: URL, username: String,
                             password: String) async throws -> (userID: String, token: String) {
        var pedido = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        assinar(&pedido)
        pedido.httpBody = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password,
        ])

        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.badResponse(http.statusCode, String(data: dados, encoding: .utf8) ?? "")
        }

        guard let raiz = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let token = raiz["AccessToken"] as? String,
              let usuario = raiz["User"] as? [String: Any],
              let userID = usuario["Id"] as? String else {
            throw Failure.malformed
        }
        return (userID, token)
    }

    /// Dados públicos do servidor — não exigem login.
    static func publicInfo(baseURL: URL) async throws -> (id: String, name: String) {
        let (dados, resposta) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("System/Info/Public"))
        guard let http = resposta as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw Failure.malformed }
        guard let raiz = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let id = raiz["Id"] as? String else { throw Failure.malformed }
        return (id, raiz["ServerName"] as? String ?? baseURL.host ?? "Jellyfin")
    }
}

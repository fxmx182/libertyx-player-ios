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
        case badResponse(Int)
        case malformed
        case badURL

        var errorDescription: String? {
            switch self {
            case .badResponse(let code) where code == 401:
                return "Usuário ou senha recusados pelo servidor."
            case .badResponse(let code):
                return "O servidor respondeu \(code)."
            case .malformed:
                return "Resposta do servidor em formato inesperado."
            case .badURL:
                return "Endereço do servidor inválido."
            }
        }
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
        pedido.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        pedido.httpBody = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password,
        ])

        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else { throw Failure.badResponse(http.statusCode) }

        guard let raiz = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let token = raiz["AccessToken"] as? String,
              let usuario = raiz["User"] as? [String: Any],
              let userID = usuario["Id"] as? String else {
            throw Failure.malformed
        }
        return (userID, token)
    }

    // MARK: - Navegação

    /// As bibliotecas do usuário: Filmes, Séries, e o que mais existir.
    func views() async throws -> [Item] {
        try await items(path: "Users/\(server.userID)/Views", query: [])
    }

    /// O conteúdo de uma biblioteca ou pasta.
    func children(of parentID: String) async throws -> [Item] {
        try await items(path: "Users/\(server.userID)/Items", query: [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "Overview,ProductionYear"),
            URLQueryItem(name: "Limit", value: "500"),
        ])
    }

    /// O que ficou pela metade, para a primeira tela.
    func resumable() async throws -> [Item] {
        try await items(path: "Users/\(server.userID)/Items/Resume", query: [
            URLQueryItem(name: "Limit", value: "20"),
            URLQueryItem(name: "MediaTypes", value: "Video"),
        ])
    }

    private func items(path: String, query: [URLQueryItem]) async throws -> [Item] {
        guard var componentes = URLComponents(url: server.baseURL.appendingPathComponent(path),
                                              resolvingAgainstBaseURL: false) else {
            throw Failure.badURL
        }
        componentes.queryItems = query.isEmpty ? nil : query
        guard let url = componentes.url else { throw Failure.badURL }

        var pedido = URLRequest(url: url)
        pedido.setValue(Self.authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else { throw Failure.badResponse(http.statusCode) }

        guard let raiz = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let lista = raiz["Items"] as? [[String: Any]] else {
            throw Failure.malformed
        }
        return lista.compactMap(Self.parse)
    }

    private static func parse(_ bruto: [String: Any]) -> Item? {
        guard let id = bruto["Id"] as? String,
              let nome = bruto["Name"] as? String else { return nil }

        let dadosDoUsuario = bruto["UserData"] as? [String: Any]
        let tags = bruto["ImageTags"] as? [String: Any]

        return Item(
            id: id,
            name: nome,
            type: bruto["Type"] as? String ?? "",
            isFolder: bruto["IsFolder"] as? Bool ?? false,
            runTimeTicks: (bruto["RunTimeTicks"] as? NSNumber)?.int64Value,
            positionTicks: (dadosDoUsuario?["PlaybackPositionTicks"] as? NSNumber)?.int64Value,
            played: dadosDoUsuario?["Played"] as? Bool ?? false,
            year: (bruto["ProductionYear"] as? NSNumber)?.intValue,
            overview: bruto["Overview"] as? String,
            imageTag: (tags?["Primary"] as? String) ?? (tags?["Thumb"] as? String)
        )
    }

    // MARK: - Imagens

    /// A capa, já no tamanho pedido — o servidor redimensiona.
    ///
    /// Vai com o token na URL porque quem baixa é o `AsyncImage`, que não tem
    /// como pôr cabeçalho.
    func imageURL(for item: Item, maxWidth: Int) -> URL? {
        guard item.imageTag != nil else { return nil }
        var componentes = URLComponents(
            url: server.baseURL.appendingPathComponent("Items/\(item.id)/Images/Primary"),
            resolvingAgainstBaseURL: false)
        componentes?.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "85"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return componentes?.url
    }

    // MARK: - Reprodução

    /// A URL para tocar.
    ///
    /// Pede um HLS e declara o que este aparelho aceita. Com isso o servidor
    /// decide sozinho: se o vídeo já está num codec que a Apple lê, ele só
    /// troca a embalagem — barato, sem perda. Se não estiver, converte o que
    /// for preciso e só isso.
    ///
    /// É esta linha que faz um MKV virar algo que o AVPlayer toca com busca
    /// exata e janela flutuante.
    func streamURL(for item: Item) -> URL? {
        var componentes = URLComponents(
            url: server.baseURL.appendingPathComponent("Videos/\(item.id)/master.m3u8"),
            resolvingAgainstBaseURL: false)
        componentes?.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "MediaSourceId", value: item.id),
            // H.264 sempre aceito; HEVC também, e aí um filme 4K passa sem
            // recodificar. Quem escolhe é o servidor, não nós.
            URLQueryItem(name: "VideoCodec", value: "h264,hevc"),
            URLQueryItem(name: "AudioCodec", value: "aac,mp3"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "SegmentContainer", value: "ts"),
            // Sem isto o servidor pode escolher um perfil que o iPhone recusa.
            URLQueryItem(name: "h264-profile", value: "high,main,baseline"),
            URLQueryItem(name: "h264-level", value: "51"),
            URLQueryItem(name: "MaxAudioChannels", value: "2"),
        ]
        return componentes?.url
    }

    // MARK: - Estado de reprodução

    /// Conta ao servidor onde você parou, para o "continuar assistindo" valer
    /// em todos os aparelhos — que é metade da graça de ter um Jellyfin.
    func reportProgress(itemID: String, position: Double, paused: Bool) async {
        await post("Sessions/Playing/Progress", corpo: [
            "ItemId": itemID,
            "PositionTicks": Int64(position * 10_000_000),
            "IsPaused": paused,
        ])
    }

    func reportStart(itemID: String) async {
        await post("Sessions/Playing", corpo: ["ItemId": itemID])
    }

    func reportStop(itemID: String, position: Double) async {
        await post("Sessions/Playing/Stopped", corpo: [
            "ItemId": itemID,
            "PositionTicks": Int64(position * 10_000_000),
        ])
    }

    private func post(_ caminho: String, corpo: [String: Any]) async {
        var pedido = URLRequest(url: server.baseURL.appendingPathComponent(caminho))
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pedido.setValue(Self.authHeader(token: token), forHTTPHeaderField: "Authorization")
        pedido.httpBody = try? JSONSerialization.data(withJSONObject: corpo)
        _ = try? await URLSession.shared.data(for: pedido)
    }
}

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

    /// Canais de TV ao vivo.
    ///
    /// Precisa de um caminho próprio: a TV ao vivo não é uma pasta com
    /// arquivos dentro, é uma lista que o servidor monta na hora a partir do
    /// sintonizador. Pedir os "filhos" dela como se fosse pasta devolve vazio
    /// — que foi exatamente o que aconteceu.
    func liveChannels() async throws -> [Item] {
        try await items(path: "LiveTv/Channels", query: [
            URLQueryItem(name: "UserId", value: server.userID),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "AddCurrentProgram", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Limit", value: "600"),
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
        Self.assinar(&pedido, token: token)

        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.badResponse(http.statusCode, String(data: dados, encoding: .utf8) ?? "")
        }

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
            imageTag: (tags?["Primary"] as? String) ?? (tags?["Thumb"] as? String),
            collectionType: bruto["CollectionType"] as? String,
            nowPlaying: (bruto["CurrentProgram"] as? [String: Any])?["Name"] as? String
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

    /// A URL para tocar, perguntada ao servidor.
    ///
    /// Montar essa URL na mão não funciona — foi o que eu tinha feito, e por
    /// isso nada abria. O Jellyfin quer que o cliente **declare o que sabe
    /// tocar** e devolve a decisão pronta: se dá para entregar o arquivo como
    /// está, ou qual endereço usar depois de reembalar.
    ///
    /// O perfil abaixo é onde mora o ganho. Ele diz duas coisas ao servidor:
    ///
    /// - **Toque direto** só de MP4, M4V e MOV. MKV fica de fora de propósito:
    ///   o AVPlayer não abre, e receber o arquivo cru seria um beco sem saída.
    /// - **Reembalando**, aceitamos H.264 e HEVC dentro de fMP4, com áudio AAC,
    ///   AC-3 ou E-AC-3. Como o codec de origem quase sempre está nessa lista,
    ///   o servidor **copia** as faixas em vez de recodificar — troca de casca,
    ///   processador quase parado. É a diferença entre o seu homelab ventilando
    ///   e ele nem perceber que está servindo um filme.
    ///
    /// fMP4 e não MPEG-TS porque a Apple só aceita HEVC em HLS dentro de fMP4;
    /// com TS, todo filme em HEVC seria recodificado à toa.
    func playbackURL(for item: Item) async throws -> URL {
        let perfil: [String: Any] = [
            "DeviceProfile": [
                "MaxStreamingBitrate": 120_000_000,
                "MaxStaticBitrate": 120_000_000,
                "MusicStreamingTranscodingBitrate": 384_000,
                "DirectPlayProfiles": [
                    [
                        "Container": "mp4,m4v,mov",
                        "Type": "Video",
                        "VideoCodec": "h264,hevc",
                        "AudioCodec": "aac,mp3,ac3,eac3,alac,flac",
                    ],
                ],
                "TranscodingProfiles": [
                    [
                        "Container": "mp4",
                        "Type": "Video",
                        "VideoCodec": "h264,hevc",
                        "AudioCodec": "aac,ac3,eac3",
                        "Protocol": "hls",
                        "Context": "Streaming",
                        "MaxAudioChannels": "6",
                        "MinSegments": 2,
                        "BreakOnNonKeyFrames": false,
                    ],
                ],
                "ContainerProfiles": [],
                "CodecProfiles": [],
                "SubtitleProfiles": [
                    ["Format": "vtt", "Method": "Hls"],
                    ["Format": "vtt", "Method": "External"],
                ],
            ] as [String: Any],
        ]

        guard var componentes = URLComponents(
            url: server.baseURL.appendingPathComponent("Items/\(item.id)/PlaybackInfo"),
            resolvingAgainstBaseURL: false) else { throw Failure.badURL }
        componentes.queryItems = [URLQueryItem(name: "UserId", value: server.userID)]
        guard let url = componentes.url else { throw Failure.badURL }

        var pedido = URLRequest(url: url)
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.assinar(&pedido, token: token)
        pedido.httpBody = try JSONSerialization.data(withJSONObject: perfil)

        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.badResponse(http.statusCode, String(data: dados, encoding: .utf8) ?? "")
        }

        guard let raiz = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let fontes = raiz["MediaSources"] as? [[String: Any]],
              let fonte = fontes.first else {
            throw Failure.malformed
        }

        // Reembalado ou convertido: o servidor já devolve o endereço pronto,
        // com a sessão dele embutida.
        if let caminho = fonte["TranscodingUrl"] as? String {
            let absoluto = caminho.hasPrefix("http")
                ? caminho
                : server.baseURL.absoluteString + caminho
            guard let url = URL(string: absoluto) else { throw Failure.badURL }
            return comChave(url)
        }

        // Toque direto: o arquivo como está no disco do servidor.
        let fonteID = (fonte["Id"] as? String) ?? item.id
        let extensao = (fonte["Container"] as? String)?.split(separator: ",").first.map(String.init) ?? "mp4"
        guard var direto = URLComponents(
            url: server.baseURL.appendingPathComponent("Videos/\(item.id)/stream.\(extensao)"),
            resolvingAgainstBaseURL: false) else { throw Failure.badURL }
        direto.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: fonteID),
            URLQueryItem(name: "api_key", value: token),
        ]
        guard let url = direto.url else { throw Failure.badURL }
        return url
    }

    /// O endereço devolvido pelo servidor nem sempre traz a chave — e sem ela
    /// o AVPlayer leva 401 no primeiro segmento, sem nada explicando.
    private func comChave(_ url: URL) -> URL {
        guard var componentes = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var itens = componentes.queryItems ?? []
        guard !itens.contains(where: { $0.name.lowercased() == "api_key" }) else { return url }
        itens.append(URLQueryItem(name: "api_key", value: token))
        componentes.queryItems = itens
        return componentes.url ?? url
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
        Self.assinar(&pedido, token: token)
        pedido.httpBody = try? JSONSerialization.data(withJSONObject: corpo)
        _ = try? await URLSession.shared.data(for: pedido)
    }
}

import Foundation
import UIKit

/// Cliente de Jellyfin e Emby.
///
/// Diferente da tentativa antiga, que abria a interface web do Jellyfin numa
/// WebView, aqui o app lê só o catálogo pela API e toca o **arquivo original**
/// pelo VLC. Isso muda tudo para um servidor sem aceleração de vídeo: o MKV com
/// HEVC e áudio AC-3 sai do disco como está, sem o servidor converter nada, e
/// a rolagem é a mesma do arquivo local.
struct ServidorDeMidia {

    let conta: ContaDeRede
    let token: String?

    // MARK: - Itens

    struct Item: Decodable, Identifiable, Hashable {
        let id: String
        let nome: String
        let tipo: String
        let ehPasta: Bool
        let tipoDeColecao: String?
        let duracaoTicks: Int64?
        let ano: Int?
        let numero: Int?
        let temporada: Int?
        let criado: String?
        /// Episódio: a série de que ele faz parte — na busca, é o que o situa.
        let serie: String?
        let serieID: String?
        let temporadaID: String?
        /// Onde a pessoa parou, em qualquer aparelho, e se já viu até o fim.
        let usuario: DoUsuario?

        struct DoUsuario: Decodable, Hashable {
            let posicaoTicks: Int64?
            let visto: Bool?
            /// Série ou temporada: quantos episódios faltam ver.
            let naoVistos: Int?
            /// Quando foi tocado pela última vez, em qualquer aparelho.
            let ultimaVez: String?

            enum CodingKeys: String, CodingKey {
                case posicaoTicks = "PlaybackPositionTicks", visto = "Played"
                case naoVistos = "UnplayedItemCount", ultimaVez = "LastPlayedDate"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id = "Id", nome = "Name", tipo = "Type", ehPasta = "IsFolder"
            case tipoDeColecao = "CollectionType", duracaoTicks = "RunTimeTicks"
            case ano = "ProductionYear", numero = "IndexNumber"
            case temporada = "ParentIndexNumber", criado = "DateCreated"
            case serie = "SeriesName", serieID = "SeriesId", temporadaID = "SeasonId"
            case usuario = "UserData"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            nome = (try? c.decode(String.self, forKey: .nome)) ?? ""
            tipo = (try? c.decode(String.self, forKey: .tipo)) ?? ""
            ehPasta = (try? c.decode(Bool.self, forKey: .ehPasta)) ?? false
            tipoDeColecao = try? c.decode(String.self, forKey: .tipoDeColecao)
            duracaoTicks = try? c.decode(Int64.self, forKey: .duracaoTicks)
            ano = try? c.decode(Int.self, forKey: .ano)
            numero = try? c.decode(Int.self, forKey: .numero)
            temporada = try? c.decode(Int.self, forKey: .temporada)
            criado = try? c.decode(String.self, forKey: .criado)
            serie = try? c.decode(String.self, forKey: .serie)
            serieID = try? c.decode(String.self, forKey: .serieID)
            temporadaID = try? c.decode(String.self, forKey: .temporadaID)
            usuario = try? c.decode(DoUsuario.self, forKey: .usuario)
        }

        var ehVideo: Bool {
            !ehPasta && ["Movie", "Episode", "Video", "MusicVideo"].contains(tipo)
        }

        /// Duração em segundos; o servidor conta em décimos de microssegundo.
        var duracao: Double? {
            guard let duracaoTicks, duracaoTicks > 0 else { return nil }
            return Double(duracaoTicks) / ServidorDeMidia.ticks
        }

        /// Onde a pessoa parou, em segundos.
        var posicao: Double? {
            guard let ticks = usuario?.posicaoTicks, ticks > 0 else { return nil }
            return Double(ticks) / ServidorDeMidia.ticks
        }

        var visto: Bool { usuario?.visto == true }

        var naoVistos: Int? { usuario?.naoVistos.flatMap { $0 > 0 ? $0 : nil } }

        /// De 0 a 1, só quando há o que retomar.
        var progresso: Double? {
            guard let posicao, let duracao, duracao > 0 else { return nil }
            return min(1, max(0, posicao / duracao))
        }

        /// Episódio com o número na frente, filme com o ano: é como se acha
        /// o que se procura numa lista longa.
        var titulo: String {
            if tipo == "Episode", let numero { return "\(numero). \(nome)" }
            if tipo == "Movie", let ano { return "\(nome) (\(ano))" }
            return nome
        }

        var dataDeCriacao: Date? { criado.flatMap(ServidorDeMidia.data) }
    }

    /// O servidor conta o tempo em décimos de microssegundo.
    static let ticks = 10_000_000.0

    static func data(_ texto: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let data = f.date(from: texto) { return data }
        f.formatOptions = [.withInternetDateTime]
        // O servidor manda sete casas de fração, que o formatador recusa;
        // sem a fração a data ainda serve para ordenar.
        let semFracao = texto.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return f.date(from: semFracao)
    }

    private struct Lista: Decodable {
        let Items: [Item]
    }

    /// Bibliotecas do usuário (Filmes, Séries, Vídeos caseiros…).
    func bibliotecas() async throws -> [Item] {
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Views")
        // Música, livros e fotos não têm o que fazer num player de vídeo.
        let fora: Set<String> = ["music", "books", "photos", "playlists", "livetv", "musicvideos"]
        return lista.Items.filter { !fora.contains($0.tipoDeColecao ?? "") }
    }

    /// O que há dentro de uma biblioteca, série ou temporada.
    ///
    /// Bibliotecas de filmes e de séries são guardadas em pastas, mas quem
    /// navega espera ver os filmes e as séries direto, não a estrutura de
    /// disco — então elas são lidas de forma recursiva, filtradas pelo tipo.
    func itens(de pai: Item) async throws -> [Item] {
        var consulta = [
            URLQueryItem(name: "ParentId", value: pai.id),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
        ]
        switch pai.tipoDeColecao {
        case "movies":
            consulta += [URLQueryItem(name: "Recursive", value: "true"),
                         URLQueryItem(name: "IncludeItemTypes", value: "Movie")]
        case "tvshows":
            consulta += [URLQueryItem(name: "Recursive", value: "true"),
                         URLQueryItem(name: "IncludeItemTypes", value: "Series")]
        default:
            break
        }
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Items", consulta: consulta)
        return await lembrandoOndeParou(lista.Items)
    }

    /// Filmes e episódios cujo nome tem `termo`, de todas as bibliotecas.
    func buscar(_ termo: String) async throws -> [Item] {
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Items", consulta: [
            URLQueryItem(name: "searchTerm", value: termo),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video,MusicVideo"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "Limit", value: "40"),
        ])
        return await lembrandoOndeParou(lista.Items.filter(\.ehVideo))
    }

    /// O que a pessoa começou e não terminou, do mais recente ao mais antigo.
    func continuar() async throws -> [Item] {
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Items/Resume", consulta: [
            URLQueryItem(name: "Limit", value: "24"),
            URLQueryItem(name: "MediaTypes", value: "Video"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(lista.Items.filter(\.ehVideo))
    }

    /// O próximo episódio de cada série que a pessoa está vendo.
    func aSeguir() async throws -> [Item] {
        let lista: Lista = try await pedir("/Shows/NextUp", consulta: [
            URLQueryItem(name: "UserId", value: usuarioID),
            URLQueryItem(name: "Limit", value: "24"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(lista.Items.filter(\.ehVideo))
    }

    /// O que chegou por último numa biblioteca. Numa de séries o servidor
    /// agrupa os episódios novos na série, como no app dele.
    func recentes(_ biblioteca: Item) async throws -> [Item] {
        // O `Latest` responde com a lista solta, sem o `Items` em volta.
        let itens: [Item] = try await pedir("/Users/\(usuarioID)/Items/Latest", consulta: [
            URLQueryItem(name: "ParentId", value: biblioteca.id),
            URLQueryItem(name: "Limit", value: "16"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(itens)
    }

    /// Os episódios da temporada, na ordem: é a fila do "próximo" no player.
    func temporada(_ episodio: Item) async throws -> [Item] {
        guard let serie = episodio.serieID else { return [episodio] }
        var consulta = [URLQueryItem(name: "UserId", value: usuarioID),
                        URLQueryItem(name: "Fields", value: "DateCreated")]
        if let temporada = episodio.temporadaID {
            consulta.append(URLQueryItem(name: "SeasonId", value: temporada))
        }
        let lista: Lista = try await pedir("/Shows/\(serie)/Episodes", consulta: consulta)
        let episodios = await lembrandoOndeParou(lista.Items.filter(\.ehVideo))
        return episodios.isEmpty ? [episodio] : episodios
    }

    /// O episódio que vem depois deste, pelo "A seguir" do servidor — que
    /// sabe das outras temporadas e do que já foi visto em outro aparelho.
    /// `nil` para filme ou quando a série acabou.
    func proximoEpisodio(_ itemID: String) async throws -> Item? {
        let atual: Item = try await pedir("/Users/\(usuarioID)/Items/\(itemID)")
        guard let serie = atual.serieID else { return nil }
        let lista: Lista = try await pedir("/Shows/NextUp", consulta: [
            URLQueryItem(name: "UserId", value: usuarioID),
            URLQueryItem(name: "SeriesId", value: serie),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(lista.Items).first { $0.ehVideo && $0.id != itemID }
    }

    /// O vídeo do servidor como o player e o histórico o conhecem — o mesmo
    /// título das pastas, para a retomada e o histórico baterem.
    func paraTocar(_ item: Item) -> MediaItem {
        MediaItem(title: item.titulo, origin: .midia(conta: conta.id, item: item.id),
                  modifiedAt: item.dataDeCriacao, duration: item.duracao)
    }

    /// As legendas "externas" do vídeo: os `.srt` que o servidor achou ao lado
    /// do arquivo, na pasta dele. As de dentro do arquivo o VLC já lê; estas
    /// ele não vê, porque recebe só o vídeo.
    ///
    /// Cada uma com o nome do arquivo: o título que o servidor dá à faixa — e
    /// "forced" quando ela é marcada como forçada, que é como a regra da
    /// legenda a reconhece.
    func legendasExternas(_ itemID: String) async throws -> [(nome: String, dados: Data)] {
        let resposta = try await pedirDados("/Users/\(usuarioID)/Items/\(itemID)",
                                            consulta: [URLQueryItem(name: "Fields", value: "MediaSources,MediaStreams")])
        guard let json = try JSONSerialization.jsonObject(with: resposta) as? [String: Any],
              let fonte = (json["MediaSources"] as? [[String: Any]])?.first,
              let fluxos = fonte["MediaStreams"] as? [[String: Any]] else { return [] }
        let fonteID = fonte["Id"] as? String ?? itemID

        var legendas: [(nome: String, dados: Data)] = []
        for fluxo in fluxos where fluxo["Type"] as? String == "Subtitle" && fluxo["IsExternal"] as? Bool == true {
            guard let indice = fluxo["Index"] as? Int else { continue }
            // O servidor converte qualquer legenda de texto para SRT; ASS vem
            // como ASS, para não perder cor e posição.
            let formato: String
            switch (fluxo["Codec"] as? String)?.lowercased() {
            case "ass": formato = "ass"
            case "ssa": formato = "ssa"
            default:    formato = "srt"
            }
            guard let dados = try? await pedirDados("/Videos/\(itemID)/\(fonteID)/Subtitles/\(indice)/0/Stream.\(formato)"),
                  !dados.isEmpty else { continue }
            var titulo = fluxo["DisplayTitle"] as? String ?? fluxo["Language"] as? String ?? "Legenda"
            if fluxo["IsForced"] as? Bool == true, titulo.range(of: "forced", options: .caseInsensitive) == nil {
                titulo += " forced"
            }
            let limpo = titulo.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
            // O índice no nome: duas faixas com o mesmo título não se sobrescrevem.
            legendas.append((nome: "\(limpo) (\(indice)).\(formato)", dados: dados))
        }
        return legendas
    }

    /// Conta ao servidor o que está tocando, para o "Continuar assistindo" e
    /// o "visto" valerem também no app dele, na TV e no navegador.
    ///
    /// `evento` é `nil` no começo, `Progress` durante e `Stopped` no fim — e
    /// é no `Stopped` perto do fim que o servidor marca como visto.
    func informar(_ evento: String?, item: String, segundos: Double, pausado: Bool, sessao: String) async throws {
        let corpo = try JSONSerialization.data(withJSONObject: [
            "ItemId": item,
            "MediaSourceId": item,
            "PositionTicks": Int64(max(0, segundos) * Self.ticks),
            "IsPaused": pausado,
            "CanSeek": true,
            "PlayMethod": "DirectPlay",
            "PlaySessionId": sessao,
        ] as [String: Any])
        // O servidor responde sem corpo (204): não há o que ler.
        _ = try await pedirDados("/Sessions/Playing" + (evento.map { "/\($0)" } ?? ""), corpo: corpo)
    }

    /// A caixinha "Já reproduzido" do app do Jellyfin: marca ou desmarca o
    /// item. Numa série ou temporada, vale para todos os episódios; e o
    /// servidor zera onde parou, então o vídeo sai do "Continuar" dos dois
    /// jeitos.
    func marcarVisto(_ itemID: String, _ visto: Bool) async throws {
        _ = try await pedirDados("/Users/\(usuarioID)/PlayedItems/\(itemID)",
                                 corpo: visto ? Data("{}".utf8) : nil, apagar: !visto)
    }

    /// Toda lista que chega do servidor diz onde a pessoa parou em cada
    /// vídeo. Guardar isso junto das marcas do aparelho é o que faz o "Você
    /// parou em…" do player valer para o que foi visto na TV ou no navegador.
    private func lembrandoOndeParou(_ itens: [Item]) async -> [Item] {
        let doServidor = itens.compactMap { item -> ResumeStore.DoServidor? in
            guard item.ehVideo, let quando = item.usuario?.ultimaVez.flatMap(Self.data) else { return nil }
            return ResumeStore.DoServidor(key: MediaOrigin.midia(conta: conta.id, item: item.id).resumeKey,
                                          position: item.posicao, duration: item.duracao ?? 0,
                                          at: quando, watched: item.visto)
        }
        if !doServidor.isEmpty {
            await MainActor.run { ResumeStore.shared.mesclar(doServidor) }
        }
        return itens
    }

    // MARK: - Endereços

    /// O arquivo original, sem conversão (`static=true`).
    func urlDoVideo(_ id: String) -> URL? {
        url("/Videos/\(id)/stream", consulta: [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: id),
        ] + chaveNaConsulta)
    }

    /// Imagem do item: `Thumb` e `Backdrop` são deitadas, como as capas do
    /// app; `Primary` de filme é o cartaz em pé, e fica por último.
    func urlDaImagem(_ id: String, tipo: String, largura: Int = 480) -> URL? {
        url("/Items/\(id)/Images/\(tipo)", consulta: [
            URLQueryItem(name: "maxWidth", value: "\(largura)"),
            URLQueryItem(name: "quality", value: "80"),
        ] + chaveNaConsulta)
    }

    func imagem(_ id: String, tipos: [String] = ["Thumb", "Backdrop", "Primary"],
                largura: Int = 480) async -> UIImage? {
        for tipo in tipos {
            guard let url = urlDaImagem(id, tipo: tipo, largura: largura),
                  let resposta = try? await URLSession.shared.data(from: url),
                  (resposta.1 as? HTTPURLResponse)?.statusCode == 200,
                  let imagem = UIImage(data: resposta.0) else { continue }
            return imagem
        }
        return nil
    }

    // MARK: - Login

    /// Entra com usuário e senha e devolve o id do usuário e o token.
    ///
    /// A senha não fica guardada: o token basta para tudo e pode ser revogado
    /// no painel do servidor sem trocar a senha.
    static func entrar(tipo: ContaDeRede.Tipo, endereco: String, usuario: String,
                       senha: String) async throws -> (usuarioID: String, token: String) {
        let provisoria = ContaDeRede(tipo: tipo, nome: "", endereco: endereco, usuario: usuario)
        let servidor = ServidorDeMidia(conta: provisoria, token: nil)
        struct Resposta: Decodable {
            struct Usuario: Decodable { let Id: String }
            let User: Usuario
            let AccessToken: String
        }
        let corpo = try JSONSerialization.data(withJSONObject: ["Username": usuario, "Pw": senha])
        let resposta: Resposta = try await servidor.pedir("/Users/AuthenticateByName", corpo: corpo)
        return (resposta.User.Id, resposta.AccessToken)
    }

    // MARK: - Chamadas

    private var usuarioID: String { conta.idNoServidor ?? "" }

    /// O Jellyfin novo lê `ApiKey`; o Emby, `api_key`. Mandar os dois serve
    /// aos dois sem precisar saber qual é qual.
    private var chaveNaConsulta: [URLQueryItem] {
        guard let token else { return [] }
        return [URLQueryItem(name: "ApiKey", value: token), URLQueryItem(name: "api_key", value: token)]
    }

    private static let idDoAparelho: String = {
        let chave = "libertyx.idDoAparelho"
        if let salvo = UserDefaults.standard.string(forKey: chave) { return salvo }
        let novo = UUID().uuidString
        UserDefaults.standard.set(novo, forKey: chave)
        return novo
    }()

    private var cabecalho: String {
        var texto = #"MediaBrowser Client="LibertyX Player", Device="iOS", "#
            + #"DeviceId="\#(Self.idDoAparelho)", Version="1.0""#
        if let token { texto += #", Token="\#(token)""# }
        return texto
    }

    private func url(_ caminho: String, consulta: [URLQueryItem] = []) -> URL? {
        let base = conta.endereco.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var partes = URLComponents(string: base + caminho) else { return nil }
        if !consulta.isEmpty { partes.queryItems = consulta }
        return partes.url
    }

    private func pedir<T: Decodable>(_ caminho: String, consulta: [URLQueryItem] = [],
                                     corpo: Data? = nil) async throws -> T {
        let dados = try await pedirDados(caminho, consulta: consulta, corpo: corpo)
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw ErroDeServidor(mensagem: String(localized: "Não há um servidor \(conta.tipo.nome) nesse endereço."))
        }
    }

    private func pedirDados(_ caminho: String, consulta: [URLQueryItem] = [],
                            corpo: Data? = nil, apagar: Bool = false) async throws -> Data {
        guard let url = url(caminho, consulta: consulta) else {
            throw ErroDeServidor(mensagem: String(localized: "Endereço inválido."))
        }
        var pedido = URLRequest(url: url, timeoutInterval: 20)
        // O Jellyfin lê `Authorization`; o Emby, `X-Emby-Authorization`.
        pedido.setValue(cabecalho, forHTTPHeaderField: "Authorization")
        pedido.setValue(cabecalho, forHTTPHeaderField: "X-Emby-Authorization")
        pedido.setValue("application/json", forHTTPHeaderField: "Accept")
        if let corpo {
            pedido.httpMethod = "POST"
            pedido.httpBody = corpo
            pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if apagar { pedido.httpMethod = "DELETE" }
        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        let codigo = (resposta as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(codigo) else {
            throw codigo == 404
                ? ErroDeServidor(mensagem: String(localized: "Não há um servidor \(conta.tipo.nome) nesse endereço."))
                : ErroDeServidor.http(codigo)
        }
        return dados
    }
}

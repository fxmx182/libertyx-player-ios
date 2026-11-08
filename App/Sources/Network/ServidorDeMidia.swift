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
            let favorito: Bool?

            enum CodingKeys: String, CodingKey {
                case posicaoTicks = "PlaybackPositionTicks", visto = "Played"
                case naoVistos = "UnplayedItemCount", ultimaVez = "LastPlayedDate"
                case favorito = "IsFavorite"
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

        var favorito: Bool { usuario?.favorito == true }

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

    /// Filmes, séries e episódios cujo nome tem `termo`, de todas as bibliotecas.
    func buscar(_ termo: String) async throws -> [Item] {
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Items", consulta: [
            URLQueryItem(name: "searchTerm", value: termo),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode,Video,MusicVideo"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "Limit", value: "40"),
        ])
        return await lembrandoOndeParou(lista.Items.filter { $0.ehVideo || $0.tipo == "Series" })
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

    // MARK: - Detalhes

    /// O que a tela de detalhes mostra antes de tocar — sinopse, elenco, as
    /// faixas do arquivo e de onde vêm o logotipo e o fundo. Os textos e as
    /// imagens vêm dos provedores do servidor (TMDB, OMDb, AniDB…); as faixas,
    /// da leitura que ele fez do próprio arquivo.
    struct Detalhes: Decodable {
        let sinopse: String?
        let estreia: Date?
        let nota: Double?
        let classificacao: String?
        let generos: [String]
        let pessoas: [Pessoa]
        let fluxos: [Fluxo]
        let nomeDaTemporada: String?
        /// Trailers do YouTube que os provedores acharam, e quantos há no disco.
        let trailersDaInternet: [URL]
        let trailersNoDisco: Int
        let extras: Int
        /// O logotipo e o fundo são do próprio item ou, num episódio, da série.
        let logoDe: String?
        let fundoDe: String?

        struct Pessoa: Decodable, Identifiable, Hashable {
            let id: String
            let nome: String
            let papel: String?
            let tipo: String

            enum CodingKeys: String, CodingKey { case id = "Id", nome = "Name", papel = "Role", tipo = "Type" }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                nome = (try? c.decode(String.self, forKey: .nome)) ?? ""
                papel = (try? c.decode(String.self, forKey: .papel)).flatMap { $0.isEmpty ? nil : $0 }
                tipo = (try? c.decode(String.self, forKey: .tipo)) ?? ""
            }
        }

        struct Fluxo: Decodable, Hashable {
            let tipo: String
            let titulo: String
            let externo: Bool
            /// O número da faixa no servidor — o que a conversão e as legendas de fora usam.
            let indice: Int
            let padrao: Bool

            enum CodingKeys: String, CodingKey {
                case tipo = "Type", titulo = "DisplayTitle", codec = "Codec", idioma = "Language", externo = "IsExternal"
                case indice = "Index", padrao = "IsDefault"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                tipo = (try? c.decode(String.self, forKey: .tipo)) ?? ""
                externo = (try? c.decode(Bool.self, forKey: .externo)) ?? false
                indice = (try? c.decode(Int.self, forKey: .indice)) ?? -1
                padrao = (try? c.decode(Bool.self, forKey: .padrao)) ?? false
                // O "1080p H264 SDR" e o "Portuguese - Dolby Digital+ - Stereo"
                // do app do servidor são este campo, montado por ele.
                let idioma = try? c.decode(String.self, forKey: .idioma)
                let codec = try? c.decode(String.self, forKey: .codec)
                titulo = (try? c.decode(String.self, forKey: .titulo))
                    ?? [idioma, codec].compactMap { $0 }.joined(separator: " - ")
            }
        }

        private enum CodingKeys: String, CodingKey {
            case sinopse = "Overview", estreia = "PremiereDate", nota = "CommunityRating"
            case classificacao = "OfficialRating", generos = "Genres", pessoas = "People"
            case fluxos = "MediaStreams", fontes = "MediaSources", nomeDaTemporada = "SeasonName"
            case id = "Id", imagens = "ImageTags", fundos = "BackdropImageTags"
            case logoDoPai = "ParentLogoItemId", fundoDoPai = "ParentBackdropItemId"
            case trailersDaInternet = "RemoteTrailers", trailersNoDisco = "LocalTrailerCount"
            case extras = "SpecialFeatureCount"
        }

        private struct Fonte: Decodable { let MediaStreams: [Fluxo]? }
        private struct Trailer: Decodable { let Url: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let id = (try? c.decode(String.self, forKey: .id)) ?? ""
            sinopse = (try? c.decode(String.self, forKey: .sinopse)).flatMap { $0.isEmpty ? nil : $0 }
            estreia = (try? c.decode(String.self, forKey: .estreia)).flatMap(ServidorDeMidia.data)
            nota = (try? c.decode(Double.self, forKey: .nota)).flatMap { $0 > 0 ? $0 : nil }
            classificacao = try? c.decode(String.self, forKey: .classificacao)
            generos = (try? c.decode([String].self, forKey: .generos)) ?? []
            pessoas = (try? c.decode([Pessoa].self, forKey: .pessoas)) ?? []
            // O Emby nem sempre põe as faixas no item; na primeira fonte, sim.
            let soltos = (try? c.decode([Fluxo].self, forKey: .fluxos)) ?? []
            fluxos = soltos.isEmpty
                ? ((try? c.decode([Fonte].self, forKey: .fontes))?.first?.MediaStreams ?? [])
                : soltos
            nomeDaTemporada = try? c.decode(String.self, forKey: .nomeDaTemporada)
            trailersDaInternet = ((try? c.decode([Trailer].self, forKey: .trailersDaInternet)) ?? [])
                .compactMap { $0.Url.flatMap(URL.init(string:)) }
            trailersNoDisco = (try? c.decode(Int.self, forKey: .trailersNoDisco)) ?? 0
            extras = (try? c.decode(Int.self, forKey: .extras)) ?? 0
            let imagens = (try? c.decode([String: String].self, forKey: .imagens)) ?? [:]
            let logoDoPai = try? c.decode(String.self, forKey: .logoDoPai)
            logoDe = imagens["Logo"] != nil ? id : logoDoPai
            let fundos = (try? c.decode([String].self, forKey: .fundos)) ?? []
            let fundoDoPai = try? c.decode(String.self, forKey: .fundoDoPai)
            fundoDe = !fundos.isEmpty ? id : fundoDoPai
        }

        func faixasDo(_ tipo: String) -> [String] {
            fluxos.filter { $0.tipo == tipo }.map(\.titulo).filter { !$0.isEmpty }
        }

        func fluxosDo(_ tipo: String) -> [Fluxo] { fluxos.filter { $0.tipo == tipo } }

        func pessoasCom(_ tipos: Set<String>) -> [Pessoa] { pessoas.filter { tipos.contains($0.tipo) } }
    }

    /// O item de novo (o "visto" e onde parou podem ter mudado) e os detalhes dele.
    func detalhes(_ id: String) async throws -> (item: Item, detalhes: Detalhes) {
        let dados = try await pedirDados("/Users/\(usuarioID)/Items/\(id)", consulta: [
            URLQueryItem(name: "Fields", value: "Overview,People,Genres,MediaSources,MediaStreams,PremiereDate,DateCreated,RemoteTrailers"),
        ])
        do {
            let decodificador = JSONDecoder()
            let item = try decodificador.decode(Item.self, from: dados)
            let detalhes = try decodificador.decode(Detalhes.self, from: dados)
            _ = await lembrandoOndeParou([item])
            return (item, detalhes)
        } catch {
            throw ErroDeServidor(mensagem: String(localized: "Não há um servidor \(conta.tipo.nome) nesse endereço."))
        }
    }

    // MARK: - Séries, pessoas, favoritos

    /// As temporadas da série, na ordem.
    func temporadas(_ serieID: String) async throws -> [Item] {
        let lista: Lista = try await pedir("/Shows/\(serieID)/Seasons", consulta: [
            URLQueryItem(name: "UserId", value: usuarioID),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return lista.Items
    }

    /// Os episódios de uma temporada da série.
    func episodios(_ serieID: String, temporada: String) async throws -> [Item] {
        let lista: Lista = try await pedir("/Shows/\(serieID)/Episodes", consulta: [
            URLQueryItem(name: "UserId", value: usuarioID),
            URLQueryItem(name: "SeasonId", value: temporada),
            URLQueryItem(name: "Fields", value: "DateCreated,Overview"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(lista.Items.filter(\.ehVideo))
    }

    /// O episódio que a pessoa deve ver agora: o "A seguir" da série.
    func proximoDaSerie(_ serieID: String) async throws -> Item? {
        let lista: Lista = try await pedir("/Shows/NextUp", consulta: [
            URLQueryItem(name: "UserId", value: usuarioID),
            URLQueryItem(name: "SeriesId", value: serieID),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(lista.Items).first(where: \.ehVideo)
    }

    /// Os filmes e as séries de que a pessoa participou, do mais novo ao mais velho.
    func obras(daPessoa id: String) async throws -> [Item] {
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Items", consulta: [
            URLQueryItem(name: "PersonIds", value: id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "SortBy", value: "PremiereDate,ProductionYear,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(lista.Items)
    }

    /// Os favoritos do usuário: filmes, séries e episódios marcados com o coração.
    func favoritos() async throws -> [Item] {
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Items", consulta: [
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode,Video"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ])
        return await lembrandoOndeParou(lista.Items)
    }

    /// Os gêneros que existem numa biblioteca, para o filtro.
    func generos(_ biblioteca: Item) async throws -> [String] {
        let lista: Lista = try await pedir("/Genres", consulta: [
            URLQueryItem(name: "ParentId", value: biblioteca.id),
            URLQueryItem(name: "UserId", value: usuarioID),
            URLQueryItem(name: "SortBy", value: "SortName"),
        ])
        return lista.Items.map(\.nome).filter { !$0.isEmpty }
    }

    /// Ordem e filtros de uma biblioteca, como no app do Jellyfin.
    struct Filtro: Equatable {
        enum Ordem: String, CaseIterable {
            case nome = "SortName", adicionado = "DateCreated", lancamento = "PremiereDate"
            case nota = "CommunityRating", aleatorio = "Random"
        }
        var ordem: Ordem = .nome
        var decrescente = false
        var naoVistos = false
        var favoritos = false
        var genero: String?

        var ativo: Bool { naoVistos || favoritos || genero != nil || ordem != .nome || decrescente }
    }

    /// O que há numa biblioteca de filmes ou séries, já ordenado e filtrado
    /// pelo servidor — que sabe a nota, a data e o gênero de cada um.
    func itens(de biblioteca: Item, filtro: Filtro) async throws -> [Item] {
        var consulta = [
            URLQueryItem(name: "ParentId", value: biblioteca.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: biblioteca.tipoDeColecao == "tvshows" ? "Series" : "Movie"),
            URLQueryItem(name: "SortBy", value: filtro.ordem == .nome ? "SortName" : "\(filtro.ordem.rawValue),SortName"),
            URLQueryItem(name: "SortOrder", value: filtro.decrescente ? "Descending" : "Ascending"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ]
        var filtros: [String] = []
        if filtro.naoVistos { filtros.append("IsUnplayed") }
        if filtro.favoritos { filtros.append("IsFavorite") }
        if !filtros.isEmpty { consulta.append(URLQueryItem(name: "Filters", value: filtros.joined(separator: ","))) }
        if let genero = filtro.genero { consulta.append(URLQueryItem(name: "Genres", value: genero)) }
        let lista: Lista = try await pedir("/Users/\(usuarioID)/Items", consulta: consulta)
        return await lembrandoOndeParou(lista.Items)
    }

    // MARK: - Trailers, extras e marcações

    /// Os trailers guardados no disco, ao lado do filme.
    func trailersNoDisco(_ id: String) async throws -> [Item] {
        try await pedir("/Users/\(usuarioID)/Items/\(id)/LocalTrailers")
    }

    /// Bastidores, cenas cortadas, entrevistas: os extras da pasta do filme.
    func extras(_ id: String) async throws -> [Item] {
        try await pedir("/Users/\(usuarioID)/Items/\(id)/SpecialFeatures")
    }

    /// Um trecho marcado do vídeo — abertura, créditos, recapitulação.
    struct Segmento: Decodable, Hashable {
        let tipo: String
        let inicio: Double
        let fim: Double

        enum CodingKeys: String, CodingKey { case tipo = "Type", inicio = "StartTicks", fim = "EndTicks" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tipo = (try? c.decode(String.self, forKey: .tipo)) ?? ""
            inicio = Double((try? c.decode(Int64.self, forKey: .inicio)) ?? 0) / ServidorDeMidia.ticks
            fim = Double((try? c.decode(Int64.self, forKey: .fim)) ?? 0) / ServidorDeMidia.ticks
        }
    }

    /// As marcações do vídeo (Jellyfin 10.10 em diante). Quem as cria é um
    /// plugin do servidor — o Intro Skipper, por exemplo; sem ele a lista vem
    /// vazia e o player só não oferece o "Pular".
    func segmentos(_ id: String) async -> [Segmento] {
        struct Resposta: Decodable { let Items: [Segmento] }
        guard let resposta: Resposta = try? await pedir("/MediaSegments/\(id)") else { return [] }
        return resposta.Items.filter { $0.fim > $0.inicio }
    }

    // MARK: - Usuários e Quick Connect

    /// Os usuários que o servidor mostra na tela de entrada — os que não
    /// estão ocultos. Serve para escolher quem entra sem digitar o nome.
    static func usuariosVisiveis(tipo: ContaDeRede.Tipo, endereco: String) async -> [String] {
        let provisoria = ContaDeRede(tipo: tipo, nome: "", endereco: endereco, usuario: "")
        struct Usuario: Decodable { let Name: String }
        let lista: [Usuario]? = try? await ServidorDeMidia(conta: provisoria, token: nil).pedir("/Users/Public")
        return (lista ?? []).map(\.Name)
    }

    /// O código do Quick Connect: aparece no app e é aprovado em outro
    /// aparelho já conectado (Painel do usuário › Quick Connect).
    struct PedidoDeQuickConnect: Decodable {
        let Code: String
        let Secret: String
    }

    static func iniciarQuickConnect(tipo: ContaDeRede.Tipo, endereco: String) async throws -> PedidoDeQuickConnect {
        let provisoria = ContaDeRede(tipo: tipo, nome: "", endereco: endereco, usuario: "")
        do {
            return try await ServidorDeMidia(conta: provisoria, token: nil)
                .pedir("/QuickConnect/Initiate", corpo: Data("{}".utf8))
        } catch let erro as URLError {
            // Sem conexão é outro problema: quem chama tenta o outro endereço.
            throw erro
        } catch {
            throw ErroDeServidor(mensagem: String(localized: "Este servidor não tem o Quick Connect ligado."))
        }
    }

    /// Espera a aprovação e entra. Devolve o nome, o id do usuário e o token.
    static func esperarQuickConnect(tipo: ContaDeRede.Tipo, endereco: String,
                                    _ pedido: PedidoDeQuickConnect) async throws -> (usuario: String, usuarioID: String, token: String) {
        let provisoria = ContaDeRede(tipo: tipo, nome: "", endereco: endereco, usuario: "")
        let servidor = ServidorDeMidia(conta: provisoria, token: nil)
        struct Estado: Decodable { let Authenticated: Bool }
        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let estado: Estado = try await servidor.pedir("/QuickConnect/Connect",
                                                          consulta: [URLQueryItem(name: "Secret", value: pedido.Secret)])
            if estado.Authenticated { break }
        }
        struct Resposta: Decodable {
            struct Usuario: Decodable { let Id: String; let Name: String }
            let User: Usuario
            let AccessToken: String
        }
        let corpo = try JSONSerialization.data(withJSONObject: ["Secret": pedido.Secret])
        let resposta: Resposta = try await servidor.pedir("/Users/AuthenticateWithQuickConnect", corpo: corpo)
        return (resposta.User.Name, resposta.User.Id, resposta.AccessToken)
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
    func informar(_ evento: String?, item: String, segundos: Double, pausado: Bool, sessao: String,
                  convertendo: Bool = false) async throws {
        let corpo = try JSONSerialization.data(withJSONObject: [
            "ItemId": item,
            "MediaSourceId": item,
            "PositionTicks": Int64(max(0, segundos) * Self.ticks),
            "IsPaused": pausado,
            "CanSeek": true,
            "PlayMethod": convertendo ? "Transcode" : "DirectPlay",
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

    /// O coração do app do Jellyfin: os favoritos são do usuário, valem em
    /// todo aparelho.
    func marcarFavorito(_ itemID: String, _ favorito: Bool) async throws {
        _ = try await pedirDados("/Users/\(usuarioID)/FavoriteItems/\(itemID)",
                                 corpo: favorito ? Data("{}".utf8) : nil, apagar: !favorito)
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

    /// A versão convertida pelo servidor (ver `Qualidade`): uma lista HLS em
    /// H.264 e AAC estéreo, no teto de bits pedido. Só o vídeo e o áudio
    /// escolhido; as legendas de fora o app baixa à parte, como sempre.
    func urlDaConversao(_ id: String, kbps: Int, sessao: String, audio: Int?) -> URL? {
        let largura = kbps >= 10_000 ? 1920 : kbps >= 4_000 ? 1280 : kbps >= 2_000 ? 960 : 640
        var consulta = [
            URLQueryItem(name: "MediaSourceId", value: id),
            URLQueryItem(name: "DeviceId", value: Self.idDoAparelho),
            URLQueryItem(name: "PlaySessionId", value: sessao),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "VideoBitrate", value: "\(max(300_000, kbps * 1000 - 192_000))"),
            URLQueryItem(name: "AudioBitrate", value: "192000"),
            URLQueryItem(name: "MaxAudioChannels", value: "2"),
            URLQueryItem(name: "TranscodingMaxAudioChannels", value: "2"),
            URLQueryItem(name: "MaxWidth", value: "\(largura)"),
            URLQueryItem(name: "SegmentContainer", value: "ts"),
            URLQueryItem(name: "MinSegments", value: "1"),
            URLQueryItem(name: "BreakOnNonKeyFrames", value: "true"),
        ]
        if let audio { consulta.append(URLQueryItem(name: "AudioStreamIndex", value: "\(audio)")) }
        return url("/Videos/\(id)/master.m3u8", consulta: consulta + chaveNaConsulta)
    }

    /// Desliga a conversão no servidor quando o vídeo fecha — sem isto, o
    /// ffmpeg de lá continuaria convertendo um filme que ninguém vê.
    func pararConversao(_ sessao: String) async {
        _ = try? await pedirDados("/Videos/ActiveEncodings", consulta: [
            URLQueryItem(name: "DeviceId", value: Self.idDoAparelho),
            URLQueryItem(name: "PlaySessionId", value: sessao),
        ], apagar: true)
    }

    /// O token num cabeçalho, para a ponte repassar a cada pedaço da conversão.
    var cabecalhoDoToken: [String: String] {
        token.map { ["X-Emby-Token": $0] } ?? [:]
    }

    /// Imagem do item: `Thumb` e `Backdrop` são deitadas, como as capas do
    /// app; `Primary` de filme é o cartaz em pé, e fica por último.
    func urlDaImagem(_ id: String, tipo: String, largura: Int = 480) -> URL? {
        url("/Items/\(id)/Images/\(tipo)", consulta: [
            URLQueryItem(name: "maxWidth", value: "\(largura)"),
            URLQueryItem(name: "quality", value: "80"),
        ] + chaveNaConsulta)
    }

    /// A imagem, ou por que não veio: o servidor não tem nenhuma das pedidas
    /// (não adianta pedir de novo) ou o pedido caiu no caminho (adianta).
    enum ImagemBaixada {
        case imagem(UIImage)
        case naoTem
        case falhou
    }

    func baixarImagem(_ id: String, tipos: [String], largura: Int) async -> ImagemBaixada {
        var caiu = false
        for tipo in tipos {
            guard let url = urlDaImagem(id, tipo: tipo, largura: largura) else { continue }
            await LimiteDeImagens.shared.entrar()
            let resposta = try? await URLSession.shared.data(from: url)
            await LimiteDeImagens.shared.sair()
            guard let resposta else { caiu = true; continue }
            let codigo = (resposta.1 as? HTTPURLResponse)?.statusCode ?? 0
            if codigo == 200, let imagem = UIImage(data: resposta.0) { return .imagem(imagem) }
            if codigo != 404 { caiu = true }
        }
        return caiu ? .falhou : .naoTem
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

/// Quantas imagens descem ao mesmo tempo. Uma tela de faixas pede dezenas de
/// capas de uma vez, e despejar todas juntas num servidor atrás do Cloudflare
/// fazia uma parte cair por tempo esgotado — e a capa ficava vazia.
actor LimiteDeImagens {
    static let shared = LimiteDeImagens()

    private let maximo = 6
    private var emCurso = 0
    private var fila: [CheckedContinuation<Void, Never>] = []

    func entrar() async {
        if emCurso < maximo {
            emCurso += 1
            return
        }
        await withCheckedContinuation { fila.append($0) }
    }

    func sair() {
        if fila.isEmpty {
            emCurso -= 1
        } else {
            // A vaga passa direto para o próximo da fila.
            fila.removeFirst().resume()
        }
    }
}

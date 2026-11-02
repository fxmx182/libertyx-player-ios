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

        enum CodingKeys: String, CodingKey {
            case id = "Id", nome = "Name", tipo = "Type", ehPasta = "IsFolder"
            case tipoDeColecao = "CollectionType", duracaoTicks = "RunTimeTicks"
            case ano = "ProductionYear", numero = "IndexNumber"
            case temporada = "ParentIndexNumber", criado = "DateCreated"
            case serie = "SeriesName"
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
        }

        var ehVideo: Bool {
            !ehPasta && ["Movie", "Episode", "Video", "MusicVideo"].contains(tipo)
        }

        /// Duração em segundos; o servidor conta em décimos de microssegundo.
        var duracao: Double? {
            guard let duracaoTicks, duracaoTicks > 0 else { return nil }
            return Double(duracaoTicks) / 10_000_000
        }

        /// Episódio com o número na frente, filme com o ano: é como se acha
        /// o que se procura numa lista longa.
        var titulo: String {
            if tipo == "Episode", let numero { return "\(numero). \(nome)" }
            if tipo == "Movie", let ano { return "\(nome) (\(ano))" }
            return nome
        }

        var dataDeCriacao: Date? {
            guard let criado else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let data = f.date(from: criado) { return data }
            f.formatOptions = [.withInternetDateTime]
            // O servidor manda sete casas de fração, que o formatador recusa;
            // sem a fração a data ainda serve para ordenar.
            let semFracao = criado.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            return f.date(from: semFracao)
        }
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
        return lista.Items
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
        return lista.Items.filter(\.ehVideo)
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
    func urlDaImagem(_ id: String, tipo: String) -> URL? {
        url("/Items/\(id)/Images/\(tipo)", consulta: [
            URLQueryItem(name: "maxWidth", value: "480"),
            URLQueryItem(name: "quality", value: "80"),
        ] + chaveNaConsulta)
    }

    func imagem(_ id: String) async -> UIImage? {
        for tipo in ["Thumb", "Backdrop", "Primary"] {
            guard let url = urlDaImagem(id, tipo: tipo),
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
        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        let codigo = (resposta as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(codigo) else {
            throw codigo == 404
                ? ErroDeServidor(mensagem: String(localized: "Não há um servidor \(conta.tipo.nome) nesse endereço."))
                : ErroDeServidor.http(codigo)
        }
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw ErroDeServidor(mensagem: String(localized: "Não há um servidor \(conta.tipo.nome) nesse endereço."))
        }
    }
}

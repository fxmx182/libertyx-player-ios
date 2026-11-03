import Foundation

/// Cliente WebDAV — o suficiente para navegar por pastas e entregar ao VLC o
/// endereço de cada vídeo.
///
/// É por aqui que entra o Nextcloud: os arquivos dele ficam em
/// `/remote.php/dav/files/<usuário>/`. Quem toca é o VLC, por HTTP comum, com
/// busca por faixa de bytes; listar pasta é a única coisa que exige o
/// vocabulário do WebDAV (`PROPFIND`).
struct WebDAV {

    struct Entrada: Identifiable, Hashable {
        var id: String { caminho }
        let nome: String
        /// Caminho no servidor, já decodificado e começando por `/`.
        let caminho: String
        let ehPasta: Bool
        let tamanho: Int64?
        let modificado: Date?
    }

    let conta: ContaDeRede
    let senha: String?

    /// Pasta de partida: o caminho que veio no endereço da conta.
    var raiz: String {
        let caminho = conta.url?.path ?? "/"
        return caminho.isEmpty ? "/" : caminho
    }

    // MARK: - Listagem

    func listar(_ caminho: String) async throws -> [Entrada] {
        guard let url = Self.url(base: conta.url, caminho: caminho, pasta: true) else {
            throw ErroDeServidor(mensagem: String(localized: "Endereço inválido."))
        }
        var pedido = URLRequest(url: url, timeoutInterval: 20)
        pedido.httpMethod = "PROPFIND"
        // Só o nível de baixo: `infinity` faria o servidor descer a árvore
        // inteira, e muitos recusam.
        pedido.setValue("1", forHTTPHeaderField: "Depth")
        pedido.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let autorizacao = autorizacao { pedido.setValue(autorizacao, forHTTPHeaderField: "Authorization") }
        pedido.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop>
            <d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:displayname/>
            </d:prop></d:propfind>
            """.utf8)

        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        let codigo = (resposta as? HTTPURLResponse)?.statusCode ?? 0
        // 207 é a resposta própria do WebDAV. Um 200 aqui costuma ser uma
        // página de login, não uma listagem.
        guard codigo == 207 else {
            throw codigo == 200
                ? ErroDeServidor(mensagem: String(localized: "O endereço respondeu, mas não é uma pasta WebDAV."))
                : ErroDeServidor.http(codigo)
        }

        let pastaPedida = Self.normalizar(caminho)
        return LeitorDePropfind.ler(dados).compactMap { bruta in
            let caminho = Self.caminho(deHref: bruta.href)
            // A própria pasta vem na resposta, junto com o que tem dentro.
            guard Self.normalizar(caminho) != pastaPedida else { return nil }
            let nome = (caminho as NSString).lastPathComponent
            // Ocultos do sistema (`.DS_Store`, `.nomedia`) não interessam.
            guard !nome.isEmpty, !nome.hasPrefix(".") else { return nil }
            return Entrada(nome: nome, caminho: caminho, ehPasta: bruta.ehPasta,
                           tamanho: bruta.tamanho, modificado: bruta.modificado)
        }
    }

    /// Um arquivo inteiro do servidor — as legendas ao lado do vídeo.
    func baixar(_ caminho: String) async throws -> Data {
        guard let url = Self.url(base: conta.url, caminho: caminho, pasta: false) else {
            throw ErroDeServidor(mensagem: String(localized: "Endereço inválido."))
        }
        var pedido = URLRequest(url: url, timeoutInterval: 20)
        if let autorizacao = autorizacao { pedido.setValue(autorizacao, forHTTPHeaderField: "Authorization") }
        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        let codigo = (resposta as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(codigo) else { throw ErroDeServidor.http(codigo) }
        return dados
    }

    // MARK: - Endereços

    /// Endereço de reprodução: a ponte local, que fala com o servidor pelo
    /// TLS do iOS e leva a senha num cabeçalho — ver `PonteHTTP`.
    func urlDeReproducao(_ caminho: String) async throws -> URL? {
        guard let url = Self.url(base: conta.url, caminho: caminho, pasta: false) else { return nil }
        var cabecalhos: [String: String] = [:]
        if let autorizacao { cabecalhos["Authorization"] = autorizacao }
        return try await PonteHTTP.shared.endereco(para: url, cabecalhos: cabecalhos,
                                                   nome: (caminho as NSString).lastPathComponent)
    }

    private var autorizacao: String? {
        guard !conta.usuario.isEmpty else { return nil }
        let par = "\(conta.usuario):\(senha ?? "")"
        return "Basic " + Data(par.utf8).base64EncodedString()
    }

    /// Esquema, servidor e porta da conta, com o caminho codificado pedaço a
    /// pedaço — nome de arquivo com espaço, acento ou `#` é o normal.
    static func url(base: URL?, caminho: String, pasta: Bool) -> URL? {
        guard let base, var partes = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var codificado = caminho.split(separator: "/").map { escapar(String($0)) }.joined(separator: "/")
        codificado = "/" + codificado
        if pasta, !codificado.hasSuffix("/") { codificado += "/" }
        partes.percentEncodedPath = codificado
        partes.query = nil
        partes.fragment = nil
        return partes.url
    }

    /// O `href` pode vir como caminho (`/dav/a%20b/`) ou como URL completa.
    static func caminho(deHref href: String) -> String {
        let limpo = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if limpo.hasPrefix("http"), let url = URL(string: limpo) {
            return url.path
        }
        return limpo.removingPercentEncoding ?? limpo
    }

    static func normalizar(_ caminho: String) -> String {
        var c = caminho
        while c.count > 1, c.hasSuffix("/") { c.removeLast() }
        return c.isEmpty ? "/" : c
    }

    static func escapar(_ texto: String) -> String {
        texto.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? texto
    }
}

/// Lê a resposta `multistatus` do PROPFIND.
///
/// O prefixo do espaço de nomes muda de servidor para servidor (`d:`, `D:`,
/// nenhum), então o leitor compara só o nome local de cada elemento.
private final class LeitorDePropfind: NSObject, XMLParserDelegate {

    struct Bruta {
        var href = ""
        var ehPasta = false
        var tamanho: Int64?
        var modificado: Date?
    }

    private var lidas: [Bruta] = []
    private var atual: Bruta?
    private var texto = ""

    private static let formatoDeData: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func ler(_ dados: Data) -> [Bruta] {
        let leitor = LeitorDePropfind()
        let parser = XMLParser(data: dados)
        parser.shouldProcessNamespaces = true
        parser.delegate = leitor
        parser.parse()
        return leitor.lidas
    }

    func parser(_ parser: XMLParser, didStartElement nome: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        texto = ""
        switch nome {
        case "response":   atual = Bruta()
        case "collection": atual?.ehPasta = true
        default:           break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        texto += string
    }

    func parser(_ parser: XMLParser, didEndElement nome: String, namespaceURI: String?,
                qualifiedName: String?) {
        let valor = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        switch nome {
        case "href":             if atual?.href.isEmpty == true { atual?.href = valor }
        case "getcontentlength": atual?.tamanho = Int64(valor)
        case "getlastmodified":  atual?.modificado = Self.formatoDeData.date(from: valor)
        case "response":
            if let atual, !atual.href.isEmpty { lidas.append(atual) }
            atual = nil
        default: break
        }
        texto = ""
    }
}

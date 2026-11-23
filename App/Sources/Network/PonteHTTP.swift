import Foundation
import Network
import UIKit

/// Ponte local entre o VLC e servidores HTTPS.
///
/// O VLC do iPhone faz HTTPS pelo SecureTransport, a camada antiga da Apple,
/// que só chega ao TLS 1.2. Servidor que exige TLS 1.3 — o Nextcloud do
/// usuário atrás do Cloudflare é um — recusa a conexão antes de qualquer
/// pedido, e o VLC só diz que "não conseguiu abrir". No Android o VLC usa
/// GnuTLS, que fala 1.3, e o problema não existe.
///
/// A saída é o VLC não falar com o servidor: ele pede a `http://127.0.0.1`,
/// e esta ponte busca os bytes pelo `URLSession`, que é o TLS do próprio iOS.
/// De quebra a senha do WebDAV deixa de andar dentro da URL: vai num
/// cabeçalho, só entre o app e o servidor.
///
/// Busca por faixas de bytes, um bloco por vez, com o seguinte já a caminho
/// enquanto o atual é entregue. Entregar só depois de o VLC consumir o bloco
/// anterior é o que impede um filme inteiro de se acumular na memória quando
/// ele pausa ou enche o próprio buffer.
final class PonteHTTP: NSObject, @unchecked Sendable {

    static let shared = PonteHTTP()

    private struct Destino {
        let url: URL
        let cabecalhos: [String: String]
        /// Lista HLS (a conversão do Jellyfin): cada pedido é um arquivo
        /// diferente ao lado da lista, e não um pedaço do mesmo arquivo.
        var lista = false
    }

    private let fila = DispatchQueue(label: "libertyx.ponte")
    private let trava = NSLock()
    private var listener: NWListener?
    private var porta: UInt16?
    private var esperando: [CheckedContinuation<UInt16, Error>] = []
    /// Um token por endereço: tocar o mesmo vídeo de novo reaproveita o mesmo.
    private var destinos: [String: Destino] = [:]
    private var tokens: [String: String] = [:]

    private let sessao: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// O primeiro bloco é pequeno para a imagem aparecer logo; abrir um vídeo
    /// faz o VLC pular várias vezes entre o começo e o fim do arquivo.
    private static let primeiroBloco: Int64 = 512 * 1024
    private static let bloco: Int64 = 4 * 1024 * 1024

    /// O endereço local que o VLC abre no lugar de `url`.
    func endereco(para url: URL, cabecalhos: [String: String] = [:], nome: String) async throws -> URL {
        let porta = try await portaPronta()
        trava.lock()
        let chave = url.absoluteString
        let token = tokens[chave] ?? UUID().uuidString
        tokens[chave] = token
        destinos[token] = Destino(url: url, cabecalhos: cabecalhos)
        trava.unlock()
        // O nome no fim só ajuda o VLC a adivinhar o formato pela extensão.
        let nomeSeguro = nome.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? "video"
        guard let local = URL(string: "http://127.0.0.1:\(porta)/\(token)/\(nomeSeguro)") else {
            throw URLError(.badURL)
        }
        return local
    }

    /// O endereço local de uma lista HLS. A lista e os pedaços dela usam
    /// endereços relativos, então tudo o que o VLC pedir depois do token é
    /// resolvido a partir de `url` e repassado inteiro, sem faixas de bytes.
    func endereco(paraLista url: URL, cabecalhos: [String: String] = [:]) async throws -> URL {
        let porta = try await portaPronta()
        let token = UUID().uuidString
        trava.lock()
        destinos[token] = Destino(url: url, cabecalhos: cabecalhos, lista: true)
        trava.unlock()
        var local = "http://127.0.0.1:\(porta)/\(token)/\(url.lastPathComponent)"
        if let consulta = url.query { local += "?" + consulta }
        guard let endereco = URL(string: local) else { throw URLError(.badURL) }
        return endereco
    }

    // MARK: - Servidor local

    /// A porta da ponte anterior: refeita, a ponte tenta a mesma, para o
    /// vídeo que já estava aberto continuar no endereço que o VLC tem.
    private var portaAnterior: UInt16?

    /// A porta da ponte, conferida: a ponte que não responde é refeita.
    ///
    /// Com o app parado ou em segundo plano, o iOS derruba o soquete da ponte
    /// sem avisar — o estado continua "pronta" e nenhum erro chega. A porta
    /// guardada seguia sendo entregue ao VLC, que levava "conexão recusada"
    /// em todo vídeo até o app ser fechado; e o vídeo que estava aberto
    /// terminava sozinho no primeiro pulo, como se tivesse chegado ao fim.
    private func portaPronta() async throws -> UInt16 {
        if let atual = trava.withLock({ porta }), !(await responde(atual)) {
            LabLog.problem("ponte: a porta \(atual) parou de responder; refazendo")
            refazer()
        }
        return try await abrir()
    }

    /// Ao voltar para a frente, a ponte é conferida antes de o VLC precisar.
    @objc private func voltouParaAFrente() {
        Task { _ = try? await portaPronta() }
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(voltouParaAFrente),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    private func abrir() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuacao in
            fila.async {
                if let porta = self.trava.withLock({ self.porta }) { continuacao.resume(returning: porta); return }
                self.esperando.append(continuacao)
                guard self.listener == nil else { return }
                self.escutar(em: self.portaAnterior)
            }
        }
    }

    /// Na fila. `numero` nil: qualquer porta livre.
    private func escutar(em numero: UInt16?) {
        do {
            let parametros = NWParameters.tcp
            parametros.allowLocalEndpointReuse = true
            // Só o próprio aparelho: nada de fora alcança a ponte.
            let porta = numero.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
            parametros.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: porta)
            let novo = try NWListener(using: parametros)
            novo.newConnectionHandler = { [weak self] conexao in
                guard let self else { return }
                conexao.start(queue: self.fila)
                Task { await self.atender(conexao) }
            }
            novo.stateUpdateHandler = { [weak self, weak novo] estado in
                guard let self, let novo, novo === self.listener else { return }
                self.mudou(estado, pedida: numero)
            }
            listener = novo
            novo.start(queue: fila)
        } catch {
            if numero != nil { escutar(em: nil) } else { falhou(error) }
        }
    }

    private func mudou(_ estado: NWListener.State, pedida: UInt16?) {
        switch estado {
        case .ready:
            guard let numero = listener?.port?.rawValue else { return }
            trava.withLock { porta = numero }
            portaAnterior = numero
            esperando.forEach { $0.resume(returning: numero) }
            esperando = []
        case .failed(let erro), .waiting(let erro):
            // A porta de antes pode estar ocupada: qualquer outra serve.
            if pedida != nil {
                listener?.cancel()
                listener = nil
                escutar(em: nil)
            } else {
                falhou(erro)
            }
        case .cancelled:
            // Cancelada por fora (o iOS): a próxima vez refaz.
            listener = nil
            trava.withLock { porta = nil }
        default:
            break
        }
    }

    /// Joga a ponte fora; a próxima chamada abre outra, na mesma porta se der.
    private func refazer() {
        fila.sync {
            listener?.cancel()
            listener = nil
            trava.withLock { porta = nil }
        }
    }

    /// Começa do zero na próxima vez: a ponte pode cair quando o iOS
    /// suspende o app, e quem pedir depois precisa de uma nova.
    private func falhou(_ erro: Error) {
        LabLog.problem("ponte: \(erro)")
        listener?.cancel()
        listener = nil
        trava.withLock { porta = nil }
        esperando.forEach { $0.resume(throwing: erro) }
        esperando = []
    }

    /// Se a ponte aceita conexão nesta porta (até um segundo).
    private func responde(_ numero: UInt16) async -> Bool {
        guard let porta = NWEndpoint.Port(rawValue: numero) else { return false }
        return await withCheckedContinuation { continuacao in
            let conexao = NWConnection(host: .ipv4(.loopback), port: porta, using: .tcp)
            let resposta = RespostaDaPonte(continuacao)
            conexao.stateUpdateHandler = { estado in
                switch estado {
                case .ready: resposta.dar(true); conexao.cancel()
                case .failed, .waiting: resposta.dar(false); conexao.cancel()
                default: break
                }
            }
            conexao.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                resposta.dar(false)
                conexao.cancel()
            }
        }
    }

    // MARK: - Um pedido do VLC

    private struct Pedido {
        let metodo: String
        let token: String
        /// O que vem depois do token, com a consulta: o arquivo pedido numa lista.
        let resto: String
        let inicio: Int64?
        let fim: Int64?

        init?(_ texto: String) {
            let linhas = texto.components(separatedBy: "\r\n")
            let partes = linhas.first?.split(separator: " ") ?? []
            guard partes.count >= 2 else { return nil }
            metodo = String(partes[0])
            let caminho = partes[1].split(separator: "/", maxSplits: 1)
            guard let primeiro = caminho.first else { return nil }
            token = String(primeiro)
            resto = caminho.count > 1 ? String(caminho[1]) : ""

            var inicio: Int64?
            var fim: Int64?
            for linha in linhas.dropFirst() where linha.lowercased().hasPrefix("range:") {
                // "Range: bytes=123-" ou "bytes=123-456".
                let valor = linha.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                let limites = valor.split(separator: "-", omittingEmptySubsequences: false)
                inicio = limites.first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                if limites.count > 1 { fim = Int64(limites[1].trimmingCharacters(in: .whitespaces)) }
            }
            self.inicio = inicio
            self.fim = fim
        }
    }

    private struct Bloco {
        let status: Int
        let dados: Data
        let total: Int64?
        let tipo: String?
    }

    private func atender(_ conexao: NWConnection) async {
        defer { conexao.cancel() }
        guard let texto = await lerCabecalho(conexao), let pedido = Pedido(texto) else { return }

        trava.lock()
        let destino = destinos[pedido.token]
        trava.unlock()
        guard let destino else {
            try? await enviarCabecalho(conexao, status: 404, campos: ["Content-Length": "0"])
            return
        }
        guard pedido.metodo == "GET" || pedido.metodo == "HEAD" else {
            try? await enviarCabecalho(conexao, status: 405, campos: ["Content-Length": "0"])
            return
        }

        if destino.lista {
            await repassar(conexao, destino, pedido)
            return
        }

        do {
            let inicio = pedido.inicio ?? 0
            let primeiro = try await baixar(destino, de: inicio, ate: limite(inicio, Self.primeiroBloco, pedido.fim))

            // Sem faixa (ou erro): repassa como veio. Servidor que não aceita
            // faixas não deixa buscar no meio do vídeo, mas ainda toca.
            guard primeiro.status == 206, let total = primeiro.total else {
                var campos = ["Content-Length": "\(primeiro.dados.count)"]
                if let tipo = primeiro.tipo { campos["Content-Type"] = tipo }
                try await enviarCabecalho(conexao, status: primeiro.status, campos: campos)
                if pedido.metodo == "GET" { try await enviar(conexao, primeiro.dados) }
                return
            }

            let fim = min(pedido.fim ?? total - 1, total - 1)
            var campos = [
                "Content-Length": "\(max(0, fim - inicio + 1))",
                "Accept-Ranges": "bytes",
            ]
            if let tipo = primeiro.tipo { campos["Content-Type"] = tipo }
            // O VLC só sabe que o arquivo aceita busca se vir a faixa de volta.
            if pedido.inicio != nil { campos["Content-Range"] = "bytes \(inicio)-\(fim)/\(total)" }
            try await enviarCabecalho(conexao, status: pedido.inicio != nil ? 206 : 200, campos: campos)
            guard pedido.metodo == "GET" else { return }

            var atual = primeiro.dados
            var posicao = inicio
            while !atual.isEmpty {
                let seguinte = posicao + Int64(atual.count)
                let proximo: Task<Bloco, Error>? = seguinte <= fim
                    ? Task { try await self.baixar(destino, de: seguinte, ate: self.limite(seguinte, Self.bloco, fim)) }
                    : nil
                do {
                    try await enviar(conexao, atual)
                } catch {
                    // O VLC fechou — busca nova ou fim do vídeo. O bloco que
                    // vinha a caminho não serve mais a ninguém.
                    proximo?.cancel()
                    return
                }
                guard let proximo else { return }
                let bloco = try await proximo.value
                guard bloco.status == 206 else { return }
                atual = bloco.dados
                posicao = seguinte
            }
        } catch {
            LabLog.problem("ponte: \(error.localizedDescription)")
        }
    }

    /// Um arquivo da lista HLS, inteiro: a lista em texto ou um pedaço de
    /// poucos segundos de vídeo.
    private func repassar(_ conexao: NWConnection, _ destino: Destino, _ pedido: Pedido) async {
        do {
            guard let url = URL(string: pedido.resto, relativeTo: destino.url)?.absoluteURL else {
                try await enviarCabecalho(conexao, status: 404, campos: ["Content-Length": "0"])
                return
            }
            var requisicao = URLRequest(url: url)
            destino.cabecalhos.forEach { requisicao.setValue($1, forHTTPHeaderField: $0) }
            requisicao.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            // A conversão de um pedaço pode levar uns segundos no servidor.
            requisicao.timeoutInterval = 90
            let (dados, resposta) = try await sessao.data(for: requisicao)
            let http = resposta as? HTTPURLResponse
            var campos = ["Content-Length": "\(dados.count)"]
            if let tipo = http?.value(forHTTPHeaderField: "Content-Type") { campos["Content-Type"] = tipo }
            try await enviarCabecalho(conexao, status: http?.statusCode ?? 502, campos: campos)
            if pedido.metodo == "GET" { try await enviar(conexao, dados) }
        } catch {
            LabLog.problem("ponte (lista): \(error.localizedDescription)")
        }
    }

    private func limite(_ inicio: Int64, _ tamanho: Int64, _ fim: Int64?) -> Int64 {
        let ate = inicio + tamanho - 1
        guard let fim else { return ate }
        return min(ate, fim)
    }

    private func baixar(_ destino: Destino, de inicio: Int64, ate fim: Int64) async throws -> Bloco {
        var pedido = URLRequest(url: destino.url)
        destino.cabecalhos.forEach { pedido.setValue($1, forHTTPHeaderField: $0) }
        pedido.setValue("bytes=\(inicio)-\(fim)", forHTTPHeaderField: "Range")
        // Sem compressão: o tamanho anunciado tem que ser o dos bytes que vão.
        pedido.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (dados, resposta) = try await sessao.data(for: pedido)
        let http = resposta as? HTTPURLResponse
        // "bytes 0-524287/14329045": o total vem depois da barra.
        let total = (http?.value(forHTTPHeaderField: "Content-Range"))
            .flatMap { $0.split(separator: "/").last }
            .flatMap { Int64($0) }
        return Bloco(status: http?.statusCode ?? 502, dados: dados, total: total,
                     tipo: http?.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: - Fio com o VLC

    private func lerCabecalho(_ conexao: NWConnection) async -> String? {
        var lido = Data()
        while lido.count < 32 * 1024 {
            let pedaco: Data? = await withCheckedContinuation { continuacao in
                conexao.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { dados, _, _, erro in
                    continuacao.resume(returning: erro == nil ? dados : nil)
                }
            }
            guard let pedaco, !pedaco.isEmpty else { return nil }
            lido.append(pedaco)
            if let texto = String(data: lido, encoding: .utf8), texto.contains("\r\n\r\n") { return texto }
        }
        return nil
    }

    private func enviarCabecalho(_ conexao: NWConnection, status: Int, campos: [String: String]) async throws {
        // A frase depois do número é só enfeite; o VLC lê o número.
        var texto = "HTTP/1.1 \(status) \(status < 300 ? "OK" : "Error")\r\n"
        for (nome, valor) in campos { texto += "\(nome): \(valor)\r\n" }
        // Uma resposta por conexão: o VLC abre outra a cada busca.
        texto += "Connection: close\r\n\r\n"
        try await enviar(conexao, Data(texto.utf8))
    }

    /// Só volta quando a pilha de rede aceitou os bytes — é isto que segura o
    /// ritmo da leitura no ritmo do VLC.
    private func enviar(_ conexao: NWConnection, _ dados: Data) async throws {
        try await withCheckedThrowingContinuation { (continuacao: CheckedContinuation<Void, Error>) in
            conexao.send(content: dados, completion: .contentProcessed { erro in
                if let erro { continuacao.resume(throwing: erro) } else { continuacao.resume() }
            })
        }
    }
}

/// Uma resposta só para quem espera; as seguintes são ignoradas.
private final class RespostaDaPonte: @unchecked Sendable {
    private let trava = NSLock()
    private var continuacao: CheckedContinuation<Bool, Never>?

    init(_ c: CheckedContinuation<Bool, Never>) { continuacao = c }

    func dar(_ valor: Bool) {
        trava.lock()
        let c = continuacao
        continuacao = nil
        trava.unlock()
        c?.resume(returning: valor)
    }
}

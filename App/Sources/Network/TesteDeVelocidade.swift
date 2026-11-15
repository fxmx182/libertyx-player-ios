import Foundation
import Network
import UIKit

// MARK: - O que se mede

/// Um servidor da lista do teste de velocidade: os SMB e as contas HTTP
/// (WebDAV, Jellyfin, Emby) numa lista só.
struct AlvoDeTeste: Identifiable, Hashable {

    enum Origem: Hashable {
        case smb(SMBServer)
        case conta(ContaDeRede)
    }

    let origem: Origem

    var id: UUID {
        switch origem {
        case .smb(let s):   return s.id
        case .conta(let c): return c.id
        }
    }

    var nome: String {
        switch origem {
        case .smb(let s):   return s.name
        case .conta(let c): return c.nome
        }
    }

    var tipo: String {
        switch origem {
        case .smb:          return "SMB"
        case .conta(let c): return c.tipo.nome
        }
    }

    var endereco: String {
        switch origem {
        case .smb(let s):   return s.displayHost
        case .conta(let c): return c.enderecoCurto
        }
    }

    var simbolo: String {
        switch origem {
        case .smb:          return "server.rack"
        case .conta(let c): return c.tipo.simbolo
        }
    }

    var imagem: String? {
        switch origem {
        case .smb:          return "LogoSMB"
        case .conta(let c): return c.tipo.imagem
        }
    }

    /// Onde bater para medir a resposta: o mesmo servidor e a mesma porta que
    /// o player usa para tocar.
    var hostEPorta: (host: String, porta: Int)? {
        switch origem {
        case .smb(let s):
            return (s.host, s.port)
        case .conta(let c):
            guard let url = c.url, let host = url.host, !host.isEmpty else { return nil }
            return (host, url.port ?? (url.scheme == "https" ? 443 : 80))
        }
    }

    @MainActor static var todos: [AlvoDeTeste] {
        SMBServerStore.shared.servers.map { AlvoDeTeste(origem: .smb($0)) }
            + ContasDeRede.shared.contas.map { AlvoDeTeste(origem: .conta($0)) }
    }
}

// MARK: - Resultado

struct ResultadoDeVelocidade: Codable, Hashable {
    /// A banda sustentada, em megabits por segundo — a unidade da operadora e
    /// do roteador, para dar para comparar.
    var mbps: Double
    var pico: Double
    /// Ida e volta até o servidor, em milissegundos.
    var resposta: Double?
    /// Quanto a resposta varia de uma vez para outra. Variação alta é Wi-Fi
    /// disputado ou sinal fraco, mesmo com a banda boa.
    var variacao: Double?
    var ip: String?
    var interface: String?
    var megabytes: Double
    var segundos: Double
    var quando: Date
    /// A banda a cada instante, para o desenho da onda.
    var amostras: [Double]
    /// O que foi lido: o nome do arquivo ou o teste do próprio servidor.
    var lido: String?
    /// Quantas vezes a leitura caiu e foi refeita durante o teste.
    var tropecos: Int? = nil

    /// Endereço da rede de casa (ou de VPN) e não da internet.
    var naRedeDeCasa: Bool? {
        guard let ip else { return nil }
        return Self.ehLocal(ip)
    }

    static func ehLocal(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            switch (p[0], p[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            // Tailscale e afins: endereço de operadora, mas é a sua rede.
            case (100, 64...127): return true
            default: return false
            }
        }
        let v6 = ip.lowercased()
        return v6 == "::1" || v6.hasPrefix("fe80") || v6.hasPrefix("fd") || v6.hasPrefix("fc")
    }
}

/// O que dá para tocar com cada banda, com folga para os picos — um filme de
/// 40 Mb/s em média passa de 80 nas cenas de ação.
enum DegrauDeQualidade: CaseIterable, Identifiable {
    case sd, hd, fullHD, uhd, remux

    var id: Self { self }

    var nome: String {
        switch self {
        case .sd:     return "SD"
        case .hd:     return "720p"
        case .fullHD: return "1080p"
        case .uhd:    return "4K"
        case .remux:  return String(localized: "Remux 4K")
        }
    }

    var minimo: Double {
        switch self {
        case .sd:     return 4
        case .hd:     return 8
        case .fullHD: return 20
        case .uhd:    return 60
        case .remux:  return 130
        }
    }
}

enum NotaDeVelocidade {
    case voando, excelente, muitoBoa, boa, razoavel, fraca

    init(_ mbps: Double) {
        switch mbps {
        case 300...: self = .voando
        case 130...: self = .excelente
        case 60...:  self = .muitoBoa
        case 20...:  self = .boa
        case 8...:   self = .razoavel
        default:     self = .fraca
        }
    }

    var nome: String {
        switch self {
        case .voando:    return String(localized: "Voando")
        case .excelente: return String(localized: "Excelente")
        case .muitoBoa:  return String(localized: "Muito boa")
        case .boa:       return String(localized: "Boa")
        case .razoavel:  return String(localized: "Razoável")
        case .fraca:     return String(localized: "Fraca")
        }
    }

    var veredito: String {
        switch self {
        case .voando, .excelente:
            return String(localized: "Toca qualquer coisa com folga, até remux 4K.")
        case .muitoBoa:
            return String(localized: "Toca 4K. Um remux 4K pesado pode engasgar nos picos.")
        case .boa:
            return String(localized: "Toca 1080p com folga; 4K pode parar para carregar.")
        case .razoavel:
            return String(localized: "Toca 720p. Um 1080p de taxa alta pode parar para carregar.")
        case .fraca:
            return String(localized: "Lenta para vídeo. Chegue mais perto do roteador ou use a rede de 5 GHz.")
        }
    }
}

// MARK: - Teste

/// Mede cada servidor como o player o usa: primeiro a resposta (quanto
/// demora a ida e volta), depois a banda, lendo um arquivo de verdade por
/// alguns segundos — sem gravar nada no servidor.
@MainActor
final class TesteDeVelocidade: ObservableObject {

    static let shared = TesteDeVelocidade()

    enum Fase: Equatable {
        case parado
        case resposta
        case preparando
        case baixando
        case pronto
        case falhou
    }

    @Published private(set) var emTeste: UUID?
    @Published private(set) var fase: Fase = .parado
    /// A banda neste instante, em Mb/s.
    @Published private(set) var agora: Double = 0
    @Published private(set) var amostras: [Double] = []
    /// De 0 a 1, a parte da leitura já feita.
    @Published private(set) var progresso: Double = 0
    @Published private(set) var lendo: String?
    @Published private(set) var resposta: Double?
    @Published private(set) var resultados: [UUID: ResultadoDeVelocidade] = [:]
    @Published private(set) var falhas: [UUID: String] = [:]
    /// Os que ainda vão ser medidos no "Testar todos".
    @Published private(set) var fila: [UUID] = []
    /// O último medido, que o velocímetro mostra quando nada está rodando.
    @Published private(set) var ultimo: UUID?

    /// Quanto dura a leitura. Curto demais e o Wi-Fi não chega a acelerar;
    /// longo demais e ninguém espera o "Testar todos" acabar.
    nonisolated static let duracao: Double = 8

    private var tarefa: Task<Void, Never>?
    private let chave = "libertyx.velocidades"

    init() {
        if let dados = UserDefaults.standard.data(forKey: chave),
           let lidos = try? JSONDecoder().decode([String: ResultadoDeVelocidade].self, from: dados) {
            resultados = Dictionary(uniqueKeysWithValues: lidos.compactMap { chave, valor in
                UUID(uuidString: chave).map { ($0, valor) }
            })
            ultimo = resultados.max { $0.value.quando < $1.value.quando }?.key
        }
    }

    var rodando: Bool { emTeste != nil || !fila.isEmpty }

    func testar(_ alvos: [AlvoDeTeste]) {
        cancelar()
        guard !alvos.isEmpty else { return }
        fila = alvos.map(\.id)
        tarefa = Task { [weak self] in
            for alvo in alvos {
                guard let self, !Task.isCancelled else { return }
                self.fila.removeAll { $0 == alvo.id }
                await self.medir(alvo)
            }
            guard let self, !Task.isCancelled else { return }
            self.emTeste = nil
            self.fila = []
        }
    }

    func cancelar() {
        tarefa?.cancel()
        tarefa = nil
        fila = []
        if emTeste != nil {
            emTeste = nil
            fase = .parado
            agora = 0
        }
    }

    private func medir(_ alvo: AlvoDeTeste) async {
        emTeste = alvo.id
        ultimo = alvo.id
        falhas[alvo.id] = nil
        agora = 0
        amostras = []
        progresso = 0
        lendo = nil
        resposta = nil
        fase = .resposta

        guard let destino = alvo.hostEPorta else {
            falhar(alvo, String(localized: "Endereço inválido."))
            return
        }
        let medida = await Resposta.medir(host: destino.host, porta: destino.porta)
        if Task.isCancelled { return }
        guard let medida else {
            falhar(alvo, String(localized: "O servidor não respondeu. Ele está ligado e na mesma rede?"))
            return
        }
        resposta = medida.mediana

        fase = .preparando
        let fonte = fonte(de: alvo)
        let contador = Contador()
        let leitura = Task.detached(priority: .userInitiated) {
            do { try await fonte.ler(contador) } catch { contador.erro = error }
            contador.terminou = true
        }

        let comeco = Self.relogio
        var inicio: (t: Double, b: Int64)?
        var marco: (t: Double, b: Int64)?
        var depoisDoMarco = 0
        var chegadas: [(t: Double, b: Int64)] = []
        var ultima: (t: Double, b: Int64) = (comeco, 0)

        while true {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled {
                contador.parar = true
                leitura.cancel()
                return
            }
            let t = Self.relogio
            let chegada = contador.chegada
            if lendo == nil, let arquivo = contador.arquivo { lendo = arquivo }

            guard let primeira = inicio else {
                if chegada.b > 0 {
                    inicio = chegada
                    ultima = chegada
                    chegadas = [chegada]
                    fase = .baixando
                } else if contador.terminou || t - comeco > 30 {
                    break
                }
                continue
            }

            if chegada.b > ultima.b {
                ultima = chegada
                chegadas.append(chegada)
                // O primeiro segundo fica de fora da média: é a conexão
                // acelerando, não a banda do servidor.
                if marco == nil, chegada.t - primeira.t >= 1 {
                    marco = chegada
                } else if marco != nil {
                    depoisDoMarco += 1
                }
            }
            // Contado entre chegadas, e não pela hora da amostra: o SMB
            // entrega em blocos de até 8 MB, e medir pelo relógio fazia o
            // número pular entre zero e o dobro.
            let referencia = Self.partida(marco: marco, depoisDoMarco: depoisDoMarco,
                                          inicio: contador.inicioDaLeitura ?? (primeira.t - 0.2))
            if ultima.t > referencia.t {
                agora = Double(ultima.b - referencia.b) * 8 / 1_000_000 / (ultima.t - referencia.t)
            }
            // A onda: a banda em janelas de um segundo e meio.
            while chegadas.count > 2, ultima.t - chegadas[0].t > 1.5 { chegadas.removeFirst() }
            if let velha = chegadas.first, ultima.t > velha.t {
                amostras.append(Double(ultima.b - velha.b) * 8 / 1_000_000 / (ultima.t - velha.t))
            }
            progresso = min(1, (t - primeira.t) / Self.duracao)
            if t - primeira.t >= Self.duracao || contador.terminou { break }
        }
        contador.parar = true
        leitura.cancel()

        let partida = Self.partida(marco: marco, depoisDoMarco: depoisDoMarco,
                                   inicio: contador.inicioDaLeitura ?? ((inicio?.t ?? comeco) - 0.2))
        // Chegou alguma coisa e depois nada: o servidor parou no meio. Mostrar
        // "0 Mb/s" como se fosse a banda enganaria.
        guard let primeira = inicio, ultima.b > partida.b, ultima.t > partida.t else {
            let motivo = (contador.erro as? LocalizedError)?.errorDescription
                ?? contador.erro.map { String(localized: "A leitura falhou: \($0.localizedDescription)") }
                ?? (inicio == nil && contador.arquivo != nil
                    // Achou o arquivo e nenhum bloco chegou em 30 s: a conexão
                    // está viva, só que lenta demais (um bloco de SMB tem 8 MB).
                    ? String(localized: "Lenta demais para medir: menos de 4 Mb/s, pouco para vídeo.")
                    : inicio == nil ? String(localized: "O servidor não mandou nada a tempo.")
                                  : String(localized: "O servidor parou de responder no meio da leitura."))
            falhar(alvo, motivo)
            return
        }

        let mbps = Double(ultima.b - partida.b) * 8 / 1_000_000 / (ultima.t - partida.t)
        let resultado = ResultadoDeVelocidade(
            mbps: mbps,
            pico: max(mbps, amostras.max() ?? 0),
            resposta: medida.mediana,
            variacao: medida.variacao,
            ip: medida.ip,
            interface: medida.interface,
            megabytes: Double(ultima.b) / 1_000_000,
            segundos: ultima.t - primeira.t,
            quando: Date(),
            amostras: Self.resumir(amostras, em: 48),
            lido: contador.arquivo,
            tropecos: contador.tropecos)
        resultados[alvo.id] = resultado
        agora = mbps
        progresso = 1
        fase = .pronto
        emTeste = nil
        guardar()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        LabLog.passo("velocidade: \(alvo.tipo) \(alvo.endereco) → \(Int(mbps.rounded())) Mb/s, resposta \(String(format: "%.1f", medida.mediana)) ms, \(String(format: "%.0f", resultado.megabytes)) MB")
    }

    private func falhar(_ alvo: AlvoDeTeste, _ motivo: String) {
        falhas[alvo.id] = motivo
        fase = .falhou
        agora = 0
        emTeste = nil
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        LabLog.passo("velocidade: \(alvo.tipo) \(alvo.endereco) falhou: \(motivo)")
    }

    private func fonte(de alvo: AlvoDeTeste) -> FonteDeLeitura {
        switch alvo.origem {
        case .smb(let s):
            return .smb(s, senha: SMBServerStore.shared.password(for: s))
        case .conta(let c):
            let segredo = ContasDeRede.shared.segredo(c)
            return c.tipo == .webdav ? .webdav(c, senha: segredo) : .midia(c, token: segredo)
        }
    }

    private func guardar() {
        let porTexto = Dictionary(uniqueKeysWithValues: resultados.map { ($0.key.uuidString, $0.value) })
        guard let dados = try? JSONEncoder().encode(porTexto) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
    }

    private static var relogio: Double { ProcessInfo.processInfo.systemUptime }

    /// De onde contar a banda.
    ///
    /// Com muitos pedaços chegando (HTTP, que entrega aos poucos), conta-se
    /// a partir de um segundo depois do primeiro: o começo é a conexão
    /// acelerando. Com poucos (o SMB entrega blocos de até 8 MB, e numa rede
    /// lenta chegam cinco ou seis em todo o teste), conta-se desde o pedido:
    /// o primeiro bloco também estava vindo enquanto ninguém o via chegar,
    /// e deixá-lo de fora inflava o número em um quarto.
    private static func partida(marco: (t: Double, b: Int64)?, depoisDoMarco: Int,
                                inicio: Double) -> (t: Double, b: Int64) {
        if let marco, depoisDoMarco >= 8 { return marco }
        return (inicio, 0)
    }

    /// A onda guardada com poucos pontos: é só para o desenho.
    private static func resumir(_ valores: [Double], em pontos: Int) -> [Double] {
        guard valores.count > pontos else { return valores }
        let passo = Double(valores.count) / Double(pontos)
        return (0..<pontos).map { i in
            let de = Int(Double(i) * passo)
            let ate = max(de + 1, Int(Double(i + 1) * passo))
            let fatia = valores[de..<min(ate, valores.count)]
            return fatia.reduce(0, +) / Double(fatia.count)
        }
    }
}

// MARK: - Resposta

/// A ida e volta até o servidor, medida abrindo a conexão TCP na porta que o
/// player usa. É o mesmo aperto de mão de toda abertura de vídeo e de toda
/// busca — e não depende de o servidor ter um "ping".
enum Resposta {

    struct Medida {
        let mediana: Double
        let variacao: Double
        let ip: String?
        let interface: String?
    }

    static func medir(host: String, porta: Int, vezes: Int = 7) async -> Medida? {
        var tempos: [Double] = []
        var ip: String?
        var interface: String?
        for _ in 0..<vezes {
            if Task.isCancelled { return nil }
            guard let uma = await umaConexao(host: host, porta: porta) else { continue }
            tempos.append(uma.ms)
            ip = ip ?? uma.ip
            interface = interface ?? uma.interface
        }
        guard !tempos.isEmpty else { return nil }
        // A primeira inclui achar o nome do servidor; a mediana a descarta.
        let ordenados = tempos.sorted()
        let mediana = ordenados[ordenados.count / 2]
        let saltos = zip(tempos, tempos.dropFirst()).map { abs($0 - $1) }
        let variacao = saltos.isEmpty ? 0 : saltos.reduce(0, +) / Double(saltos.count)
        return Medida(mediana: mediana, variacao: variacao, ip: ip, interface: interface)
    }

    private static let fila = DispatchQueue(label: "com.mauricio.libertyx.resposta")

    private static func umaConexao(host: String, porta: Int) async -> (ms: Double, ip: String?, interface: String?)? {
        guard let numero = NWEndpoint.Port(rawValue: UInt16(clamping: porta)) else { return nil }
        let conexao = NWConnection(host: NWEndpoint.Host(host), port: numero, using: .tcp)
        return await withCheckedContinuation { continuacao in
            let uma = UmaVez()
            let inicio = DispatchTime.now().uptimeNanoseconds
            conexao.stateUpdateHandler = { estado in
                switch estado {
                case .ready:
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1_000_000
                    var ip: String?
                    if case .hostPort(let remoto, _)? = conexao.currentPath?.remoteEndpoint {
                        ip = Resposta.texto(remoto)
                    }
                    let interface = conexao.currentPath.flatMap(Resposta.nomeDaInterface)
                    conexao.cancel()
                    uma.fazer { continuacao.resume(returning: (ms, ip, interface)) }
                case .failed, .waiting:
                    conexao.cancel()
                    uma.fazer { continuacao.resume(returning: nil) }
                default:
                    break
                }
            }
            conexao.start(queue: fila)
            fila.asyncAfter(deadline: .now() + 3) {
                conexao.cancel()
                uma.fazer { continuacao.resume(returning: nil) }
            }
        }
    }

    private static func texto(_ host: NWEndpoint.Host) -> String {
        let bruto: String
        switch host {
        case .ipv4(let a):       bruto = "\(a)"
        case .ipv6(let a):       bruto = "\(a)"
        case .name(let n, _):    bruto = n
        @unknown default:        bruto = "\(host)"
        }
        // O IPv6 de rede local vem com a interface no fim ("%en0").
        return bruto.split(separator: "%").first.map(String.init) ?? bruto
    }

    private static func nomeDaInterface(_ caminho: NWPath) -> String? {
        if caminho.usesInterfaceType(.wifi) { return String(localized: "Wi-Fi") }
        if caminho.usesInterfaceType(.wiredEthernet) { return String(localized: "Cabo") }
        if caminho.usesInterfaceType(.cellular) { return String(localized: "Rede celular") }
        return nil
    }
}

/// Garante que a continuação seja retomada uma vez só — a conexão pode ficar
/// pronta, falhar e estourar o prazo quase ao mesmo tempo.
private final class UmaVez: @unchecked Sendable {
    private let trava = NSLock()
    private var feito = false

    func fazer(_ acao: () -> Void) {
        trava.lock()
        let primeira = !feito
        feito = true
        trava.unlock()
        if primeira { acao() }
    }
}

// MARK: - Leitura

/// Os bytes que chegaram, contados por quem lê e lidos por quem mede.
final class Contador: @unchecked Sendable {
    private let trava = NSLock()
    private var _bytes: Int64 = 0
    private var _chegada: (t: Double, b: Int64) = (0, 0)
    private var _parar = false
    private var _terminou = false
    private var _arquivo: String?
    private var _erro: Error?
    private var _tropecos = 0

    var bytes: Int64 { trava.withLock { _bytes } }

    func somar(_ n: Int) {
        let agora = ProcessInfo.processInfo.systemUptime
        trava.withLock {
            _bytes += Int64(n)
            _chegada = (agora, _bytes)
        }
    }

    private var _inicioDaLeitura: Double?

    /// Quando os pedidos de leitura começaram (depois de achar o arquivo).
    var inicioDaLeitura: Double? { trava.withLock { _inicioDaLeitura } }
    func marcarInicio() {
        let agora = ProcessInfo.processInfo.systemUptime
        trava.withLock { if _inicioDaLeitura == nil { _inicioDaLeitura = agora } }
    }

    /// Quando chegou o último pedaço, e o total até ali.
    var chegada: (t: Double, b: Int64) { trava.withLock { _chegada } }

    var parar: Bool {
        get { trava.withLock { _parar } }
        set { trava.withLock { _parar = newValue } }
    }

    var terminou: Bool {
        get { trava.withLock { _terminou } }
        set { trava.withLock { _terminou = newValue } }
    }

    var arquivo: String? {
        get { trava.withLock { _arquivo } }
        set { trava.withLock { _arquivo = newValue } }
    }

    /// Quantas vezes uma leitura caiu e recomeçou.
    var tropecos: Int { trava.withLock { _tropecos } }
    func tropecar() { trava.withLock { _tropecos += 1 } }

    var erro: Error? {
        get { trava.withLock { _erro } }
        set { trava.withLock { _erro = newValue } }
    }
}

struct ErroDoTeste: LocalizedError {
    let mensagem: String
    var errorDescription: String? { mensagem }

    static let semArquivo = ErroDoTeste(mensagem: String(localized: "Não achei um arquivo grande o bastante para medir. O teste precisa de um vídeo de pelo menos 16 MB no servidor."))
}

/// Uma leitura que travou ou caiu: a conexão é refeita e o teste segue.
struct Queda: LocalizedError {
    var errorDescription: String? { String(localized: "O servidor parou de responder no meio da leitura.") }
}

/// De onde vêm os bytes de cada tipo de servidor.
///
/// Sempre duas leituras ao mesmo tempo, como os testes de velocidade
/// conhecidos: uma só deixa a conexão parada a cada ida e volta, e o número
/// sai mais baixo e mais instável do que a rede é — sobretudo pela internet.
enum FonteDeLeitura {
    case smb(SMBServer, senha: String?)
    case webdav(ContaDeRede, senha: String?)
    case midia(ContaDeRede, token: String?)

    /// Abaixo disto o arquivo acaba antes de o teste terminar.
    private static let minimo: UInt64 = 16 << 20
    /// Achou um desse tamanho, para de procurar.
    private static let bastante: UInt64 = 300 << 20
    private static let leiturasJuntas = 2
    /// Quantas vezes uma leitura pode cair e recomeçar antes de o teste desistir.
    private static let tropecosPermitidos = 4

    /// Lê até o contador mandar parar.
    func ler(_ contador: Contador) async throws {
        switch self {
        case .smb(let servidor, let senha):
            try await LeituraSMB.ler(LeituraSMB.Destino(host: servidor.host, porta: servidor.port,
                                                        usuario: servidor.isGuest ? nil : servidor.username,
                                                        senha: senha), contador)
        case .webdav(let conta, let senha):  try await Self.lerWebDAV(conta, senha: senha, contador)
        case .midia(let conta, let token):   try await Self.lerMidia(conta, token: token, contador)
        }
    }

    /// Roda as leituras juntas e só falha se todas desistirem sem ler nada.
    private static func juntas(_ contador: Contador,
                               _ leitura: @escaping @Sendable (Int) async throws -> Void) async throws {
        var ultimoErro: Error?
        contador.marcarInicio()
        await withTaskGroup(of: Error?.self) { grupo in
            for k in 0..<leiturasJuntas {
                grupo.addTask {
                    do { try await leitura(k); return nil } catch { return error }
                }
            }
            for await erro in grupo { if let erro { ultimoErro = erro } }
        }
        if let ultimoErro, contador.bytes == 0 { throw ultimoErro }
    }

    /// Repete a leitura quando ela cai no meio: a queda entra no resultado
    /// ("parou 2 vezes"), mas não joga fora o que já foi medido.
    private static func insistindo(_ contador: Contador, _ passo: () async throws -> Void) async throws {
        var quedas = 0
        while !contador.parar && !Task.isCancelled {
            do {
                try await passo()
            } catch {
                if contador.parar || Task.isCancelled { return }
                if error is LeituraHTTP.Recusado || error is ErroDeServidor || error is ErroDoTeste { throw error }
                quedas += 1
                contador.tropecar()
                if quedas > tropecosPermitidos { throw error }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    // MARK: WebDAV

    private static func lerWebDAV(_ conta: ContaDeRede, senha: String?, _ contador: Contador) async throws {
        let dav = WebDAV(conta: conta, senha: senha)
        let prazo = Date().addingTimeInterval(10)
        var fila = [dav.raiz]
        var listadas = 0
        var melhor: WebDAV.Entrada?
        while !fila.isEmpty, listadas < 30, Date() < prazo {
            if Task.isCancelled { return }
            let atual = fila.removeFirst()
            listadas += 1
            let itens: [WebDAV.Entrada]
            do {
                itens = try await dav.listar(atual)
            } catch {
                // Senha errada ou endereço que não é WebDAV aparece já na
                // primeira pasta, e é isso que a pessoa precisa saber.
                if listadas == 1 { throw error }
                continue
            }
            for item in itens {
                if item.ehPasta {
                    fila.append(item.caminho)
                } else if (item.tamanho ?? 0) > (melhor?.tamanho ?? 0) {
                    melhor = item
                }
            }
            if let m = melhor, UInt64(m.tamanho ?? 0) >= bastante { break }
        }
        guard let arquivo = melhor, let tamanho = arquivo.tamanho, UInt64(tamanho) >= minimo else {
            throw ErroDoTeste.semArquivo
        }
        contador.arquivo = arquivo.nome
        // Cada leitura a partir de um ponto diferente; a segunda, do meio.
        // Ponto fixo, e não sorteado: com a criptografia do Nextcloud ligada,
        // começar no meio de um bloco faz o servidor decifrar antes de mandar.
        try await Self.juntas(contador) { k in
            let desde = k == 0 ? 0 : (tamanho / 2) - (tamanho / 2) % (1 << 20)
            try await Self.insistindo(contador) {
                guard let pedido = dav.pedidoDeLeitura(arquivo.caminho, desde: desde) else {
                    throw ErroDoTeste(mensagem: String(localized: "Endereço inválido."))
                }
                try await LeituraHTTP.baixar(pedido, contador)
            }
        }
    }

    // MARK: Jellyfin e Emby

    /// O teste de banda do próprio servidor (o que os apps oficiais usam para
    /// escolher a qualidade); se ele não existir, o arquivo de um vídeo.
    private static func lerMidia(_ conta: ContaDeRede, token: String?, _ contador: Contador) async throws {
        let servidor = ServidorDeMidia(conta: conta, token: token)
        if let pedido = servidor.pedidoDoTesteDeBanda(bytes: 50_000_000) {
            do {
                contador.arquivo = String(localized: "teste de banda do servidor")
                try await Self.juntas(contador) { _ in
                    try await Self.insistindo(contador) { try await LeituraHTTP.baixar(pedido, contador) }
                }
                return
            } catch let recusa as LeituraHTTP.Recusado where contador.bytes == 0 {
                if recusa.codigo == 401 || recusa.codigo == 403 { throw ErroDeServidor.http(recusa.codigo) }
                // Servidor sem o teste: segue para o vídeo.
            }
        }
        guard let item = try await servidor.videoParaTeste(),
              let url = servidor.urlDoVideo(item.id) else { throw ErroDoTeste.semArquivo }
        contador.arquivo = item.nome
        let cabecalhos = servidor.cabecalhoDoToken
        try await Self.juntas(contador) { _ in
            try await Self.insistindo(contador) {
                var pedido = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                for (campo, valor) in cabecalhos { pedido.setValue(valor, forHTTPHeaderField: campo) }
                try await LeituraHTTP.baixar(pedido, contador)
            }
        }
    }
}

/// Um download HTTP que só conta os bytes, sem guardá-los.
///
/// Pelo delegate e não por `bytes(for:)`: percorrer byte a byte custa mais
/// processador do que a rede de casa entrega, e o teste mediria o iPhone.
final class LeituraHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    struct Recusado: LocalizedError {
        let codigo: Int
        var errorDescription: String? { ErroDeServidor.http(codigo).errorDescription }
    }

    private let contador: Contador
    private let trava = NSLock()
    private var continuacao: CheckedContinuation<Void, Error>?

    private init(contador: Contador) {
        self.contador = contador
    }

    static func baixar(_ pedido: URLRequest, _ contador: Contador) async throws {
        let leitura = LeituraHTTP(contador: contador)
        let configuracao = URLSessionConfiguration.ephemeral
        configuracao.urlCache = nil
        configuracao.requestCachePolicy = .reloadIgnoringLocalCacheData
        let fila = OperationQueue()
        fila.maxConcurrentOperationCount = 1
        let sessao = URLSession(configuration: configuracao, delegate: leitura, delegateQueue: fila)
        defer { sessao.invalidateAndCancel() }
        let tarefa = sessao.dataTask(with: pedido)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                leitura.trava.withLock { leitura.continuacao = c }
                tarefa.resume()
            }
        } onCancel: {
            tarefa.cancel()
        }
    }

    private func terminar(_ erro: Error?) {
        let c: CheckedContinuation<Void, Error>? = trava.withLock {
            let atual = continuacao
            continuacao = nil
            return atual
        }
        if let erro { c?.resume(throwing: erro) } else { c?.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let codigo = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(codigo) else {
            completionHandler(.cancel)
            terminar(Recusado(codigo: codigo))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        contador.somar(data.count)
        if contador.parar { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code == .cancelled {
            // Cancelado por nós (o tempo acabou): não é falha.
            terminar(contador.parar ? nil : CancellationError())
        } else {
            terminar(error)
        }
    }
}

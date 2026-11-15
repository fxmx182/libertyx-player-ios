import Foundation
import AMSMB2

/// A leitura do SMB no teste de velocidade, pelo libsmb2 (via AMSMB2).
///
/// O libsmb2 é o mesmo motor de SMB que o VLC usa para tocar: o número que
/// sai daqui é o que o player vai ter. O `SMBClient` em Swift puro, que a
/// navegação usa, travava no meio das leituras grandes na rede local —
/// parava de receber e nunca mais voltava.
enum LeituraSMB {

    struct Destino: Sendable {
        let host: String
        let porta: Int
        /// `nil` entra como convidado.
        let usuario: String?
        let senha: String?
    }

    /// Duas conexões ao mesmo tempo, cada uma lendo o seu trecho.
    static let juntas = 2
    /// Quantas vezes uma conexão pode cair e ser refeita antes de desistir.
    static let quedasPermitidas = 4
    /// Abaixo disto o arquivo acaba antes de o teste terminar.
    static let minimo: Int64 = 16 << 20
    /// Achou um desse tamanho, para de procurar.
    static let bastante: Int64 = 300 << 20

    struct Achado: Sendable {
        let pasta: String
        let caminho: String
        let tamanho: Int64
        var nome: String { (caminho as NSString).lastPathComponent }
    }

    /// Lê até o contador mandar parar.
    static func ler(_ destino: Destino, _ contador: Contador) async throws {
        let procura = try gerente(destino)
        let achado: Achado?
        do {
            achado = try await arquivo(procura)
        } catch {
            try? await procura.disconnectShare()
            throw explicar(error, destino)
        }
        try? await procura.disconnectShare()
        guard let achado else { throw ErroDoTeste.semArquivo }
        contador.arquivo = achado.nome

        // De um ponto da primeira metade: o começo de todo arquivo costuma
        // estar no cache do servidor, e o meio não. A segunda conexão lê
        // meio arquivo adiante.
        let mega: Int64 = 1 << 20
        var partida = Int64.random(in: 0...(achado.tamanho / 2))
        partida -= partida % mega
        let metade = (achado.tamanho / 2) - (achado.tamanho / 2) % mega

        var ultimoErro: (any Error)?
        contador.marcarInicio()
        await withTaskGroup(of: (any Error)?.self) { grupo in
            for k in 0..<juntas {
                let desde = k == 0 ? partida : (partida + metade) % achado.tamanho
                grupo.addTask {
                    do {
                        try await LeituraSMB.lerUma(destino, achado, desde: desde, contador)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            for await erro in grupo {
                if let erro { ultimoErro = erro }
            }
        }
        if let ultimoErro, contador.bytes == 0 { throw explicar(ultimoErro, destino) }
    }

    /// O libsmb2 responde com códigos do sistema ("Operation not permitted");
    /// aqui viram o que a pessoa precisa saber.
    static func explicar(_ erro: any Error, _ destino: Destino) -> any Error {
        let codigo = erro as NSError
        guard codigo.domain == NSPOSIXErrorDomain else { return erro }
        switch Int32(codigo.code) {
        case EPERM, EACCES:
            // O libsmb2 não entra como convidado em todo servidor (o Samba
            // recusa), mesmo onde a navegação entra.
            return destino.usuario == nil
                ? ErroDoTeste(mensagem: String(localized: "O teste de velocidade não consegue entrar como convidado neste servidor. Cadastre-o com usuário e senha para medir."))
                : ErroDoTeste(mensagem: String(localized: "Usuário ou senha recusados pelo servidor."))
        case ETIMEDOUT:
            return ErroDoTeste(mensagem: String(localized: "O servidor não mandou nada a tempo."))
        case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH:
            return ErroDoTeste(mensagem: String(localized: "O servidor não respondeu. Ele está ligado e na mesma rede?"))
        default:
            return erro
        }
    }

    static func gerente(_ destino: Destino) throws -> SMB2Manager {
        let host = destino.host.contains(":") ? "[\(destino.host)]" : destino.host
        var texto = "smb://\(host)"
        if destino.porta != 445 { texto += ":\(destino.porta)" }
        let credencial = destino.usuario.map {
            URLCredential(user: $0, password: destino.senha ?? "", persistence: .forSession)
        }
        guard let url = URL(string: texto),
              let smb = SMB2Manager(url: url, credential: credencial) else {
            throw ErroDoTeste(mensagem: String(localized: "Endereço inválido."))
        }
        // O prazo fica no padrão da biblioteca (60 s), de propósito: o SMB
        // pede blocos de até 8 MB, que numa rede lenta levam mais de 10 s, e
        // um prazo curto estourava no meio do bloco — a resposta atrasada
        // chegava depois e derrubava o app (defeito do AMSMB2 4.0.3, visto
        // num teste com a rede limitada a 10 Mb/s).
        return smb
    }

    /// Uma conexão lendo em sequência, como o player lê, até mandarem parar.
    /// Caiu, abre outra e continua de onde estava.
    private static func lerUma(_ destino: Destino, _ achado: Achado, desde inicio: Int64,
                               _ contador: Contador) async throws {
        var posicao = inicio
        var quedas = 0
        while !contador.parar && !Task.isCancelled {
            let smb = try gerente(destino)
            do {
                try await smb.connectShare(name: achado.pasta)
                posicao = try await lerAteParar(smb, achado.caminho, desde: posicao, contador)
                // Chegou ao fim do arquivo: volta ao começo.
                if posicao >= achado.tamanho { posicao = 0 }
                try? await smb.disconnectShare()
            } catch {
                try? await smb.disconnectShare()
                if contador.parar || Task.isCancelled { return }
                quedas += 1
                contador.tropecar()
                if quedas > quedasPermitidas { throw error }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Devolve até onde leu.
    private static func lerAteParar(_ smb: SMB2Manager, _ caminho: String, desde: Int64,
                                    _ contador: Contador) async throws -> Int64 {
        let posicao = Posicao(desde)
        try await withCheckedThrowingContinuation { (continuacao: CheckedContinuation<Void, any Error>) in
            smb.contents(atPath: caminho, offset: desde, fetchedData: { offset, _, dados in
                contador.somar(dados.count)
                posicao.valor = offset + Int64(dados.count)
                return !contador.parar
            }, completionHandler: { erro in
                if let erro { continuacao.resume(throwing: erro) } else { continuacao.resume() }
            })
        }
        return posicao.valor
    }

    /// O maior arquivo que aparecer numa olhada rápida pelas pastas — de
    /// cima para baixo, até achar um grande ou o tempo acabar.
    static func arquivo(_ smb: SMB2Manager) async throws -> Achado? {
        let pastas = try await smb.listShares()
            .map(\.name)
            .filter { !$0.hasSuffix("$") }
        let prazo = Date().addingTimeInterval(10)
        var melhor: Achado?

        procura: for pasta in pastas {
            do { try await smb.connectShare(name: pasta) } catch { continue }
            var fila = [""]
            var listadas = 0
            while !fila.isEmpty, listadas < 40, Date() < prazo {
                if Task.isCancelled { return nil }
                let atual = fila.removeFirst()
                listadas += 1
                guard let itens = try? await smb.contentsOfDirectory(atPath: atual) else { continue }
                for item in itens {
                    guard let nome = item[.nameKey] as? String,
                          nome != ".", nome != "..", !nome.hasPrefix(".") else { continue }
                    let caminho = atual.isEmpty ? nome : "\(atual)/\(nome)"
                    let pastaDentro = (item[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
                    if pastaDentro {
                        fila.append(caminho)
                        continue
                    }
                    let tamanho = (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                    if tamanho > (melhor?.tamanho ?? 0) {
                        melhor = Achado(pasta: pasta, caminho: caminho, tamanho: tamanho)
                    }
                }
                if let m = melhor, m.tamanho >= bastante { break procura }
            }
            if Date() >= prazo { break }
        }
        guard let m = melhor, m.tamanho >= minimo else { return nil }
        return m
    }
}

/// Até onde a leitura chegou, escrito na fila do libsmb2 e lido aqui.
private final class Posicao: @unchecked Sendable {
    private let trava = NSLock()
    private var _valor: Int64

    init(_ valor: Int64) { _valor = valor }

    var valor: Int64 {
        get { trava.lock(); defer { trava.unlock() }; return _valor }
        set { trava.lock(); _valor = newValue; trava.unlock() }
    }
}

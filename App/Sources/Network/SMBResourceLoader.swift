import AVFoundation
import SMBClient
import UniformTypeIdentifiers

/// Faz o AVPlayer tocar um arquivo que está no servidor SMB.
///
/// O AVFoundation não fala SMB e nunca vai falar. Mas ele aceita ser
/// alimentado: dando a ele uma URL com um esquema que o sistema desconhece,
/// em vez de recusar ele pergunta a nós o que fazer. A partir daí somos o
/// fornecedor de bytes dele — ele pede trechos, nós lemos do servidor e
/// devolvemos.
///
/// O que isso muda: os vídeos do servidor que a Apple sabe decodificar passam
/// a ganhar tudo o que só existia nos arquivos do celular — busca exata,
/// janela flutuante, miniatura pelo gerador dela. O que isso **não** muda:
/// formato. MKV continua fora, porque o problema nunca foi de onde vinham os
/// bytes.
final class SMBResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    /// Esquema inventado de propósito. Se fosse `http` ou `file`, o iOS
    /// atenderia sozinho e nunca nos perguntaria nada.
    static let scheme = "labsmb"

    private let connection: SMBConnection
    private let share: String
    private let path: String
    private let contentType: String

    private var reader: FileReader?
    private var size: UInt64 = 0

    /// Uma tarefa por pedido, para poder cancelar. O AVPlayer cancela muito —
    /// é o que ele faz a cada busca, e insistir num pedido morto significa
    /// gastar rede com bytes que ninguém mais quer.
    private var tarefas: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let trava = NSLock()

    init?(share: String, path: String, server: SMBServer, password: String?) {
        guard let tipo = Self.uti(for: path) else { return nil }
        self.connection = SMBConnection(server: server, password: password)
        self.share = share
        self.path = path
        self.contentType = tipo
        super.init()
    }

    /// A URL a entregar ao `AVURLAsset`.
    func makeURL() -> URL? {
        var componentes = URLComponents()
        componentes.scheme = Self.scheme
        componentes.host = "servidor"
        componentes.path = "/" + share + "/" + path
        return componentes.url
    }

    /// Só os contêineres que o AVFoundation abre.
    ///
    /// Devolver `nil` aqui é o que faz o `HybridEngine` nem tentar: um MKV
    /// atravessaria toda a ponte de leitura para ser recusado no fim, com o
    /// custo de uma conexão e a espera correspondente.
    static func uti(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4":  return UTType.mpeg4Movie.identifier
        case "m4v":  return "com.apple.m4v-video"
        case "mov":  return UTType.quickTimeMovie.identifier
        default:     return nil
        }
    }

    static func canHandle(path: String) -> Bool { uti(for: path) != nil }

    // MARK: - Delegado

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource
                        loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let chave = ObjectIdentifier(loadingRequest)
        let tarefa = Task { [weak self] in
            await self?.atender(loadingRequest)
            self?.esquecer(chave)
        }
        trava.lock()
        tarefas[chave] = tarefa
        trava.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let chave = ObjectIdentifier(loadingRequest)
        trava.lock()
        tarefas[chave]?.cancel()
        tarefas[chave] = nil
        trava.unlock()
    }

    private func esquecer(_ chave: ObjectIdentifier) {
        trava.lock()
        tarefas[chave] = nil
        trava.unlock()
    }

    // MARK: - Atendimento

    private func atender(_ pedido: AVAssetResourceLoadingRequest) async {
        do {
            let leitor = try await abrir()

            // O AVPlayer sempre pergunta primeiro o que é o arquivo. Sem
            // tamanho e sem aviso de que aceitamos trechos, ele desiste de
            // buscar e passa a tratar tudo como transmissão ao vivo.
            if let informacao = pedido.contentInformationRequest {
                informacao.contentType = contentType
                informacao.contentLength = Int64(size)
                informacao.isByteRangeAccessSupported = true
            }

            guard let dados = pedido.dataRequest else {
                pedido.finishLoading()
                return
            }

            let inicio = dados.requestedOffset + Int64(dados.currentOffset - dados.requestedOffset)
            let restante = Int64(dados.requestedLength) - (inicio - dados.requestedOffset)
            guard restante > 0, inicio < Int64(size) else {
                pedido.finishLoading()
                return
            }

            let quanto = min(restante, Int64(size) - inicio)
            let trecho = try await leitor.read(offset: UInt64(inicio), length: Int(quanto))
            guard !Task.isCancelled else { return }

            dados.respond(with: trecho)
            pedido.finishLoading()

        } catch {
            guard !Task.isCancelled else { return }
            LabLog.problem("SMB pelo AVPlayer falhou: \(error)")
            pedido.finishLoading(with: error)
        }
    }

    /// Uma conexão por reprodução, reaproveitada em todos os pedidos.
    private func abrir() async throws -> FileReader {
        if let reader { return reader }
        let (leitor, tamanho) = try await connection.fileReader(share: share, path: path)
        reader = leitor
        size = tamanho
        return leitor
    }

    func teardown() {
        trava.lock()
        tarefas.values.forEach { $0.cancel() }
        tarefas.removeAll()
        trava.unlock()
        let conexao = connection
        Task { await conexao.disconnect() }
    }
}

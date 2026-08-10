import Foundation
import SMBClient

/// Roda trabalho bloqueante do FFmpeg fora do pool cooperativo do Swift.
///
/// Isto não é detalhe: as callbacks do FFmpeg são síncronas e precisam esperar
/// uma leitura SMB assíncrona terminar. Se essa espera bloqueasse uma thread do
/// pool cooperativo — que é o que `Task.detached` usa — a própria tarefa que
/// faz a leitura poderia nunca ser escalonada, e o app travaria de vez.
/// Uma fila própria dá ao FFmpeg uma thread que pode ser bloqueada à vontade.
enum FFmpegRunner {

    /// Concorrente, e não serial.
    ///
    /// Com uma fila serial, uma leitura de rede que nunca retorna bloqueia a
    /// fila para sempre — e como todo trabalho de FFmpeg passa por aqui,
    /// nenhum outro vídeo consegue abrir depois disso. Era exatamente o
    /// sintoma: travou uma vez, não abre mais nada. Cada trabalho ganha sua
    /// própria thread; se um ficar preso, os demais seguem.
    private static let queue = DispatchQueue(label: "com.mauricio.labplayer.ffmpeg",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do    { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Adapta um arquivo em servidor SMB para o `AVIOSource`.
///
/// Traduz "me dê N bytes a partir de X" em leituras SMB, sem nunca materializar
/// o arquivo inteiro — que é o ponto: o vídeo de 75 GB no servidor de casa tem
/// que começar a tocar em segundos, não depois de um download.
final class SMBByteSource {

    private let reader: FileReader
    private let size: Int64
    private var position: Int64 = 0

    /// Leitura antecipada.
    ///
    /// Sem isto, cada pedido do decodificador vira uma ida e volta pela rede,
    /// feita no exato momento em que ele precisa dos bytes. Num arquivo de alta
    /// taxa o decodificador consome mais rápido do que a rede entrega, o laço
    /// fica esperando e o vídeo trava alguns segundos depois de começar —
    /// quando o buffer interno do FFmpeg acaba.
    ///
    /// Com blocos grandes em memória e o próximo já sendo buscado em segundo
    /// plano, a maioria das leituras é atendida sem tocar na rede.
    private static let chunkSize: Int64 = 4 * 1024 * 1024

    private var cache = Data()
    private var cacheStart: Int64 = -1
    private var prefetch: Task<(Int64, Data)?, Never>?
    private var prefetchStart: Int64 = -1

    init(reader: FileReader, size: Int64) {
        self.reader = reader
        self.size = size
    }

    /// Abre o arquivo e descobre o tamanho antes de entregar ao FFmpeg —
    /// sem tamanho conhecido não há seek, e sem seek não há rolagem.
    static func open(client: SMBClient, path: String) async throws -> SMBByteSource {
        let reader = client.fileReader(path: path)
        let size = try await reader.fileSize
        return SMBByteSource(reader: reader, size: Int64(size))
    }

    /// O `AVIOSource` devolvido retém esta fonte **fortemente**.
    ///
    /// Com captura fraca, bastava a fonte ser coletada para o FFmpeg saltar
    /// para um ponteiro de função inválido no primeiro seek. Agora manter vivo
    /// o AVIOSource basta para manter tudo vivo — e é ele que precisa
    /// sobreviver, porque é dele o AVIOContext.
    func makeAVIOSource() -> AVIOSource {
        AVIOSource(
            read: { buffer, count in self.read(into: buffer, count: count) },
            seek: { offset, whence in self.seek(to: offset, whence: whence) }
        )
    }

    // MARK: - Ponte assíncrono → síncrono

    private func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard position < size else { return 0 }
        let pedido = min(Int64(count), size - position)
        guard pedido > 0 else { return 0 }

        // 1. O bloco em memória atende?
        if let servidos = serveFromCache(into: buffer, count: Int(pedido)) {
            agendarProximoBloco()
            return servidos
        }

        // 2. O bloco que já estava sendo buscado é este?
        if prefetchStart == blocoDe(position), let tarefa = prefetch {
            let resultado = esperar(tarefa)
            prefetch = nil
            prefetchStart = -1
            if let (inicio, dados) = resultado, !dados.isEmpty {
                cache = dados
                cacheStart = inicio
                if let servidos = serveFromCache(into: buffer, count: Int(pedido)) {
                    agendarProximoBloco()
                    return servidos
                }
            }
        }

        // 3. Buscar agora, bloqueando. Acontece no início e após cada salto.
        prefetch = nil
        prefetchStart = -1
        guard let (inicio, dados) = buscarBloco(em: blocoDe(position)), !dados.isEmpty else {
            return position >= size ? 0 : -1
        }
        cache = dados
        cacheStart = inicio
        let servidos = serveFromCache(into: buffer, count: Int(pedido)) ?? 0
        agendarProximoBloco()
        return servidos
    }

    /// Alinha em múltiplos do bloco para as buscas se repetirem no mesmo lugar
    /// — sem isso, cada salto cria um bloco novo e o cache nunca acerta.
    private func blocoDe(_ deslocamento: Int64) -> Int64 {
        (deslocamento / Self.chunkSize) * Self.chunkSize
    }

    private func serveFromCache(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int? {
        guard cacheStart >= 0, position >= cacheStart else { return nil }
        let dentro = Int(position - cacheStart)
        guard dentro < cache.count else { return nil }

        let disponivel = min(count, cache.count - dentro)
        cache.withUnsafeBytes { origem in
            guard let base = origem.baseAddress else { return }
            buffer.update(from: base.advanced(by: dentro).assumingMemoryBound(to: UInt8.self),
                          count: disponivel)
        }
        position += Int64(disponivel)
        return disponivel
    }

    /// Dispara a busca do bloco seguinte quando o atual está acabando.
    private func agendarProximoBloco() {
        guard prefetch == nil, cacheStart >= 0 else { return }
        let restante = cacheStart + Int64(cache.count) - position
        // Só vale a pena antecipar quando ainda há folga para a rede responder.
        guard restante < Self.chunkSize / 2 else { return }

        let proximo = cacheStart + Int64(cache.count)
        guard proximo < size else { return }

        prefetchStart = proximo
        prefetch = Task { [reader, size] in
            let tamanho = UInt32(min(Self.chunkSize, size - proximo))
            guard let dados = try? await reader.read(offset: UInt64(proximo), length: tamanho) else {
                return nil
            }
            return (proximo, dados)
        }
    }

    /// Prazo para a rede responder.
    ///
    /// Sem prazo, uma conexão que engasga deixa esta espera parada para
    /// sempre, e com ela o decodificador. Vinte segundos é generoso para um
    /// bloco de 4 MB numa rede doméstica e curto o bastante para o app se
    /// recuperar em vez de morrer congelado.
    private static let networkTimeout: DispatchTimeInterval = .seconds(20)

    private func buscarBloco(em inicio: Int64) -> (Int64, Data)? {
        let tamanho = UInt32(min(Self.chunkSize, size - inicio))
        guard tamanho > 0 else { return nil }

        let caixa = ResultBox()
        let semaforo = DispatchSemaphore(value: 0)
        let tarefa = Task { [reader] in
            do    { caixa.data = try await reader.read(offset: UInt64(inicio), length: tamanho) }
            catch { caixa.failed = true }
            semaforo.signal()
        }

        if semaforo.wait(timeout: .now() + Self.networkTimeout) == .timedOut {
            tarefa.cancel()
            LabLog.problem("leitura SMB estourou o prazo em \(inicio / 1_048_576) MB")
            return nil
        }
        guard !caixa.failed, let dados = caixa.data else { return nil }
        return (inicio, dados)
    }

    private func esperar(_ tarefa: Task<(Int64, Data)?, Never>) -> (Int64, Data)? {
        let caixa = PrefetchBox()
        let semaforo = DispatchSemaphore(value: 0)
        Task {
            caixa.resultado = await tarefa.value
            semaforo.signal()
        }
        if semaforo.wait(timeout: .now() + Self.networkTimeout) == .timedOut {
            tarefa.cancel()
            LabLog.problem("leitura antecipada estourou o prazo")
            return nil
        }
        return caixa.resultado
    }

    private final class PrefetchBox {
        var resultado: (Int64, Data)?
    }

    private func seek(to offset: Int64, whence: Int32) -> Int64 {
        // O FFmpeg pergunta o tamanho por este mesmo canal, com um "whence"
        // especial — responder errado aqui faz o arquivo parecer não-buscável
        // e o player perde a barra de progresso.
        if whence == AVSEEK_SIZE { return size }

        switch whence {
        case SEEK_SET: position = offset
        case SEEK_CUR: position += offset
        case SEEK_END: position = size + offset
        default:       return Int64(labp_averror_einval())
        }
        position = max(0, min(position, size))

        // Saltar para longe invalida o que estava sendo buscado adiante; manter
        // essa tarefa só gastaria banda com bytes que ninguém vai pedir.
        if position < cacheStart || position >= cacheStart + Int64(cache.count) {
            prefetch?.cancel()
            prefetch = nil
            prefetchStart = -1
        }
        return position
    }

    /// Caixa de referência para trazer o resultado de volta da tarefa.
    private final class ResultBox {
        var data: Data?
        var failed = false
    }
}

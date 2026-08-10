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

    private static let queue = DispatchQueue(label: "com.mauricio.labplayer.ffmpeg",
                                             qos: .userInitiated)

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

    func makeAVIOSource() -> AVIOSource {
        AVIOSource(
            read: { [weak self] buffer, count in self?.read(into: buffer, count: count) ?? -1 },
            seek: { [weak self] offset, whence in self?.seek(to: offset, whence: whence) ?? -1 }
        )
    }

    // MARK: - Ponte assíncrono → síncrono

    private func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard position < size else { return 0 }
        let pedido = UInt32(min(Int64(count), size - position))
        guard pedido > 0 else { return 0 }

        let caixa = ResultBox()
        let semaforo = DispatchSemaphore(value: 0)
        let deslocamento = UInt64(position)

        Task { [reader] in
            do    { caixa.data = try await reader.read(offset: deslocamento, length: pedido) }
            catch { caixa.failed = true }
            semaforo.signal()
        }
        semaforo.wait()

        if caixa.failed { return -1 }
        guard let data = caixa.data, !data.isEmpty else { return 0 }

        data.withUnsafeBytes { origem in
            guard let base = origem.baseAddress else { return }
            buffer.update(from: base.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        position += Int64(data.count)
        return data.count
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
        return position
    }

    /// Caixa de referência para trazer o resultado de volta da tarefa.
    private final class ResultBox {
        var data: Data?
        var failed = false
    }
}

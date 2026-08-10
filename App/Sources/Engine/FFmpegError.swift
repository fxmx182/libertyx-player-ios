import Foundation

/// Erro vindo da biblioteca C, já traduzido.
struct FFmpegError: LocalizedError {
    let code: Int32
    let operation: String

    var errorDescription: String? {
        "\(operation): \(FFmpegError.message(for: code))"
    }

    static func message(for code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        labp_strerror(code, &buffer, buffer.count)
        let text = String(cString: buffer)
        return text.isEmpty ? "erro \(code)" : text
    }
}

/// Converte retorno negativo do FFmpeg em `throw`.
///
/// Toda a API C sinaliza erro com inteiro negativo. Sem isto, cada chamada
/// vira três linhas de `if ret < 0`, e é fácil esquecer uma — que é como
/// nascem os bugs silenciosos de decodificação.
@discardableResult
func ffCheck(_ operation: String, _ expression: @autoclosure () -> Int32) throws -> Int32 {
    let result = expression()
    guard result >= 0 else {
        throw FFmpegError(code: result, operation: operation)
    }
    return result
}

extension Int32 {
    /// Fim do arquivo — condição normal, não falha.
    var isEndOfFile: Bool { self == labp_averror_eof() }
    /// "Preciso de mais dados" — o estado mais comum do laço de decodificação.
    var isTryAgain: Bool { self == labp_averror_eagain() }
}

extension Int64 {
    /// Marca do FFmpeg para timestamp desconhecido.
    var isNoPTS: Bool { self == labp_nopts_value() }
}

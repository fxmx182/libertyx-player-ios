import Foundation

/// Uma fonte de bytes com acesso aleatório, apresentada ao FFmpeg como se
/// fosse um arquivo.
///
/// É a peça central do SMB. O FFmpeg não precisa saber de onde os bytes vêm —
/// ele pede "me dê 64 KB a partir do deslocamento X" e nós atendemos. Sem
/// isto, tocar um arquivo de rede exigiria baixá-lo inteiro antes, o que para
/// um vídeo de dezenas de gigabytes é o mesmo que não funcionar.
final class AVIOSource {

    /// Devolve quantos bytes leu, 0 no fim do arquivo, negativo em erro.
    typealias ReadBlock = (UnsafeMutablePointer<UInt8>, Int) -> Int
    /// Posiciona e devolve o novo deslocamento, ou negativo em erro.
    typealias SeekBlock = (Int64, Int32) -> Int64

    private let readBlock: ReadBlock
    private let seekBlock: SeekBlock
    private(set) var context: UnsafeMutablePointer<AVIOContext>?

    /// 256 KB: um buffer pequeno demais transforma cada leitura de rede numa
    /// ida e volta, e latência de SMB dói muito mais que memória.
    private static let bufferSize = 256 * 1024

    init(read: @escaping ReadBlock, seek: @escaping SeekBlock) {
        self.readBlock = read
        self.seekBlock = seek

        // O FFmpeg assume a posse deste buffer e pode realocá-lo — por isso
        // av_malloc, e não memória gerenciada pelo Swift.
        let buffer = av_malloc(Self.bufferSize)?.assumingMemoryBound(to: UInt8.self)
        let opaque = Unmanaged.passUnretained(self).toOpaque()

        context = avio_alloc_context(
            buffer,
            Int32(Self.bufferSize),
            0,              // só leitura
            opaque,
            avioReadCallback,
            nil,
            avioSeekCallback
        )
    }

    func perform(read buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        readBlock(buffer, count)
    }

    func perform(seek offset: Int64, whence: Int32) -> Int64 {
        seekBlock(offset, whence)
    }

    deinit {
        guard let context else { return }
        // O buffer atual pode não ser o que passamos: o FFmpeg realoca.
        av_free(context.pointee.buffer)
        var mutable: UnsafeMutablePointer<AVIOContext>? = context
        avio_context_free(&mutable)
    }
}

// MARK: - Callbacks em C
//
// Precisam ser funções de topo: ponteiro de função em C não carrega contexto.
// O `self` viaja pelo ponteiro opaco.

private func avioReadCallback(_ opaque: UnsafeMutableRawPointer?,
                              _ buffer: UnsafeMutablePointer<UInt8>?,
                              _ size: Int32) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return labp_averror_einval() }
    let source = Unmanaged<AVIOSource>.fromOpaque(opaque).takeUnretainedValue()

    let lidos = source.perform(read: buffer, count: Int(size))
    if lidos > 0 { return Int32(lidos) }
    // Zero byte é fim de arquivo, não erro — e o FFmpeg exige essa distinção
    // explícita, senão fica em laço infinito pedindo mais dados.
    return lidos == 0 ? labp_averror_eof() : labp_averror(EIO)
}

private func avioSeekCallback(_ opaque: UnsafeMutableRawPointer?,
                              _ offset: Int64,
                              _ whence: Int32) -> Int64 {
    guard let opaque else { return Int64(labp_averror_einval()) }
    let source = Unmanaged<AVIOSource>.fromOpaque(opaque).takeUnretainedValue()
    return source.perform(seek: offset, whence: whence)
}

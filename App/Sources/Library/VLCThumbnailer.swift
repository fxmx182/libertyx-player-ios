import UIKit
import VLCKitSPM

/// Miniatura pelo VLC.
///
/// Substitui o caminho por FFmpeg, que não funcionava — e por um motivo que
/// não dava para ver de fora. O nosso FFmpeg entra no app como biblioteca
/// estática, mas o MobileVLCKit é dinâmico e **exporta os mesmos símbolos**,
/// porque traz o próprio FFmpeg dentro. O ligador resolve `avformat_open_input`
/// e companhia pelo VLC antes de tocar no nosso arquivo, e o nosso nunca entra
/// no binário. Compila, liga, roda — e chama uma versão de FFmpeg diferente da
/// dos nossos cabeçalhos, com campos em outras posições na memória. O
/// resultado é lixo silencioso, nunca um erro.
///
/// A saída aqui não é brigar com o ligador: é reconhecer que o VLC já está no
/// app, com um FFmpeg inteiro e coerente consigo mesmo. Quem consegue tocar o
/// arquivo consegue tirar um quadro dele — e isso vale igual para o arquivo
/// local e para o do servidor, porque o VLC fala `smb://` nativamente.
@MainActor
enum VLCThumbnailer {

    /// Fração da duração onde tirar o quadro. Depois da abertura escura, antes
    /// de qualquer coisa acontecer.
    private static let posicao: Float = 0.12

    /// Nenhum arquivo justifica prender uma linha da lista para sempre — no
    /// servidor, um arquivo grande pode simplesmente nunca responder.
    private static let prazo: TimeInterval = 25

    static func preview(for item: MediaItem, maxWidth: CGFloat = 320) async -> (UIImage, Double)? {
        guard let url = try? VLCEngine.resolveURL(for: item.origin), let url else { return nil }

        // O escopo de segurança precisa durar toda a extração: o VLC lê o
        // arquivo em outra thread, depois de esta função ter retornado ao
        // chamador se fechássemos antes.
        var guarda: ScopedAccess?
        if case .file(let original, let bookmark) = item.origin {
            guarda = ScopedAccess(url: original, bookmark: bookmark)
            guard guarda?.path != nil else {
                LabLog.problem("miniatura: sem permissão para \(item.title)")
                return nil
            }
        }

        let media = VLCMedia(url: url)
        let tarefa = Tarefa(media: media, maxWidth: maxWidth)

        let imagem = await tarefa.executar(prazo: prazo)
        withExtendedLifetime(guarda) {}

        guard let imagem else {
            LabLog.problem("miniatura falhou: \(item.title)")
            return nil
        }

        // `length` só é confiável depois de o VLC ter aberto o arquivo — o que
        // a extração acabou de fazer.
        let duracao = Double(media.length.intValue) / 1000
        return (imagem, duracao > 0 ? duracao : 0)
    }

    /// Uma extração em curso.
    ///
    /// Classe separada porque o `VLCMediaThumbnailer` fala por delegado, e o
    /// delegado precisa de alguém vivo para responder — uma closure solta seria
    /// liberada antes de o quadro chegar.
    private final class Tarefa: NSObject, VLCMediaThumbnailerDelegate {

        private let media: VLCMedia
        private let maxWidth: CGFloat
        private var thumbnailer: VLCMediaThumbnailer?
        private var continuacao: CheckedContinuation<UIImage?, Never>?
        /// Três caminhos disputam a resposta: quadro pronto, tempo esgotado pelo
        /// VLC e o nosso próprio prazo. Retomar duas vezes derruba o app.
        private var respondido = false

        init(media: VLCMedia, maxWidth: CGFloat) {
            self.media = media
            self.maxWidth = maxWidth
        }

        func executar(prazo: TimeInterval) async -> UIImage? {
            await withCheckedContinuation { continuation in
                continuacao = continuation

                let novo = VLCMediaThumbnailer(media: media, andDelegate: self)
                novo.thumbnailWidth = maxWidth
                novo.thumbnailHeight = maxWidth * 9 / 16
                novo.snapshotPosition = VLCThumbnailer.posicao
                thumbnailer = novo
                novo.fetchThumbnail()

                DispatchQueue.main.asyncAfter(deadline: .now() + prazo) { [weak self] in
                    self?.responder(nil)
                }
            }
        }

        private func responder(_ imagem: UIImage?) {
            guard !respondido else { return }
            respondido = true
            thumbnailer = nil
            continuacao?.resume(returning: imagem)
            continuacao = nil
        }

        func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer,
                              didFinishThumbnail thumbnail: CGImage) {
            responder(UIImage(cgImage: thumbnail))
        }

        func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
            responder(nil)
        }
    }
}

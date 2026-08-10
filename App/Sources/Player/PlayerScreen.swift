import SwiftUI

/// Cola entre a biblioteca (SwiftUI) e o player (UIKit).
///
/// A escolha do motor acontece num único lugar — `makeEngine()`. Quando o
/// FFmpegEngine ficar pronto, é a única linha que muda para o app inteiro
/// passar a usá-lo.
struct PlayerScreen: UIViewControllerRepresentable {

    let item: MediaItem
    /// Os demais vídeos da mesma pasta, para pular de faixa e emendar no fim.
    var playlist: [MediaItem] = []

    func makeUIViewController(context: Context) -> PlayerViewController {
        PlayerViewController(engine: Self.makeEngine(for: item),
                             item: item,
                             playlist: playlist)
    }

    func updateUIViewController(_ controller: PlayerViewController, context: Context) {}

    @MainActor
    private static func makeEngine(for item: MediaItem) -> PlaybackEngine {
        // VLCKit. A troca de motor custou exatamente esta linha — que é o
        // motivo de tudo passar pelo protocolo PlaybackEngine desde o começo.
        //
        // O motor próprio (FFmpegEngine) continua no projeto: ele decodifica
        // quadro exato para as miniaturas e é a base para a rolagem frame a
        // frame, que é onde ele ganha do VLC.
        VLCEngine()
    }
}

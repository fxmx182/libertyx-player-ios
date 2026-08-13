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

    /// O motor é escolhido pelo arquivo, dentro do HybridEngine.
    ///
    /// Tenta o AVPlayer, que busca quadro exato e tem janela flutuante nativa;
    /// se ele recusar o formato, o VLC assume. O usuário não escolhe nada, e
    /// não há um caminho "experimental" para ele cair sem querer.
    @MainActor
    private static func makeEngine(for item: MediaItem) -> PlaybackEngine {
        AVPlayerEngine()
    }
}

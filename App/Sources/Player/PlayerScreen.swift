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

    /// VLC para tudo.
    ///
    /// O motor próprio existe no projeto e decodifica quadro exato — é o que
    /// daria a rolagem integral e a janela flutuante. Mas oferecer os dois
    /// custou regressões imediatas, e uma opção que leva a um caminho instável
    /// não é escolha, é armadilha. Ele volta quando estiver no mesmo nível.
    ///
    /// O `FFmpegEngine` segue em uso fora da reprodução: é ele que decodifica
    /// o quadro exato das miniaturas em "Detalhes do arquivo".
    @MainActor
    private static func makeEngine(for item: MediaItem) -> PlaybackEngine {
        VLCEngine()
    }
}

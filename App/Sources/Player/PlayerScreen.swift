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

    /// Os dois motores convivem, escolhidos por origem ou pela preferência.
    ///
    /// Nenhum vence em tudo: o próprio decodifica quadro exato (rolagem
    /// integral) e desenha na camada do sistema (janela flutuante); o VLC tem
    /// buffer de rede e recuperação de erro muito superiores. Deixá-los
    /// conviver custa uma linha porque tudo passa pelo protocolo
    /// `PlaybackEngine` desde o primeiro dia.
    @MainActor
    private static func makeEngine(for item: MediaItem) -> PlaybackEngine {
        switch EnginePreference.current.resolve(for: item.origin) {
        case .own: return FFmpegEngine()
        case .vlc: return VLCEngine()
        }
    }
}

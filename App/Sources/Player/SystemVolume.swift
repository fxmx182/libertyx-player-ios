import UIKit
import MediaPlayer
import AVFoundation

/// Controla o volume do aparelho — o mesmo que os botões laterais movem.
///
/// O iOS não oferece API pública para **definir** o volume (só para ler). O
/// caminho que resta é achar o `UISlider` que vive dentro de um `MPVolumeView`
/// e mexer nele: é o mesmo controle que a Central de Controle usa, então o
/// efeito é idêntico ao dos botões físicos.
///
/// A alternativa seria um ganho interno do player, que foi o que existia
/// antes. Funciona tecnicamente, mas cria dois volumes independentes no mesmo
/// aparelho — o gesto mexia num, os botões laterais no outro, e o usuário
/// ficava sem entender por que o dedo não fazia efeito.
@MainActor
final class SystemVolume {

    private let volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))
    private weak var slider: UISlider?

    /// Precisa estar na hierarquia de views, mesmo fora da tela: sem isso o
    /// `MPVolumeView` não monta o slider interno.
    func attach(to parent: UIView) {
        volumeView.isHidden = false
        volumeView.alpha = 0.001
        volumeView.showsRouteButton = false
        parent.addSubview(volumeView)
    }

    /// Procura o slider sob demanda e em profundidade.
    ///
    /// Ele não existe no instante em que a view entra na hierarquia, e nem
    /// sempre é filho direto — procurar uma vez só, no nível de cima, falhava
    /// silenciosamente e derrubava tudo para o caminho de reserva.
    private func resolvedSlider() -> UISlider? {
        if let slider { return slider }

        var fila: [UIView] = volumeView.subviews
        while let atual = fila.first {
            fila.removeFirst()
            if let encontrado = atual as? UISlider {
                slider = encontrado
                return encontrado
            }
            fila.append(contentsOf: atual.subviews)
        }
        return nil
    }

    /// Volume atual, 0...1.
    ///
    /// Lê do próprio slider quando ele existe — o mesmo lugar em que
    /// escrevemos. Ler da sessão de áudio e escrever no slider eram fontes
    /// diferentes, e a leitura vinha sempre em 100%: cada gesto recomeçava do
    /// topo em vez de continuar de onde parou.
    var value: Float {
        resolvedSlider()?.value ?? AVAudioSession.sharedInstance().outputVolume
    }

    /// Só tem efeito se o slider foi encontrado; do contrário, devolve `false`
    /// para quem chama poder cair no ganho interno do player.
    @discardableResult
    func set(_ novo: Float) -> Bool {
        guard let slider = resolvedSlider() else { return false }
        slider.value = max(0, min(1, novo))
        // O evento é o que faz o sistema aplicar de verdade; mudar só o valor
        // move o controle e não o volume.
        slider.sendActions(for: .valueChanged)
        return true
    }
}

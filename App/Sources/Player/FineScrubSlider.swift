import UIKit

/// Barra de rolagem com rolagem fina.
///
/// Numa barra comum, cada ponto de largura vale a mesma fração do vídeo. Num
/// filme de duas horas numa barra de 330 pontos, isso dá uns 22 segundos por
/// ponto — mais fino que a ponta do dedo consegue, e é por isso que acertar um
/// tempo específico era difícil: não era falta de jeito, era falta de
/// resolução.
///
/// A saída é a mesma dos apps de música e vídeo da própria Apple: quanto mais o
/// dedo se afasta verticalmente da barra enquanto arrasta, mais devagar ela
/// anda. Colado nela, velocidade normal; subindo, metade, um quarto, um
/// décimo. O dedo escolhe a precisão sem soltar.
final class FineScrubSlider: UISlider {

    /// Fração do movimento horizontal que vira movimento da barra.
    private(set) var velocidade: Float = 1

    /// Avisa quando a velocidade muda, para a tela poder mostrar em qual está.
    var onVelocidade: ((Float) -> Void)?

    private var ultimoX: CGFloat = 0

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let comecou = super.beginTracking(touch, with: event)
        if comecou {
            ultimoX = touch.location(in: self).x
            mudarVelocidade(para: 1)
        }
        return comecou
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let ponto = touch.location(in: self)

        // Degraus, e não uma curva contínua: com curva, a velocidade mudaria a
        // cada tremida vertical do dedo e o arrasto ficaria imprevisível.
        let distancia = abs(ponto.y - bounds.midY)
        let alvo: Float
        switch distancia {
        case ..<50:  alvo = 1
        case ..<100: alvo = 0.5
        case ..<150: alvo = 0.25
        default:     alvo = 0.1
        }
        mudarVelocidade(para: alvo)

        // Movimento relativo, e não posição absoluta: ao reduzir a velocidade
        // a bolinha precisa sair do lugar onde está, e não pular para baixo do
        // dedo — senão a mudança de precisão viraria um salto no vídeo.
        let trilha = trackRect(forBounds: bounds)
        let dx = ponto.x - ultimoX
        ultimoX = ponto.x
        guard trilha.width > 0 else { return true }

        let delta = Float(dx / trilha.width) * (maximumValue - minimumValue) * velocidade
        let novo = min(max(value + delta, minimumValue), maximumValue)
        if novo != value {
            value = novo
            sendActions(for: .valueChanged)
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        mudarVelocidade(para: 1)
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        mudarVelocidade(para: 1)
    }

    private func mudarVelocidade(para nova: Float) {
        guard nova != velocidade else { return }
        velocidade = nova
        onVelocidade?(nova)
    }
}

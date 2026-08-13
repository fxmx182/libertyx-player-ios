import UIKit

/// Um reconhecedor que nunca reconhece nada.
///
/// Existe só para avisar que um dedo encostou na tela — inclusive nos toques
/// que terminam num botão, que o `touchesBegan` da tela nunca chega a ver
/// porque o botão os consome antes.
///
/// Ele falha de propósito no primeiro toque: assim não disputa com os gestos
/// de verdade nem engole o toque do botão, e serve apenas de aviso.
final class TouchSpyRecognizer: UIGestureRecognizer {

    var onTouch: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // Nada do que ele faz pode atrapalhar o toque original.
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouch?()
        state = .failed
    }
}

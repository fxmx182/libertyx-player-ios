import UIKit

/// O aviso na borda: toque duplo e segurar-para-acelerar.
///
/// Um halo que se desfaz nas bordas, e não um círculo de borda dura: diz "aqui"
/// sem desenhar mais uma forma sobre o filme. Fica no meio da borda do lado em
/// que se anda — à direita para frente, à esquerda para trás —, e não no alto,
/// onde mora a ilha.
final class EdgeHaloView: UIView {

    private let brilho = CAGradientLayer()
    private let icone = UIImageView()
    let texto = UILabel()

    init(frente: Bool) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        translatesAutoresizingMaskIntoConstraints = false

        brilho.type = .radial
        brilho.colors = [UIColor.white.withAlphaComponent(0.28).cgColor,
                         UIColor.white.withAlphaComponent(0.10).cgColor,
                         UIColor.white.withAlphaComponent(0).cgColor]
        brilho.locations = [0, 0.5, 1]
        brilho.startPoint = CGPoint(x: 0.5, y: 0.5)
        brilho.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(brilho)

        icone.image = UIImage(systemName: frente ? "forward.fill" : "backward.fill")
        icone.tintColor = .white
        icone.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)

        texto.font = LabFont.ui(19, .bold, mono: true)
        texto.textColor = .white
        texto.textAlignment = .center
        texto.numberOfLines = 2

        // Sem caixa: a sombra é o que mantém a leitura sobre qualquer quadro.
        [icone, texto].forEach {
            $0.layer.shadowColor = UIColor.black.cgColor
            $0.layer.shadowOpacity = 0.9
            $0.layer.shadowRadius = 5
            $0.layer.shadowOffset = CGSize(width: 0, height: 1)
        }

        let pilha = UIStackView(arrangedSubviews: [icone, texto])
        pilha.axis = .vertical
        pilha.alignment = .center
        pilha.spacing = 6
        pilha.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pilha)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 150),
            heightAnchor.constraint(equalToConstant: 150),
            pilha.centerXAnchor.constraint(equalTo: centerXAnchor),
            pilha.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override func layoutSubviews() {
        super.layoutSubviews()
        brilho.frame = bounds
    }

    func aparecer() {
        layer.removeAllAnimations()
        if alpha < 0.01 { transform = CGAffineTransform(scaleX: 0.8, y: 0.8) }
        UIView.animate(withDuration: 0.16) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func sumir() {
        UIView.animate(withDuration: 0.24) { self.alpha = 0 }
    }
}

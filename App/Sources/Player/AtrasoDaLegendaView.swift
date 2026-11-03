import UIKit

/// O atraso da legenda, como no Jellyfin: uma barra no alto da tela.
///
/// No alto, e sem escurecer o filme, porque o ajuste se faz olhando a boca de
/// quem fala e a legenda ao mesmo tempo — nada pode cobrir a cena. A barra vale
/// na hora, enquanto se arrasta; os botões − e + andam um décimo de segundo, o
/// passo que o dedo na barra não acerta. Tocar fora fecha.
final class AtrasoDaLegendaView: UIControl {

    /// Até onde vai, para cada lado: legenda de outra edição do mesmo filme
    /// chega a vir dezenas de segundos fora.
    static let maximo: Double = 30

    var onChange: ((Double) -> Void)?
    var onClose: (() -> Void)?

    private let cartao = UIView()
    private let valor = UILabel()
    private let barra = UISlider()

    init(atraso: Double) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addTarget(self, action: #selector(fechar), for: .touchUpInside)

        cartao.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        cartao.layer.cornerRadius = 14
        cartao.layer.borderWidth = 0.5
        cartao.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        cartao.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cartao)

        valor.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        valor.textColor = .white
        valor.textAlignment = .center

        let fechar = UIButton(type: .system)
        fechar.setImage(UIImage(systemName: "xmark"), for: .normal)
        fechar.tintColor = .white
        fechar.accessibilityLabel = String(localized: "Fechar")
        fechar.addTarget(self, action: #selector(self.fechar), for: .touchUpInside)

        barra.minimumValue = Float(-Self.maximo)
        barra.maximumValue = Float(Self.maximo)
        barra.value = Float(atraso)
        barra.minimumTrackTintColor = LabTheme.accentUI
        barra.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        barra.addTarget(self, action: #selector(arrastou), for: .valueChanged)

        let menos = passo("−", -0.1)
        let mais = passo("+", 0.1)

        let dica = UILabel()
        dica.text = String(localized: "− mostra a legenda antes · + depois")
        dica.font = .systemFont(ofSize: 12)
        dica.textColor = UIColor.white.withAlphaComponent(0.6)
        dica.textAlignment = .center

        let linha = UIStackView(arrangedSubviews: [menos, barra, mais])
        linha.spacing = 8
        linha.alignment = .center
        let pilha = UIStackView(arrangedSubviews: [valor, linha, dica])
        pilha.axis = .vertical
        pilha.spacing = 6
        pilha.translatesAutoresizingMaskIntoConstraints = false
        fechar.translatesAutoresizingMaskIntoConstraints = false
        cartao.addSubview(pilha)
        cartao.addSubview(fechar)

        let largura = cartao.widthAnchor.constraint(equalToConstant: 560)
        largura.priority = .defaultHigh
        NSLayoutConstraint.activate([
            cartao.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            cartao.centerXAnchor.constraint(equalTo: centerXAnchor),
            cartao.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            largura,
            pilha.topAnchor.constraint(equalTo: cartao.topAnchor, constant: 10),
            pilha.bottomAnchor.constraint(equalTo: cartao.bottomAnchor, constant: -12),
            pilha.leadingAnchor.constraint(equalTo: cartao.leadingAnchor, constant: 10),
            pilha.trailingAnchor.constraint(equalTo: cartao.trailingAnchor, constant: -10),
            fechar.topAnchor.constraint(equalTo: cartao.topAnchor, constant: 4),
            fechar.trailingAnchor.constraint(equalTo: cartao.trailingAnchor, constant: -4),
            fechar.widthAnchor.constraint(equalToConstant: 40),
            fechar.heightAnchor.constraint(equalToConstant: 40),
            menos.widthAnchor.constraint(equalToConstant: 44),
            mais.widthAnchor.constraint(equalToConstant: 44),
        ])
        mostrar(atraso)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Cartão engole os toques: só tocar fora dele fecha.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let alvo = super.hitTest(point, with: event)
        return alvo === cartao ? nil : alvo
    }

    private func passo(_ texto: String, _ segundos: Double) -> UIButton {
        let botao = UIButton(type: .system)
        botao.setTitle(texto, for: .normal)
        botao.titleLabel?.font = .systemFont(ofSize: 24, weight: .medium)
        botao.tintColor = .white
        botao.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.aplicar(Double(self.barra.value) + segundos)
        }, for: .touchUpInside)
        return botao
    }

    @objc private func arrastou() { aplicar(Double(barra.value)) }

    /// Sempre em décimos: a barra solta daria 1,2347 s, e nem o VLC nem o olho
    /// distinguem menos que isso.
    private func aplicar(_ segundos: Double) {
        let redondo = (min(max(segundos, -Self.maximo), Self.maximo) * 10).rounded() / 10
        barra.value = Float(redondo)
        mostrar(redondo)
        onChange?(redondo)
    }

    private func mostrar(_ segundos: Double) {
        valor.text = Self.texto(segundos)
    }

    /// "+1,5 s", "−0,3 s", "0 s": o sinal sempre à mostra, que é o que diz o sentido.
    static func texto(_ segundos: Double) -> String {
        guard abs(segundos) >= 0.05 else { return "0 s" }
        let numero = abs(segundos).formatted(.number.precision(.fractionLength(1)))
        return (segundos > 0 ? "+" : "−") + numero + " s"
    }

    @objc private func fechar() {
        removeFromSuperview()
        onClose?()
    }
}

import UIKit

/// Fileira de ferramentas sobre o vídeo, no espírito do MX Player.
///
/// Botão redondo com rótulo embaixo, rolando na horizontal. Menu suspenso
/// seria menos código, mas esconde as opções atrás de dois toques — e o ponto
/// dessas ferramentas é estarem à mão enquanto se assiste.
final class ToolStripView: UIView {

    struct Tool {
        let id: String
        var symbol: String
        var title: String
        /// Ligada muda a cor, para o estado ser visível sem abrir nada.
        var isOn: Bool = false
        var action: () -> Void
    }

    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    private func setup() {
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.axis = .horizontal
        stack.spacing = 18
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    /// Recria a fileira. Chamado sempre que o estado muda (mudo ligado,
    /// repetição ativa) para os destaques acompanharem.
    func configure(with tools: [Tool]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tools.forEach { stack.addArrangedSubview(makeButton(for: $0)) }
    }

    private func makeButton(for tool: Tool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let circulo = UIButton(type: .system)
        circulo.setImage(UIImage(systemName: tool.symbol), for: .normal)
        circulo.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .regular), forImageIn: .normal)
        circulo.tintColor = tool.isOn ? .black : .white
        circulo.backgroundColor = tool.isOn
            ? UIColor.white.withAlphaComponent(0.92)
            : UIColor.black.withAlphaComponent(0.45)
        circulo.layer.cornerRadius = 26
        circulo.translatesAutoresizingMaskIntoConstraints = false

        // A ação vem numa closure; UIAction evita ter que guardar alvo e seletor
        // para cada botão criado dinamicamente.
        circulo.addAction(UIAction { _ in tool.action() }, for: .touchUpInside)

        let rotulo = UILabel()
        rotulo.text = tool.title
        rotulo.font = .systemFont(ofSize: 11, weight: .medium)
        rotulo.textColor = .white
        rotulo.textAlignment = .center
        rotulo.numberOfLines = 2
        rotulo.lineBreakMode = .byWordWrapping
        rotulo.translatesAutoresizingMaskIntoConstraints = false
        // Sombra porque o rótulo cai sobre o vídeo, que pode ser claro.
        rotulo.layer.shadowColor = UIColor.black.cgColor
        rotulo.layer.shadowOpacity = 0.9
        rotulo.layer.shadowRadius = 2
        rotulo.layer.shadowOffset = .zero

        container.addSubview(circulo)
        container.addSubview(rotulo)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 66),
            // Altura explícita, e não deduzida do conteúdo: sem ela o
            // contêiner fica com altura zero. Os botões continuariam
            // VISÍVEIS — o iOS desenha fora dos limites — mas não receberiam
            // toque nenhum, porque o teste de toque respeita os limites. Era
            // por isso que nenhuma ferramenta respondia.
            container.heightAnchor.constraint(equalToConstant: 80),

            circulo.topAnchor.constraint(equalTo: container.topAnchor),
            circulo.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            circulo.widthAnchor.constraint(equalToConstant: 52),
            circulo.heightAnchor.constraint(equalToConstant: 52),

            rotulo.topAnchor.constraint(equalTo: circulo.bottomAnchor, constant: 6),
            rotulo.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rotulo.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rotulo.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }
}

import UIKit

/// O tamanho da legenda: a mesma barra do atraso, no alto, com − e +, e a
/// legenda à vista embaixo para ver se ficou confortável. Cada mudança refaz
/// o reprodutor no mesmo ponto (ver `TamanhoDaLegenda`); toques seguidos
/// esperam meio segundo e viram um só. Tocar fora fecha.
final class TamanhoDaLegendaView: UIControl {

    /// Já com o tamanho guardado: refazer o reprodutor.
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?

    private let cartao = UIView()
    private let valor = UILabel()
    private let barra = UISlider()
    private var espera: DispatchWorkItem?

    init() {
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

        let opcoes = TamanhoDaLegenda.opcoes
        barra.minimumValue = 0
        barra.maximumValue = Float(opcoes.count - 1)
        barra.value = Float(opcoes.firstIndex(of: TamanhoDaLegenda.atual) ?? opcoes.firstIndex(of: 100) ?? 0)
        barra.minimumTrackTintColor = LabTheme.accentUI
        barra.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        barra.addTarget(self, action: #selector(arrastou), for: .valueChanged)

        let menos = passo("−", -1)
        let mais = passo("+", 1)

        let dica = UILabel()
        dica.text = String(localized: "Olhe a legenda embaixo. A cada mudança o vídeo recomeça do mesmo ponto.")
        dica.font = .systemFont(ofSize: 12)
        dica.textColor = UIColor.white.withAlphaComponent(0.6)
        dica.textAlignment = .center
        dica.numberOfLines = 0

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
        mostrar()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Cartão engole os toques: só tocar fora dele fecha.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let alvo = super.hitTest(point, with: event)
        return alvo === cartao ? nil : alvo
    }

    private func passo(_ texto: String, _ direcao: Int) -> UIButton {
        let botao = UIButton(type: .system)
        botao.setTitle(texto, for: .normal)
        botao.titleLabel?.font = .systemFont(ofSize: 24, weight: .medium)
        botao.tintColor = .white
        botao.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.aplicar(Int(self.barra.value.rounded()) + direcao)
        }, for: .touchUpInside)
        return botao
    }

    @objc private func arrastou() { aplicar(Int(barra.value.rounded())) }

    private func aplicar(_ posicao: Int) {
        let opcoes = TamanhoDaLegenda.opcoes
        let certa = min(max(posicao, 0), opcoes.count - 1)
        barra.value = Float(certa)
        guard opcoes[certa] != TamanhoDaLegenda.atual else { return }
        TamanhoDaLegenda.atual = opcoes[certa]
        mostrar()
        espera?.cancel()
        let trabalho = DispatchWorkItem { [weak self] in self?.onChange?() }
        espera = trabalho
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: trabalho)
    }

    private func mostrar() {
        valor.text = String(localized: "Legenda em \(TamanhoDaLegenda.atual)%")
    }

    @objc private func fechar() {
        removeFromSuperview()
        onClose?()
    }
}

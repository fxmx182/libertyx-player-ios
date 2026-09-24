import UIKit

/// O painel de ferramentas: uma grade de anéis finos sobre o próprio filme.
///
/// No lugar do menu em lista. Quinze itens em lista de texto são uma coluna que
/// se lê linha a linha, no escuro, com o filme parado; em grade de quatro, tudo
/// aparece de uma vez e o dedo vai direto ao desenho. O rótulo embaixo resolve
/// o que o desenho sozinho não diria.
///
/// Sem fundo próprio: os anéis flutuam sobre o filme, que continua à vista. Quem
/// garante a leitura é o véu que escurece a cena por igual, o escuro dentro de
/// cada anel e a sombra dos nomes — e não um bloco preto tapando metade da tela.
final class ToolsPanelView: UIView {

    struct Ferramenta {
        let rotulo: String
        let simbolo: String
        /// Em que ponto ela está: "deitado", "10 segundos". À mostra de
        /// propósito — o painel existe para não precisar abrir nada para olhar.
        var valor: String? = nil
        /// Ligada: anel dourado e um ponto no canto, para não se esquecer.
        var aceso = false
        /// Texto dentro do anel no lugar do ícone — a velocidade. "1,5×" diz
        /// mais que qualquer desenho de velocímetro.
        var noAnel: String? = nil
        let acao: () -> Void
    }

    var onClose: (() -> Void)?

    private let veu = UIControl()
    private let rolagem = UIScrollView()
    private let grade = UIStackView()

    init(ferramentas: [Ferramenta]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // O véu escurece a cena sem escondê-la, e tocar nele fecha — é o
        // caminho que todo mundo tenta primeiro.
        veu.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        veu.addTarget(self, action: #selector(fechar), for: .touchUpInside)
        veu.translatesAutoresizingMaskIntoConstraints = false
        addSubview(veu)

        grade.axis = .vertical
        grade.spacing = 4
        grade.translatesAutoresizingMaskIntoConstraints = false

        rolagem.showsVerticalScrollIndicator = false
        rolagem.translatesAutoresizingMaskIntoConstraints = false
        rolagem.addSubview(grade)
        addSubview(rolagem)

        // Quatro por fileira. As células vazias fecham a última: sem elas, uma
        // fileira de três repartiria a largura entre três e sairia
        // desalinhada das de cima.
        var fila: [UIView] = []
        for ferramenta in ferramentas {
            fila.append(celula(ferramenta))
            if fila.count == 4 { grade.addArrangedSubview(fileira(fila)); fila = [] }
        }
        if !fila.isEmpty {
            while fila.count < 4 { fila.append(UIView()) }
            grade.addArrangedSubview(fileira(fila))
        }

        let altura = rolagem.heightAnchor.constraint(equalTo: grade.heightAnchor)
        altura.priority = .defaultHigh

        NSLayoutConstraint.activate([
            veu.topAnchor.constraint(equalTo: topAnchor),
            veu.bottomAnchor.constraint(equalTo: bottomAnchor),
            veu.leadingAnchor.constraint(equalTo: leadingAnchor),
            veu.trailingAnchor.constraint(equalTo: trailingAnchor),

            rolagem.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 10),
            rolagem.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
            rolagem.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            altura,
            // O painel não passa de 60% da tela. Fileira cortada pela borda
            // não se lê como "role para ver mais", lê-se como defeito — acima
            // do teto, ele rola.
            rolagem.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.6),

            grade.topAnchor.constraint(equalTo: rolagem.contentLayoutGuide.topAnchor),
            grade.bottomAnchor.constraint(equalTo: rolagem.contentLayoutGuide.bottomAnchor),
            grade.leadingAnchor.constraint(equalTo: rolagem.contentLayoutGuide.leadingAnchor),
            grade.trailingAnchor.constraint(equalTo: rolagem.contentLayoutGuide.trailingAnchor),
            grade.widthAnchor.constraint(equalTo: rolagem.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    // MARK: - Aparecer e sumir

    func aparecer() {
        veu.alpha = 0
        rolagem.transform = CGAffineTransform(translationX: 0, y: 40)
        rolagem.alpha = 0
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.veu.alpha = 1
            self.rolagem.transform = .identity
            self.rolagem.alpha = 1
        }
    }

    @objc private func fechar() {
        sumir { }
    }

    private func sumir(_ depois: @escaping () -> Void) {
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
            self.onClose?()
            depois()
        })
    }

    // MARK: - Peças

    private func fileira(_ celulas: [UIView]) -> UIStackView {
        let pilha = UIStackView(arrangedSubviews: celulas)
        pilha.axis = .horizontal
        pilha.distribution = .fillEqually
        pilha.alignment = .top
        return pilha
    }

    private func celula(_ ferramenta: Ferramenta) -> UIView {
        let dourado = LabTheme.accentUI
        let botao = UIControl()

        // O anel: traço fino e vazio por dentro, com um véu escuro que mantém o
        // ícone legível sobre cena clara. Ligada, o traço vira dourado.
        let anel = UIView()
        anel.isUserInteractionEnabled = false
        anel.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        anel.layer.cornerRadius = 29
        anel.layer.borderWidth = 1.5
        anel.layer.borderColor = (ferramenta.aceso ? dourado : UIColor.white.withAlphaComponent(0.9)).cgColor
        anel.translatesAutoresizingMaskIntoConstraints = false

        let miolo: UIView
        if let noAnel = ferramenta.noAnel {
            let texto = UILabel()
            texto.text = noAnel
            texto.font = .systemFont(ofSize: 15, weight: .bold)
            texto.textColor = ferramenta.aceso ? dourado : .white
            miolo = texto
        } else {
            let icone = UIImageView(image: UIImage(systemName: ferramenta.simbolo))
            icone.tintColor = ferramenta.aceso ? dourado : .white
            icone.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
            icone.contentMode = .scaleAspectFit
            miolo = icone
        }
        miolo.isUserInteractionEnabled = false
        miolo.translatesAutoresizingMaskIntoConstraints = false

        // O ponto no canto: o estado ligado se vê de longe, sem depender só da
        // cor. Aro preto para se destacar do traço que ele sobrepõe.
        let ponto = UIView()
        ponto.isHidden = !ferramenta.aceso
        ponto.isUserInteractionEnabled = false
        ponto.backgroundColor = dourado
        ponto.layer.cornerRadius = 6
        ponto.layer.borderWidth = 2
        ponto.layer.borderColor = UIColor.black.cgColor
        ponto.translatesAutoresizingMaskIntoConstraints = false

        // O nome ocupa sempre duas linhas, para as fileiras ficarem alinhadas;
        // o valor, quando existe, é a segunda — em dourado e um pouco menor.
        let rotulo = UILabel()
        rotulo.numberOfLines = 2
        rotulo.textAlignment = .center
        rotulo.isUserInteractionEnabled = false
        rotulo.translatesAutoresizingMaskIntoConstraints = false
        let texto = NSMutableAttributedString(
            string: ferramenta.rotulo,
            attributes: [.font: UIFont.systemFont(ofSize: 12.5, weight: .medium),
                         .foregroundColor: UIColor.white])
        if let valor = ferramenta.valor {
            texto.append(NSAttributedString(
                string: "\n" + valor,
                attributes: [.font: UIFont.systemFont(ofSize: 11.5, weight: .semibold),
                             .foregroundColor: dourado]))
        }
        rotulo.attributedText = texto
        rotulo.layer.shadowColor = UIColor.black.cgColor
        rotulo.layer.shadowOpacity = 0.95
        rotulo.layer.shadowRadius = 4
        rotulo.layer.shadowOffset = CGSize(width: 0, height: 1)

        [anel, miolo, ponto, rotulo].forEach(botao.addSubview)
        NSLayoutConstraint.activate([
            anel.topAnchor.constraint(equalTo: botao.topAnchor, constant: 10),
            anel.centerXAnchor.constraint(equalTo: botao.centerXAnchor),
            anel.widthAnchor.constraint(equalToConstant: 58),
            anel.heightAnchor.constraint(equalToConstant: 58),

            miolo.centerXAnchor.constraint(equalTo: anel.centerXAnchor),
            miolo.centerYAnchor.constraint(equalTo: anel.centerYAnchor),

            ponto.widthAnchor.constraint(equalToConstant: 12),
            ponto.heightAnchor.constraint(equalToConstant: 12),
            ponto.topAnchor.constraint(equalTo: anel.topAnchor, constant: 1),
            ponto.trailingAnchor.constraint(equalTo: anel.trailingAnchor, constant: -1),

            rotulo.topAnchor.constraint(equalTo: anel.bottomAnchor, constant: 8),
            rotulo.leadingAnchor.constraint(equalTo: botao.leadingAnchor, constant: 2),
            rotulo.trailingAnchor.constraint(equalTo: botao.trailingAnchor, constant: -2),
            rotulo.heightAnchor.constraint(equalToConstant: 32),
            rotulo.bottomAnchor.constraint(equalTo: botao.bottomAnchor, constant: -8),
        ])

        // Tocado, o anel se enche por um instante — o retorno de que o toque
        // pegou antes de o painel sumir.
        botao.addAction(UIAction { [weak self, weak anel] _ in
            anel?.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            self?.sumir(ferramenta.acao)
        }, for: .touchUpInside)
        return botao
    }
}

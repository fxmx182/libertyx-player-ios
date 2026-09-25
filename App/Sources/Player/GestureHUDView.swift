import UIKit

/// O balão central que aparece durante os gestos (brilho, volume, seek, 2x).
/// Efêmero por natureza: aparece na hora, some sozinho.
final class GestureHUDView: UIView {

    enum Content {
        case brightness(Float)
        case volume(Float)
        case seek(delta: Double, target: Double, duration: Double)
        case rate(Float)
        case text(String)
        /// Só o tempo de destino, sem caixa em volta. Usado durante o arrasto,
        /// quando o usuário está justamente tentando enxergar a imagem.
        case time(Double)
    }

    /// Fundo translúcido em vez de desfoque opaco.
    ///
    /// O balão aparece no meio da tela justamente enquanto o usuário ajusta o
    /// vídeo — e tapar a imagem no momento em que ele quer vê-la derrota o
    /// propósito. O texto ganha sombra para continuar legível sobre cena clara.
    private let fundo = UIView()
    private let icon = UIImageView()
    private let primary = UILabel()
    private let secondary = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let stack = UIStackView()
    /// Valor em cima, o que ele é embaixo. Antes eram duas linhas iguais lado
    /// a lado, e o olho não sabia qual ler primeiro.
    private let textos = UIStackView()

    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    private func setup() {
        alpha = 0
        // O arredondamento vai no fundo, não no contêiner: recortar o
        // contêiner cortaria junto as sombras do texto, que são o que mantém
        // a leitura possível agora que o fundo é translúcido.
        // Pastilha horizontal, como a do volume do próprio iOS, em vez de um
        // quadro no meio da imagem: diz o que precisa dizer ocupando uma faixa
        // fina, e o fundo mal aparece.
        fundo.layer.cornerRadius = 17
        fundo.layer.cornerCurve = .continuous
        fundo.backgroundColor = UIColor.black.withAlphaComponent(0.26)
        fundo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fundo)

        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

        primary.font = LabFont.ui(15, .semibold, mono: true)
        primary.textColor = .white
        primary.textAlignment = .center
        [primary, secondary, icon].forEach { view in
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.9
            view.layer.shadowRadius = 3
            view.layer.shadowOffset = .zero
        }

        secondary.font = LabFont.ui(12, .semibold, mono: true)
        secondary.textColor = UIColor.white.withAlphaComponent(0.65)
        secondary.textAlignment = .center

        bar.progressTintColor = .white
        bar.trackTintColor = UIColor.white.withAlphaComponent(0.25)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        textos.axis = .vertical
        textos.alignment = .center
        textos.spacing = 1
        [primary, secondary].forEach { textos.addArrangedSubview($0) }
        [icon, textos, bar].forEach { stack.addArrangedSubview($0) }
        addSubview(stack)

        NSLayoutConstraint.activate([
            fundo.topAnchor.constraint(equalTo: topAnchor),
            fundo.bottomAnchor.constraint(equalTo: bottomAnchor),
            fundo.leadingAnchor.constraint(equalTo: leadingAnchor),
            fundo.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            bar.widthAnchor.constraint(equalToConstant: 70),
        ])
    }

    func show(_ content: Content) {
        hideWork?.cancel()

        switch content {
        case .brightness(let value):
            icon.image = UIImage(systemName: "sun.max.fill")
            icon.isHidden = false
            primary.text = "\(Int(value * 100))%"
            secondary.isHidden = true
            bar.isHidden = false
            bar.progress = value

        case .volume(let value):
            icon.image = UIImage(systemName: value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            icon.isHidden = false
            primary.text = "\(Int(value * 100))%"
            secondary.isHidden = true
            bar.isHidden = false
            bar.progress = value

        case .seek(let delta, let target, let duration):
            icon.isHidden = true
            let sign = delta >= 0 ? "+" : "−"
            primary.text = TimeFormat.clock(target)
            // O salto em dourado: é ele que diz "para frente" ou "para trás".
            secondary.isHidden = false
            secondary.text = "\(sign)\(TimeFormat.clock(abs(delta)))"
            secondary.textColor = LabTheme.accentUI
            bar.isHidden = true
            _ = duration

        case .rate(let value):
            icon.image = UIImage(systemName: "forward.fill")
            icon.isHidden = false
            primary.text = String(format: "%.1f×", value)
            secondary.isHidden = true
            bar.isHidden = true

        case .text(let value):
            icon.isHidden = true
            primary.text = value
            secondary.isHidden = true
            bar.isHidden = true

        case .time(let instante):
            icon.isHidden = true
            primary.text = TimeFormat.clock(instante)
            secondary.isHidden = true
            bar.isHidden = true
        }

        // Sem caixa nem barra, o número é a única referência na tela — e
        // precisa ser lido de relance, com o dedo em movimento.
        switch content {
        case .time, .seek:
            primary.font = LabFont.ui(24, .bold, mono: true)
        default:
            primary.font = LabFont.ui(15, .semibold, mono: true)
            secondary.textColor = UIColor.white.withAlphaComponent(0.65)
        }

        // O fundo some no modo tempo: a sombra do texto basta para ele ficar
        // legível, e nada cobre a cena que se está procurando.
        switch content {
        case .time, .seek: fundo.alpha = 0
        default:           fundo.alpha = 1
        }

        guard alpha < 1 else { return }
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
    }

    func hideAfterDelay(_ delay: TimeInterval = 0.6) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.25) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

enum TimeFormat {
    /// "1 h 12 min", "8 min", "40 s" — para ler, não para cronometrar. É como
    /// se diz quanto falta de um filme.
    static func spoken(_ segundos: Double) -> String {
        let total = Int(segundos.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        if m > 0 { return "\(m) min" }
        return "\(max(total, 1)) s"
    }

    /// h:mm:ss quando passa de uma hora, mm:ss quando não passa.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

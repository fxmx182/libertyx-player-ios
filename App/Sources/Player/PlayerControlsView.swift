import UIKit

/// Controles do player: barra superior, botões centrais e barra inferior com
/// ferramentas — no espírito do MX Player.
///
/// Nenhuma lógica de reprodução aqui: a view só emite intenções. Isso é o que
/// permite ela sobreviver intacta à troca do AVPlayer pelo motor FFmpeg.
final class PlayerControlsView: UIView {

    // MARK: - Intenções

    var onPlayPause: (() -> Void)?
    var onClose: (() -> Void)?
    /// `finished == false` durante o arrasto (scrub ao vivo), `true` ao soltar.
    var onScrub: ((Double, Bool) -> Void)?
    var onSeekRelative: ((Double) -> Void)?
    var onSpeedChange: ((Float) -> Void)?
    var onCycleAspect: (() -> Void)?
    var onRotate: (() -> Void)?
    var onShowTracks: ((TrackKind) -> Void)?
    var onLockChange: ((Bool) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    enum TrackKind { case audio, subtitle }

    // MARK: - Estado

    private(set) var isVisible = true
    /// Bloqueio: esconde tudo e desliga os gestos. Existe porque assistir
    /// deitado na cama significa encostar na tela sem querer o tempo todo.
    private(set) var isLocked = false

    var title: String = "" {
        didSet { titleLabel.text = title }
    }

    private var duration: Double = 0
    private var isUserScrubbing = false
    private var currentSpeed: Float = 1.0

    // MARK: - Views

    private let topBar = UIView()
    private let centerStack = UIStackView()
    private let bottomBar = UIView()
    private let topGradient = CAGradientLayer()
    private let bottomGradient = CAGradientLayer()

    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)

    private let previousButton = UIButton(type: .system)
    private let rewindButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)

    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let slider = UISlider()
    private let toolRow = UIStackView()

    private let lockButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let aspectButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    /// Botão solto que aparece sozinho quando tudo está bloqueado.
    private let unlockButton = UIButton(type: .system)

    // MARK: - Ciclo de vida

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupTopBar()
        setupCenterControls()
        setupBottomBar()
        setupUnlockButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    /// Só intercepta o toque se ele caiu sobre um controle visível — o resto
    /// atravessa para a camada de gestos.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isLocked {
            return unlockButton.frame.insetBy(dx: -12, dy: -12).contains(point)
        }
        guard isVisible else { return false }
        return topBar.frame.contains(point)
            || bottomBar.frame.contains(point)
            || centerStack.frame.insetBy(dx: -20, dy: -20).contains(point)
    }

    // MARK: - Construção

    private static func iconButton(_ symbol: String, size: CGFloat = 17,
                                   weight: UIImage.SymbolWeight = .medium) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: size, weight: weight), forImageIn: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)

        topGradient.colors = [UIColor.black.withAlphaComponent(0.8).cgColor, UIColor.clear.cgColor]
        topBar.layer.insertSublayer(topGradient, at: 0)

        configure(closeButton, symbol: "chevron.down", action: #selector(closeTapped))
        configure(subtitleButton, symbol: "captions.bubble", action: #selector(subtitlesTapped))
        configure(audioButton, symbol: "waveform", action: #selector(audioTapped))

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        [closeButton, titleLabel, subtitleButton, audioButton].forEach(topBar.addSubview)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 96),

            closeButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -14),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            audioButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            audioButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            audioButton.widthAnchor.constraint(equalToConstant: 44),
            audioButton.heightAnchor.constraint(equalToConstant: 44),

            subtitleButton.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -4),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            subtitleButton.widthAnchor.constraint(equalToConstant: 44),
            subtitleButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
    }

    /// Play/pause no centro, com ±10 s dos lados. É o pedido mais direto de
    /// quem vem do MX Player: a mão fica no meio da tela, não no rodapé.
    private func setupCenterControls() {
        configure(previousButton, symbol: "backward.end.fill", size: 22, action: #selector(previousTapped))
        configure(rewindButton, symbol: "gobackward.10", size: 30, action: #selector(rewindTapped))
        configure(playButton, symbol: "play.fill", size: 42, weight: .semibold, action: #selector(playTapped))
        configure(forwardButton, symbol: "goforward.10", size: 30, action: #selector(forwardTapped))
        configure(nextButton, symbol: "forward.end.fill", size: 22, action: #selector(nextTapped))

        let botoes = [previousButton, rewindButton, playButton, forwardButton, nextButton]
        for (indice, botao) in botoes.enumerated() {
            // Anterior/próxima ficam menores: são ações de saltar arquivo, não
            // de controlar o que está tocando, e não devem competir com o play.
            let lado: CGFloat = (indice == 0 || indice == botoes.count - 1) ? 56 : 74
            botao.widthAnchor.constraint(equalToConstant: lado).isActive = true
            botao.heightAnchor.constraint(equalToConstant: lado).isActive = true
            // Sombra em vez de fundo sólido: o vídeo continua visível atrás,
            // e o ícone se destaca mesmo sobre cena clara.
            botao.layer.shadowColor = UIColor.black.cgColor
            botao.layer.shadowOpacity = 0.55
            botao.layer.shadowRadius = 8
            botao.layer.shadowOffset = .zero
        }

        centerStack.axis = .horizontal
        centerStack.alignment = .center
        centerStack.spacing = 16
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        botoes.forEach(centerStack.addArrangedSubview)
        addSubview(centerStack)

        NSLayoutConstraint.activate([
            centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func setupBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBar)

        bottomGradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
        bottomBar.layer.insertSublayer(bottomGradient, at: 0)

        [elapsedLabel, remainingLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            $0.textColor = .white
            $0.text = "--:--"
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        slider.minimumTrackTintColor = tintColor
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(Self.thumbImage(diameter: 12), for: .normal)
        slider.setThumbImage(Self.thumbImage(diameter: 20), for: .highlighted)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchUp),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])

        setupToolRow()

        [elapsedLabel, slider, remainingLabel, toolRow].forEach(bottomBar.addSubview)

        NSLayoutConstraint.activate([
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 140),

            elapsedLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            elapsedLabel.bottomAnchor.constraint(equalTo: toolRow.topAnchor, constant: -14),

            remainingLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            remainingLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),

            toolRow.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            toolRow.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            toolRow.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            toolRow.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func setupToolRow() {
        configure(lockButton, symbol: "lock.open", action: #selector(lockTapped))
        configure(aspectButton, symbol: "rectangle.arrowtriangle.2.inward", action: #selector(aspectTapped))
        configure(rotateButton, symbol: "rotate.right", action: #selector(rotateTapped))

        speedButton.setTitle("1×", for: .normal)
        speedButton.tintColor = .white
        speedButton.setTitleColor(.white, for: .normal)
        speedButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        speedButton.translatesAutoresizingMaskIntoConstraints = false
        // Menu em vez de ciclar: ciclar entre seis velocidades obriga a passar
        // por todas para chegar na que se quer.
        speedButton.showsMenuAsPrimaryAction = true
        speedButton.menu = speedMenu()

        toolRow.axis = .horizontal
        toolRow.distribution = .equalSpacing
        toolRow.alignment = .center
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        [lockButton, speedButton, aspectButton, rotateButton].forEach(toolRow.addArrangedSubview)
    }

    private func setupUnlockButton() {
        configure(unlockButton, symbol: "lock.fill", action: #selector(lockTapped))
        unlockButton.alpha = 0
        addSubview(unlockButton)
        NSLayoutConstraint.activate([
            unlockButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            unlockButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            unlockButton.widthAnchor.constraint(equalToConstant: 46),
            unlockButton.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func configure(_ button: UIButton, symbol: String, size: CGFloat = 17,
                           weight: UIImage.SymbolWeight = .medium, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: size, weight: weight), forImageIn: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func speedMenu() -> UIMenu {
        let velocidades: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        let acoes = velocidades.map { velocidade in
            UIAction(title: Self.speedLabel(velocidade),
                     state: velocidade == currentSpeed ? .on : .off) { [weak self] _ in
                self?.applySpeed(velocidade)
            }
        }
        return UIMenu(title: "Velocidade", children: acoes)
    }

    private static func speedLabel(_ value: Float) -> String {
        value == rintf(value) ? "\(Int(value))×" : String(format: "%.2g×", value)
    }

    private func applySpeed(_ value: Float) {
        currentSpeed = value
        speedButton.setTitle(Self.speedLabel(value), for: .normal)
        speedButton.menu = speedMenu()
        onSpeedChange?(value)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        topGradient.frame = topBar.bounds
        bottomGradient.frame = bottomBar.bounds
    }

    private static func thumbImage(diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Atualizações vindas do player

    func update(currentTime: Double, duration: Double) {
        self.duration = duration
        guard !isUserScrubbing else { return }

        elapsedLabel.text = TimeFormat.clock(currentTime)
        remainingLabel.text = duration > 0 ? "−" + TimeFormat.clock(duration - currentTime) : "--:--"
        slider.value = duration > 0 ? Float(currentTime / duration) : 0
    }

    func apply(state: PlaybackState) {
        let symbol = (state == .playing) ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol), for: .normal)
        if state == .paused || state == .ended { setVisible(true, animated: true) }
    }

    /// Some com os saltos de faixa quando não há para onde ir — botão inerte
    /// na tela é pior que botão ausente.
    func setNavigation(hasPrevious: Bool, hasNext: Bool) {
        previousButton.isHidden = !hasPrevious && !hasNext
        nextButton.isHidden = previousButton.isHidden

        previousButton.isEnabled = hasPrevious
        nextButton.isEnabled = hasNext
        previousButton.alpha = hasPrevious ? 1 : 0.3
        nextButton.alpha = hasNext ? 1 : 0.3
    }

    func setAspectLabel(_ text: String) {
        aspectButton.setTitle(nil, for: .normal)
        // O rótulo aparece no HUD central; aqui só o ícone muda de ênfase.
        aspectButton.tintColor = text == "Ajustar" ? .white : tintColor
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard !isLocked, visible != isVisible else { return }
        isVisible = visible
        let alpha: CGFloat = visible ? 1 : 0
        let work = {
            self.topBar.alpha = alpha
            self.bottomBar.alpha = alpha
            self.centerStack.alpha = alpha
        }
        animated ? UIView.animate(withDuration: 0.22, animations: work) : work()
    }

    // MARK: - Ações

    @objc private func closeTapped()     { onClose?() }
    @objc private func playTapped()      { onPlayPause?() }
    @objc private func rewindTapped()    { onSeekRelative?(-10) }
    @objc private func forwardTapped()   { onSeekRelative?(10) }
    @objc private func previousTapped()  { onPrevious?() }
    @objc private func nextTapped()      { onNext?() }
    @objc private func aspectTapped()    { onCycleAspect?() }
    @objc private func rotateTapped()    { onRotate?() }
    @objc private func subtitlesTapped() { onShowTracks?(.subtitle) }
    @objc private func audioTapped()     { onShowTracks?(.audio) }

    @objc private func lockTapped() {
        isLocked.toggle()
        lockButton.setImage(UIImage(systemName: isLocked ? "lock.fill" : "lock.open"), for: .normal)

        UIView.animate(withDuration: 0.25) {
            let alpha: CGFloat = self.isLocked ? 0 : 1
            self.topBar.alpha = alpha
            self.bottomBar.alpha = alpha
            self.centerStack.alpha = alpha
            self.unlockButton.alpha = self.isLocked ? 0.85 : 0
        }
        isVisible = !isLocked
        onLockChange?(isLocked)
    }

    @objc private func sliderTouchDown() { isUserScrubbing = true }

    @objc private func sliderChanged() {
        guard duration > 0 else { return }
        let time = Double(slider.value) * duration
        elapsedLabel.text = TimeFormat.clock(time)
        remainingLabel.text = "−" + TimeFormat.clock(duration - time)
        onScrub?(time, false)
    }

    @objc private func sliderTouchUp() {
        isUserScrubbing = false
        guard duration > 0 else { return }
        onScrub?(Double(slider.value) * duration, true)
    }
}

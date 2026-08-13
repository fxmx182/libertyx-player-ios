import UIKit

/// Controles do player.
///
/// Disposição: barra superior com título e acessos; fileira de ferramentas que
/// abre sob demanda; e rodapé em duas linhas — tempo e barra em cima,
/// transporte embaixo. Nenhuma lógica de reprodução aqui: a view só emite
/// intenções, e é isso que permitiu trocar o motor sem tocar nela.
final class PlayerControlsView: UIView {

    // MARK: - Intenções

    var onPlayPause: (() -> Void)?
    var onClose: (() -> Void)?
    /// `finished == false` durante o arrasto (scrub ao vivo), `true` ao soltar.
    var onScrub: ((Double, Bool) -> Void)?
    var onSeekRelative: ((Double) -> Void)?
    var onShowTracks: ((TrackKind) -> Void)?
    var onLockChange: ((Bool) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onCycleAspect: (() -> Void)?
    var onTogglePiP: (() -> Void)?

    /// Montado na hora de abrir: os itens mostram estado que muda enquanto o
    /// player está aberto.
    var moreMenuProvider: (() -> [UIMenuElement])?

    enum TrackKind { case audio, subtitle }

    // MARK: - Estado

    private(set) var isVisible = true
    /// Bloqueio: esconde tudo e desliga os gestos. Existe porque assistir
    /// deitado significa encostar na tela sem querer o tempo todo.
    private(set) var isLocked = false
    /// Preferência do usuário, preservada entre aparições dos controles.
    /// Começa fechada para não cobrir o vídeo; o botão de grade abre.
    private(set) var isToolStripExpanded = false

    var title: String = "" {
        didSet { titleLabel.text = title }
    }

    private var duration: Double = 0
    private var isUserScrubbing = false

    // MARK: - Views

    private let topBar = UIView()
    private let bottomBar = UIView()
    private let topGradient = CAGradientLayer()
    private let bottomGradient = CAGradientLayer()

    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let toolsButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

    private let elapsedLabel = UILabel()
    private let totalLabel = UILabel()
    private let slider = UISlider()

    private let lockButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    /// Bloqueio, transporte e ajustes na mesma fileira, repartindo a largura.
    private let fileiraInferior = UIStackView()
    private let aspectButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)

    /// Aparece sozinho quando tudo está bloqueado.
    private let unlockButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    let toolStrip = ToolStripView()

    // MARK: - Ciclo de vida

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupTopBar()
        setupBottomBar()
        setupToolStrip()
        setupUnlockButton()
        setupSpinner()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    /// Só intercepta o toque se ele caiu sobre um controle visível — o resto
    /// atravessa para a camada de gestos.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isLocked {
            return unlockButton.frame.insetBy(dx: -12, dy: -12).contains(point)
        }
        // Escondida, a barra deixa o toque passar para os gestos; visível, ela
        // captura só onde há controle de verdade.
        guard isVisible else { return false }
        return topBar.frame.contains(point)
            || bottomBar.frame.contains(point)
            || (isToolStripExpanded && !toolStrip.isHidden && toolStrip.frame.contains(point))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        topGradient.frame = topBar.bounds
        bottomGradient.frame = bottomBar.bounds
    }

    // MARK: - Barra superior

    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)

        topGradient.colors = [UIColor.black.withAlphaComponent(0.8).cgColor, UIColor.clear.cgColor]
        topBar.layer.insertSublayer(topGradient, at: 0)

        configure(closeButton, symbol: "chevron.down", action: #selector(closeTapped))
        configure(toolsButton, symbol: "square.grid.2x2", action: #selector(toolsTapped))
        configure(subtitleButton, symbol: "captions.bubble", action: #selector(subtitlesTapped))
        configure(audioButton, symbol: "waveform", action: #selector(audioTapped))

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = .white
        moreButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 17, weight: .medium), forImageIn: .normal)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] concluir in
                concluir(self?.moreMenuProvider?() ?? [])
            }
        ])

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        [closeButton, titleLabel, toolsButton, subtitleButton, audioButton, moreButton]
            .forEach(topBar.addSubview)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 96),

            closeButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -14),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            moreButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            moreButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),

            audioButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
            audioButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            audioButton.widthAnchor.constraint(equalToConstant: 44),
            audioButton.heightAnchor.constraint(equalToConstant: 44),

            subtitleButton.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -4),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            subtitleButton.widthAnchor.constraint(equalToConstant: 44),
            subtitleButton.heightAnchor.constraint(equalToConstant: 44),

            toolsButton.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -4),
            toolsButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            toolsButton.widthAnchor.constraint(equalToConstant: 44),
            toolsButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: toolsButton.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
    }

    // MARK: - Rodapé

    /// Duas linhas: tempo e barra em cima, transporte embaixo.
    ///
    /// O play fica centralizado no rodapé, e não no meio da tela: ali ele
    /// cobre a imagem justamente onde a ação acontece. Tocar duas vezes no
    /// centro continua pausando — o gesto cobre o caso de querer pausar sem
    /// procurar botão.
    private func setupBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBar)

        bottomGradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
        bottomBar.layer.insertSublayer(bottomGradient, at: 0)

        [elapsedLabel, totalLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            $0.textColor = .white
            $0.text = "--:--"
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // Trilha desenhada, e não escalada: escalar o controle inteiro
        // engrossava a barra mas esticava o marcador junto, deixando-o oval.
        slider.setMinimumTrackImage(Self.trackImage(color: tintColor), for: .normal)
        slider.setMaximumTrackImage(Self.trackImage(color: UIColor.white.withAlphaComponent(0.3)),
                                    for: .normal)
        slider.setThumbImage(Self.thumbImage(diameter: 15), for: .normal)
        slider.setThumbImage(Self.thumbImage(diameter: 22), for: .highlighted)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchUp),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])

        configure(lockButton, symbol: "lock.open", size: 20, action: #selector(lockTapped))
        configure(previousButton, symbol: "backward.end.fill", size: 27, action: #selector(previousTapped))
        configure(playButton, symbol: "play.fill", size: 38, weight: .semibold, action: #selector(playTapped))
        configure(nextButton, symbol: "forward.end.fill", size: 27, action: #selector(nextTapped))
        configure(aspectButton, symbol: "arrow.left.and.right", size: 20, action: #selector(aspectTapped))
        configure(pipButton, symbol: "pip.enter", size: 20, action: #selector(pipTapped))

        // Área de toque generosa: o alvo confortável para o dedo é 44 pt, e
        // esses botões ficam perto da borda inferior, onde errar é mais fácil.
        [previousButton, nextButton].forEach {
            $0.widthAnchor.constraint(equalToConstant: 60).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 56).isActive = true
        }
        pipButton.isHidden = true

        // Uma fileira só, em partes iguais: ninguém pode invadir o vizinho.
        fileiraInferior.axis = .horizontal
        fileiraInferior.alignment = .center
        fileiraInferior.distribution = .fillEqually
        fileiraInferior.translatesAutoresizingMaskIntoConstraints = false
        [lockButton, previousButton, playButton, nextButton, aspectButton, pipButton]
            .forEach(fileiraInferior.addArrangedSubview)

        [elapsedLabel, slider, totalLabel, fileiraInferior].forEach(bottomBar.addSubview)

        NSLayoutConstraint.activate([
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 148),

            // Linha de baixo: uma fileira só, repartindo a largura.
            //
            // Antes cada botão tinha a sua âncora — bloqueio colado à esquerda,
            // transporte fixo no centro, ajustes à direita — e nada impedia que
            // se encontrassem no meio numa tela estreita. Duas tentativas de
            // remendar com limites falharam, porque o problema nunca foi
            // distância: era não haver ninguém encarregado de repartir o
            // espaço. Uma fileira com distribuição igual tem esse encarregado
            // por construção, e a sobreposição deixa de ser possível em
            // qualquer largura.
            fileiraInferior.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            fileiraInferior.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            fileiraInferior.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            fileiraInferior.heightAnchor.constraint(equalToConstant: 56),

            // Linha de cima: tempo decorrido, barra, duração total.
            elapsedLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            elapsedLabel.bottomAnchor.constraint(equalTo: fileiraInferior.topAnchor, constant: -14),

            totalLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            totalLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: totalLabel.leadingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),
        ])
    }

    private func setupToolStrip() {
        toolStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolStrip)
        NSLayoutConstraint.activate([
            toolStrip.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            toolStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolStrip.heightAnchor.constraint(equalToConstant: 86),
        ])
        toolStrip.alpha = 0
        toolStrip.isHidden = true
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

    private func setupSpinner() {
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configure(_ button: UIButton, symbol: String, size: CGFloat = 18,
                           weight: UIImage.SymbolWeight = .medium, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: size, weight: weight), forImageIn: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// Trilha com altura própria. O UISlider não expõe espessura, mas aceita
    /// uma imagem esticável — que é o jeito de engrossar sem deformar o resto.
    private static func trackImage(color: UIColor, height: CGFloat = 7) -> UIImage {
        let tamanho = CGSize(width: height, height: height)
        let imagem = UIGraphicsImageRenderer(size: tamanho).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: tamanho),
                         cornerRadius: height / 2).fill()
        }
        return imagem.resizableImage(
            withCapInsets: UIEdgeInsets(top: 0, left: height / 2, bottom: 0, right: height / 2))
    }

    private static func thumbImage(diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Atualizações

    func update(currentTime: Double, duration: Double) {
        self.duration = duration
        guard !isUserScrubbing else { return }

        elapsedLabel.text = TimeFormat.clock(currentTime)
        totalLabel.text = duration > 0 ? TimeFormat.clock(duration) : "--:--"
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

    func setPiPAvailable(_ available: Bool) {
        pipButton.isHidden = !available
    }

    /// Enquanto carrega, o transporte some e a roda aparece: sem esse aviso,
    /// espera pela rede é indistinguível de travamento.
    /// Enquanto o dedo arrasta, nenhum indicador aparece no centro — foi o
    /// pedido explícito, e faz sentido: ali o usuário quer ver a imagem, não
    /// um aviso de que ela está carregando.
    var suppressBuffering = false {
        didSet { if suppressBuffering { spinner.stopAnimating() } }
    }

    func setBuffering(_ buffering: Bool) {
        guard !suppressBuffering else { return }
        // Só a roda aparece e some. Antes o transporte era escondido junto, e
        // como o carregamento oscila durante a rolagem, os botões piscavam. A
        // roda fica no centro e o transporte no rodapé; não se atrapalham.
        buffering ? spinner.startAnimating() : spinner.stopAnimating()
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard !isLocked, visible != isVisible else { return }
        isVisible = visible
        applyVisibility(animated: animated)
    }

    /// Ponto único que decide o que aparece.
    ///
    /// Antes, cada ação mexia direto na transparência de cada peça, e os
    /// estados saíam de sincronia — o sintoma era a barra voltar sem as
    /// ferramentas. Calculando tudo a partir de `isVisible`, `isLocked` e
    /// `isToolStripExpanded` num lugar só, essa classe de bug deixa de existir.
    private func applyVisibility(animated: Bool) {
        let barras: CGFloat = (isVisible && !isLocked) ? 1 : 0
        let fileira: CGFloat = (isVisible && !isLocked && isToolStripExpanded) ? 1 : 0

        toolsButton.tintColor = isToolStripExpanded ? tintColor : .white
        if fileira > 0 {
            toolStrip.isHidden = false
            bringSubviewToFront(toolStrip)
        }

        let trabalho = {
            self.topBar.alpha = barras
            self.bottomBar.alpha = barras
            self.toolStrip.alpha = fileira
            self.unlockButton.alpha = self.isLocked ? 0.85 : 0
        }
        let depois = { (_: Bool) in
            // Transparente ainda receberia toque e roubaria gestos da área do
            // vídeo; escondida de verdade, não.
            self.toolStrip.isHidden = fileira == 0
        }
        if animated {
            UIView.animate(withDuration: 0.22, animations: trabalho, completion: depois)
        } else {
            trabalho()
            depois(true)
        }
    }

    /// Chamado também pela fileira de ferramentas.
    func toggleLock() { lockTapped() }

    // MARK: - Ações

    @objc private func closeTapped()     { onClose?() }
    @objc private func playTapped()      { onPlayPause?() }
    @objc private func previousTapped()  { onPrevious?() }
    @objc private func nextTapped()      { onNext?() }
    @objc private func subtitlesTapped() { onShowTracks?(.subtitle) }
    @objc private func audioTapped()     { onShowTracks?(.audio) }
    @objc private func aspectTapped()    { onCycleAspect?() }
    @objc private func pipTapped()       { onTogglePiP?() }

    @objc private func toolsTapped() {
        isToolStripExpanded.toggle()
        applyVisibility(animated: true)
    }

    @objc private func lockTapped() {
        isLocked.toggle()
        lockButton.setImage(UIImage(systemName: isLocked ? "lock.fill" : "lock.open"), for: .normal)
        isVisible = !isLocked
        applyVisibility(animated: true)
        onLockChange?(isLocked)
    }

    @objc private func sliderTouchDown() { isUserScrubbing = true }

    @objc private func sliderChanged() {
        guard duration > 0 else { return }
        let time = Double(slider.value) * duration
        elapsedLabel.text = TimeFormat.clock(time)
        onScrub?(time, false)
    }

    @objc private func sliderTouchUp() {
        isUserScrubbing = false
        guard duration > 0 else { return }
        onScrub?(Double(slider.value) * duration, true)
    }
}

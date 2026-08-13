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
    /// Desde quando está na tela.
    ///
    /// Serve para distinguir "o toque que trouxe a barra" de "um toque com a
    /// barra já na tela" sem depender de sinalizador algum: basta olhar o
    /// relógio. Um sinalizador precisa que dois eventos aconteçam sempre em
    /// par, e quando um falha ele trava — foi o que aconteceu.
    private(set) var visibleSince: Date? = Date()
    /// Bloqueio: esconde tudo e desliga os gestos. Existe porque assistir
    /// deitado significa encostar na tela sem querer o tempo todo.
    private(set) var isLocked = false
    /// Preferência do usuário, preservada entre aparições dos controles.
    /// Começa fechada para não cobrir o vídeo; o botão de grade abre.

    /// Guardado por compatibilidade com quem informa o título; a barra de
    /// cima saiu, e com ela o lugar onde ele aparecia.
    var title: String = ""

    private var duration: Double = 0
    private var isUserScrubbing = false

    // MARK: - Views

    private let bottomBar = UIView()
    private let bottomGradient = CAGradientLayer()

    private let toolsButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)

    private let elapsedLabel = UILabel()
    private let totalLabel = UILabel()
    private let slider = UISlider()
    /// Trilha própria atrás do controle: o fundo escuro e, sobre ele, o quanto
    /// já está carregado. O `UISlider` não sabe desenhar três camadas, então a
    /// dele fica transparente e estas duas ficam por baixo.
    private let trilhaFundo = UIView()
    private let trilhaCarregada = UIView()
    private var larguraCarregada: NSLayoutConstraint?

    private let previousButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    /// Transporte à esquerda, ajustes à direita.
    private let transporte = UIStackView()
    private let ajustes = UIStackView()
    private let aspectButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)

    /// Sair do vídeo. Sozinho no alto, sem barra em volta.
    private let closeButton = UIButton(type: .system)

    /// Aparece sozinho quando tudo está bloqueado.
    private let unlockButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)

    /// Toque no espaço vazio das barras — não num botão delas.
    var onBackgroundTap: (() -> Void)?

    // MARK: - Ciclo de vida

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupBottomBar()
        setupGestoDeFundo()
        setupCloseButton()
        setupUnlockButton()
        setupSpinner()

        // Quem decide o que está à mostra é sempre a mesma função, inclusive no
        // primeiro instante.
        //
        // Antes cada peça escolhia a própria opacidade inicial, e elas
        // discordavam: a barra nascia visível e o botão de sair nascia
        // invisível. Como só uma mudança de estado chamava essa função, a saída
        // só aparecia depois do primeiro ciclo de esconder e mostrar.
        applyVisibility(animated: false)
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
        return bottomBar.frame.contains(point)
            || closeButton.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bottomGradient.frame = bottomBar.bounds
    }

    // MARK: - Barra superior

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
        // Transparente de propósito: quem desenha o fundo agora é a trilha
        // própria, para caber a faixa do que já foi carregado entre os dois.
        slider.setMaximumTrackImage(Self.trackImage(color: .clear), for: .normal)

        trilhaFundo.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        trilhaCarregada.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        [trilhaFundo, trilhaCarregada].forEach {
            $0.layer.cornerRadius = 2.5
            $0.isUserInteractionEnabled = false
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        slider.setThumbImage(Self.thumbImage(diameter: 15), for: .normal)
        slider.setThumbImage(Self.thumbImage(diameter: 22), for: .highlighted)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        // Um toque na barra leva o vídeo até ali.
        //
        // O controle padrão do sistema só responde a arrasto a partir da
        // bolinha: tocar no meio da trilha não faz nada. Em vídeo isso
        // contraria o que todo mundo espera — apontar para um ponto é a forma
        // mais direta de dizer "quero ver isto aqui".
        slider.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                           action: #selector(sliderTapped)))
        slider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchUp),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])

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

        configure(subtitleButton, symbol: "captions.bubble", size: 20, action: #selector(subtitlesTapped))
        configure(audioButton, symbol: "music.note", size: 20, action: #selector(audioTapped))

        // A engrenagem guarda o resto: modo noturno, velocidade, captura,
        // temporizador, bloqueio, girar, fechar. Deixar tudo à mostra era o
        // que enchia a tela de ícones e disputava espaço com o filme.
        toolsButton.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        toolsButton.tintColor = .white
        toolsButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium), forImageIn: .normal)
        toolsButton.translatesAutoresizingMaskIntoConstraints = false
        toolsButton.showsMenuAsPrimaryAction = true
        toolsButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] concluir in
                concluir(self?.moreMenuProvider?() ?? [])
            }
        ])

        // Dois grupos, como no reprodutor da Apple: o transporte à esquerda,
        // os ajustes à direita, e o vídeo respirando no meio.
        transporte.axis = .horizontal
        transporte.alignment = .center
        transporte.spacing = 8
        transporte.translatesAutoresizingMaskIntoConstraints = false
        [previousButton, playButton, nextButton].forEach(transporte.addArrangedSubview)

        ajustes.axis = .horizontal
        ajustes.alignment = .center
        ajustes.spacing = 8
        ajustes.translatesAutoresizingMaskIntoConstraints = false
        [subtitleButton, audioButton, toolsButton, pipButton, aspectButton]
            .forEach(ajustes.addArrangedSubview)

        [elapsedLabel, trilhaFundo, trilhaCarregada, slider, totalLabel, transporte, ajustes]
            .forEach(bottomBar.addSubview)

        NSLayoutConstraint.activate([
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 118),

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
            transporte.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 10),
            transporte.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -2),
            transporte.heightAnchor.constraint(equalToConstant: 48),

            ajustes.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
            ajustes.centerYAnchor.constraint(equalTo: transporte.centerYAnchor),
            ajustes.heightAnchor.constraint(equalToConstant: 48),
            // Os dois grupos não podem se encontrar: com pouca largura, quem
            // cede é o da direita, encolhendo os ícones.
            ajustes.leadingAnchor.constraint(greaterThanOrEqualTo: transporte.trailingAnchor,
                                             constant: 12),

            // Linha de cima: tempo decorrido, barra, duração total.
            elapsedLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            elapsedLabel.bottomAnchor.constraint(equalTo: transporte.topAnchor, constant: -8),

            totalLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            totalLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: totalLabel.leadingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),

            // As trilhas seguem a do controle: a bolinha precisa de folga nas
            // pontas, e desenhar de borda a borda deixaria as três desalinhadas.
            trilhaFundo.leadingAnchor.constraint(equalTo: slider.leadingAnchor, constant: 2),
            trilhaFundo.trailingAnchor.constraint(equalTo: slider.trailingAnchor, constant: -2),
            trilhaFundo.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            trilhaFundo.heightAnchor.constraint(equalToConstant: 5),

            trilhaCarregada.leadingAnchor.constraint(equalTo: trilhaFundo.leadingAnchor),
            trilhaCarregada.centerYAnchor.constraint(equalTo: trilhaFundo.centerYAnchor),
            trilhaCarregada.heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    /// As barras cobrem boa parte da tela quando aparecem, e um toque em cima
    /// delas — fora de um botão — precisa esconder, como qualquer outro toque.
    private func setupGestoDeFundo() {
        bottomBar.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                              action: #selector(fundoTocado)))
    }

    /// A saída, e só ela, no alto.
    ///
    /// A barra de cima inteira era demais para um botão: título, ferramentas e
    /// um degradê ocupando um oitavo da tela. Um círculo discreto no canto faz
    /// o mesmo trabalho e devolve a imagem ao filme. O fundo translúcido existe
    /// porque uma seta branca some numa cena clara.
    private func setupCloseButton() {
        configure(closeButton, symbol: "chevron.down", size: 17, action: #selector(closeTapped))
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        closeButton.layer.cornerRadius = 19
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.widthAnchor.constraint(equalToConstant: 38),
            closeButton.heightAnchor.constraint(equalToConstant: 38),
        ])
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
    private static func trackImage(color: UIColor, height: CGFloat = 5) -> UIImage {
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

    /// O quanto já está carregado, em segundos de vídeo.
    func setBuffered(_ instante: Double) {
        guard duration > 0 else { return }
        let fracao = max(0, min(1, instante / duration))
        larguraCarregada?.isActive = false
        larguraCarregada = trilhaCarregada.widthAnchor.constraint(
            equalTo: trilhaFundo.widthAnchor, multiplier: max(0.0001, fracao))
        larguraCarregada?.isActive = true
    }

    func update(currentTime: Double, duration: Double) {
        self.duration = duration
        guard !isUserScrubbing else { return }

        elapsedLabel.text = TimeFormat.clock(currentTime)
        // Quanto falta, não quanto dura: é a conta que se faz de cabeça o
        // tempo todo enquanto se assiste.
        totalLabel.text = duration > 0
            ? "-" + TimeFormat.clock(max(0, duration - currentTime))
            : "--:--"
        slider.value = duration > 0 ? Float(currentTime / duration) : 0
    }

    func apply(state: PlaybackState) {
        let symbol = (state == .playing) ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol), for: .normal)
        if state == .paused || state == .ended { setVisible(true, animated: true) }
    }

    /// Some com os saltos de faixa quando não há para onde ir — botão inerte
    /// na tela é pior que botão ausente.
    /// Os saltos de faixa ficam sempre na tela, apagados quando não há para
    /// onde ir.
    ///
    /// Antes eles sumiam, e a fileira se reorganizava sozinha: a mesma posição
    /// passava a ter outro botão conforme o vídeo aberto. Um controle que muda
    /// de lugar é pior que um controle inerte — a mão já sabe onde estava.
    func setNavigation(hasPrevious: Bool, hasNext: Bool) {
        previousButton.isHidden = false
        nextButton.isHidden = false
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
        visibleSince = visible ? Date() : nil
        applyVisibility(animated: animated)
    }

    /// Ponto único que decide o que aparece.
    ///
    /// Antes, cada ação mexia direto na transparência de cada peça, e os
    /// estados saíam de sincronia — o sintoma era a barra voltar sem as
    /// ferramentas. Calculando tudo a partir de `isVisible`, `isLocked` e
    private func applyVisibility(animated: Bool) {
        let barras: CGFloat = (isVisible && !isLocked) ? 1 : 0
        let bloqueio: CGFloat = isLocked ? 0.85 : 0

        let aplicar = {
            self.bottomBar.alpha = barras
            self.closeButton.alpha = barras
            self.unlockButton.alpha = bloqueio
        }
        animated ? UIView.animate(withDuration: 0.22, animations: aplicar) : aplicar()
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

    @objc private func lockTapped() {
        isLocked.toggle()
        isVisible = !isLocked
        applyVisibility(animated: true)
        onLockChange?(isLocked)
    }

    @objc private func sliderTapped(_ gesto: UITapGestureRecognizer) {
        guard duration > 0 else { return }

        // A trilha não ocupa a largura inteira do controle: a bolinha precisa
        // caber nas pontas. Perguntar ao próprio controle onde ela está evita
        // um desvio que só apareceria perto do começo e do fim.
        let trilha = slider.trackRect(forBounds: slider.bounds)
        let ponto = gesto.location(in: slider)
        let fracao = max(0, min(1, (ponto.x - trilha.minX) / max(1, trilha.width)))

        slider.setValue(Float(fracao), animated: true)
        let destino = Double(fracao) * duration
        elapsedLabel.text = TimeFormat.clock(destino)
        onScrub?(destino, true)
    }

    @objc private func fundoTocado() { onBackgroundTap?() }

    @objc private func sliderTouchDown() { isUserScrubbing = true }

    @objc private func sliderChanged() {
        guard duration > 0 else { return }
        let time = Double(slider.value) * duration
        elapsedLabel.text = TimeFormat.clock(time)
        totalLabel.text = "-" + TimeFormat.clock(max(0, duration - time))
        onScrub?(time, false)
    }

    @objc private func sliderTouchUp() {
        isUserScrubbing = false
        guard duration > 0 else { return }
        onScrub?(Double(slider.value) * duration, true)
    }
}

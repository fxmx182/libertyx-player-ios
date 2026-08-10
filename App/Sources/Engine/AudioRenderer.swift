import AVFoundation

/// Saída de áudio — e, mais importante, o **relógio** da reprodução.
///
/// Vídeo é sincronizado ao áudio, nunca o contrário. O motivo é fisiológico:
/// o ouvido percebe uma falha de milissegundos no som, enquanto um quadro
/// repetido ou descartado passa despercebido. Todo player sério usa o áudio
/// como mestre; quem usa relógio de parede produz aquele descompasso que vai
/// crescendo ao longo do filme.
final class AudioRenderer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var format: AVAudioFormat?

    /// Instante do vídeo correspondente ao início do que está tocando agora.
    /// Muda a cada busca.
    private var baseTime: Double = 0
    private var isRunning = false

    var volume: Float {
        get { volumeBeforeMute }
        set {
            volumeBeforeMute = max(0, min(1, newValue))
            // Mexer no volume durante o mudo desfaz o mudo — é o que o usuário
            // espera ao deslizar o dedo para aumentar o som.
            if isMuted { isMuted = false }
            player.volume = volumeBeforeMute
        }
    }

    /// Alterar a taxa altera o tom junto. Corrigir isso exige um `AVAudioUnit`
    /// de time-pitch — vale a pena, mas depois de o básico funcionar.
    var rate: Float = 1.0

    func prepare(sampleRate: Double, channels: AVAudioChannelCount) throws {
        // Sem uma sessão de áudio ativa na categoria de reprodução, o
        // AVAudioEngine simplesmente não roda — e, como ele é o relógio do
        // player, o vídeo fica esperando um tempo que nunca avança. O sintoma
        // é tela congelada sem erro nenhum, que foi exatamente o que apareceu.
        let sessao = AVAudioSession.sharedInstance()
        try sessao.setCategory(.playback, mode: .moviePlayback)
        try sessao.setActive(true)

        // Float32 não-intercalado é o formato nativo do AVAudioEngine; pedir
        // qualquer outro faz o sistema converter a cada buffer.
        guard let formato = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                          channels: channels) else {
            throw PlaybackError.loadFailed("formato de áudio não suportado")
        }
        format = formato

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: formato)
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private var wantsPlay = false
    private var hasScheduled = false

    /// Não começa a tocar antes de existir som agendado.
    ///
    /// Esta é a correção do "áudio atrasado depois de adiantar": mandando o nó
    /// tocar com a fila vazia, ele roda em silêncio mas o relógio dele já
    /// avança — e como o vídeo segue esse relógio, a imagem corre à frente do
    /// som que ainda vai chegar. Depois de uma busca, esse buraco é justamente
    /// o tempo de ler do servidor.
    func play() {
        guard isRunning else { return }
        wantsPlay = true
        if hasScheduled { player.play() }
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func schedule(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
        hasScheduled = true
        if wantsPlay, !player.isPlaying { player.play() }
    }

    /// Descarta o que estava agendado e reancora o relógio — usado ao buscar.
    func reset(to time: Double) {
        player.stop()
        hasScheduled = false
        baseTime = time
    }

    /// Silenciar sem perder o volume escolhido.
    var isMuted = false {
        didSet { player.volume = isMuted ? 0 : volumeBeforeMute }
    }
    private var volumeBeforeMute: Float = 1.0

    /// Posição atual da reprodução, em segundos do vídeo.
    ///
    /// `nil` quando o áudio ainda não começou a render: quem chama deve usar
    /// outro relógio nesse intervalo, senão o vídeo trava esperando um tempo
    /// que ainda não existe.
    var currentTime: Double? {
        guard isRunning,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return baseTime + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    func stop() {
        player.stop()
        engine.stop()
        isRunning = false
    }
}

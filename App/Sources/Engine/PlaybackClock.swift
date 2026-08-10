import Foundation
import AVFoundation
import QuartzCore

/// O relógio da reprodução, consultável de qualquer thread.
///
/// Existe porque o laço de decodificação roda fora da thread principal e
/// precisa saber "que instante do filme é agora" a cada quadro. Perguntar isso
/// ao motor exigiria uma travessia síncrona para a thread principal a cada
/// 33 ms, e o vídeo engasgaria sempre que a interface estivesse ocupada.
///
/// A fonte preferida é o áudio: o ouvido percebe uma falha de milissegundos no
/// som, enquanto um quadro a mais ou a menos passa despercebido. O relógio de
/// parede só cobre dois casos — arquivos mudos, e o intervalo entre dar play e
/// o áudio efetivamente começar a render.
final class PlaybackClock {

    private let lock = NSLock()
    private weak var audio: AudioRenderer?

    private var base: Double = 0
    private var origin: CFTimeInterval = 0
    private var running = false
    private var rateValue: Double = 1
    private var generationValue = 0
    private var audioScheduledUntil: Double = 0

    init(audio: AudioRenderer) {
        self.audio = audio
    }

    /// Trocada a cada busca ou parada. O laço compara com a sua própria cópia
    /// e se encerra sozinho quando fica obsoleto — assim uma busca não precisa
    /// esperar o laço anterior terminar.
    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return generationValue
    }

    @discardableResult
    func invalidate() -> Int {
        lock.lock(); defer { lock.unlock() }
        generationValue += 1
        return generationValue
    }

    func start(at time: Double, rate: Double) {
        lock.lock()
        base = time
        origin = CACurrentMediaTime()
        rateValue = rate
        running = true
        lock.unlock()
    }

    func pause(at time: Double) {
        lock.lock()
        base = time
        running = false
        lock.unlock()
    }

    func reset(to time: Double) {
        lock.lock()
        base = time
        origin = CACurrentMediaTime()
        audioScheduledUntil = time
        lock.unlock()
    }

    /// Até onde o áudio já foi entregue. Serve de teto para o relógio de
    /// parede: sem isso, num arquivo cujo áudio atrasa para carregar, o vídeo
    /// dispararia à frente do som.
    func markAudioScheduled(until time: Double) {
        lock.lock()
        audioScheduledUntil = max(audioScheduledUntil, time)
        lock.unlock()
    }

    /// Ligado quando o arquivo tem faixa de áudio.
    ///
    /// Faz diferença no arranque: enquanto o áudio não começa a render, o
    /// relógio de parede já está correndo, e o vídeo dispara à frente do som.
    /// Quando o áudio enfim entra, a imagem está adiantada — e isso é
    /// percebido como áudio atrasado. Com esta trava, o vídeo espera o som.
    var expectsAudio = false

    var now: Double {
        if let doAudio = audio?.currentTime {
            lock.lock(); defer { lock.unlock() }
            // Teto no áudio já entregue.
            //
            // Este é o ponto que faltava. O nó de áudio continua "tocando"
            // quando fica sem som agendado — ele renderiza silêncio, e o
            // relógio dele avança do mesmo jeito. Numa leitura lenta pela rede,
            // que é exatamente o que acontece logo depois de adiantar, o
            // relógio corre durante o silêncio, o vídeo o segue, e quando o som
            // enfim chega a imagem já está à frente. O sintoma é "áudio
            // atrasado", mas a causa é o relógio adiantado.
            //
            // Limitando ao que de fato foi entregue, o vídeo espera o som em
            // vez de disparar na frente dele.
            //
            // A folga de 0,25 s evita travar a imagem no fim do arquivo, quando
            // o áudio acaba antes do vídeo — sem ela, os últimos quadros
            // ficariam presos esperando um som que não vem mais.
            return min(doAudio, audioScheduledUntil + 0.25)
        }

        lock.lock(); defer { lock.unlock() }
        guard running else { return base }
        if expectsAudio { return base }
        return base + (CACurrentMediaTime() - origin) * rateValue
    }
}

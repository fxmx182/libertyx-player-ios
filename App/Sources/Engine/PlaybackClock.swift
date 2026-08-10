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

    var now: Double {
        if let doAudio = audio?.currentTime { return doAudio }

        lock.lock(); defer { lock.unlock() }
        guard running else { return base }
        return base + (CACurrentMediaTime() - origin) * rateValue
    }
}

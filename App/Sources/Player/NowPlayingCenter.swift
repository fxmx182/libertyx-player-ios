import Foundation
import MediaPlayer
import UIKit

/// A ponte com o resto do iPhone: Dynamic Island, central de controle, tela
/// bloqueada, botão do fone de ouvido, carro.
///
/// Sem isto o sistema não sabe que somos nós que estamos tocando. O botão do
/// fone vai para o último app que se registrou — o Spotify, no caso — e ele
/// começa a tocar por cima do vídeo, que continua rodando mudo porque perdeu a
/// sessão de áudio.
///
/// Duas metades que precisam existir juntas: os comandos remotos dizem ao
/// sistema o que sabemos fazer, e o "now playing" diz o que está tocando. Só a
/// segunda não captura o botão do fone; só a primeira não aparece na ilha.
@MainActor
final class NowPlayingCenter {

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSkip: ((Double) -> Void)?

    /// Sem o `hasNext`/`hasPrevious` do app, a ilha mostraria setas mortas.
    var hasNext = false { didSet { commands.nextTrackCommand.isEnabled = hasNext } }
    var hasPrevious = false { didSet { commands.previousTrackCommand.isEnabled = hasPrevious } }

    private var commands: MPRemoteCommandCenter { .shared() }
    private var info: [String: Any] = [:]

    // MARK: - Ciclo de vida

    func activate() {
        // A sessão precisa ser nossa e estar ativa: é ela que diz ao sistema
        // quem é o app tocando agora. O VLC não a configura sozinho.
        do {
            let sessao = AVAudioSession.sharedInstance()
            try sessao.setCategory(.playback, mode: .moviePlayback)
            try sessao.setActive(true)
        } catch {
            LabLog.problem("sessão de áudio: \(error.localizedDescription)")
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()
        registrarComandos()
    }

    func deactivate() {
        limparComandos()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()

        // Fora da thread principal, e por um motivo prático: desativar a
        // sessão avisa todos os outros apps de áudio do aparelho, e isso pode
        // levar segundos. Feito aqui mesmo, a tela congelava na saída do vídeo
        // — parecia travamento do app e era só espera.
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Comandos

    private func registrarComandos() {
        limparComandos()

        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            self?.onPlay?()
            return .success
        }

        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        }

        // É este que o botão do meio do fone dispara.
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onToggle?()
            return .success
        }

        commands.nextTrackCommand.isEnabled = hasNext
        commands.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?()
            return .success
        }

        commands.previousTrackCommand.isEnabled = hasPrevious
        commands.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?()
            return .success
        }

        // Arrastar a barrinha na tela bloqueada.
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.addTarget { [weak self] evento in
            guard let evento = evento as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek?(evento.positionTime)
            return .success
        }

        commands.skipForwardCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] evento in
            let passo = (evento as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.onSkip?(passo)
            return .success
        }

        commands.skipBackwardCommand.isEnabled = true
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { [weak self] evento in
            let passo = (evento as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.onSkip?(-passo)
            return .success
        }
    }

    private func limparComandos() {
        let todos: [MPRemoteCommand] = [
            commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
            commands.nextTrackCommand, commands.previousTrackCommand,
            commands.changePlaybackPositionCommand,
            commands.skipForwardCommand, commands.skipBackwardCommand,
        ]
        todos.forEach { $0.removeTarget(nil) }
    }

    // MARK: - O que está tocando

    func update(title: String, currentTime: Double, duration: Double, rate: Float) {
        info[MPMediaItemPropertyTitle] = title
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// A capa que aparece na ilha e na tela bloqueada.
    func setArtwork(_ imagem: UIImage?) {
        if let imagem {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: imagem.size) { _ in imagem }
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

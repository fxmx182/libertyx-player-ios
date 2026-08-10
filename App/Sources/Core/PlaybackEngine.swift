import Foundation
import UIKit
import AVFoundation

enum PlaybackState: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

/// Contrato entre a interface e o motor de vídeo.
///
/// A interface toda (gestos, controles, biblioteca) é escrita contra esse
/// protocolo. Hoje existe uma implementação em AVPlayer, que é o suficiente
/// para validar o pipeline de build e a camada de gestos. A implementação
/// FFmpeg + VideoToolbox entra depois trocando só a fábrica em `PlayerModel`.
///
/// `beginScrub`/`endScrub` existem justamente por causa do MX Player: o motor
/// FFmpeg vai usar esses limites para manter um decodificador separado do de
/// reprodução, seekar para o keyframe anterior e decodificar até o frame exato
/// sem destruir o estado do playback.
@MainActor
protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }
    var currentTime: Double { get }
    var duration: Double { get }

    /// Velocidade de reprodução (1.0 normal). Usada pelo gesto de "segurar para 2x".
    var rate: Float { get set }
    /// Volume da aplicação, 0...1. Deliberadamente NÃO é o volume do sistema:
    /// mexer no volume do iOS por app exige truque com MPVolumeView, que a
    /// Apple pode quebrar a qualquer momento. Ganho próprio é estável.
    var volume: Float { get set }

    var onTimeUpdate: ((Double) -> Void)? { get set }
    var onStateChange: ((PlaybackState) -> Void)? { get set }
    /// Buscando ou enchendo o buffer. A interface usa isto para mostrar que a
    /// espera é carregamento — sem esse aviso, uma busca lenta pela rede é
    /// indistinguível de um travamento.
    var onBufferingChange: ((Bool) -> Void)? { get set }
    /// Texto da legenda a exibir agora, ou `nil` para limpar.
    var onSubtitle: ((String?) -> Void)? { get set }

    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var currentAudioTrack: Int32? { get }
    var currentSubtitleTrack: Int32? { get }

    var isMuted: Bool { get set }
    /// Quadro que está na tela agora, para captura de tela.
    func snapshot() -> UIImage?

    func selectAudioTrack(_ id: Int32) async
    /// `nil` desliga a legenda.
    func selectSubtitleTrack(_ id: Int32?) async

    func load(_ item: MediaItem) async throws
    func play()
    func pause()

    /// `precise == true` obriga o motor a parar no frame exato, sem cair no
    /// keyframe mais próximo. É o comportamento que falta no VLC do iOS.
    func seek(to time: Double, precise: Bool) async

    func beginScrub()
    func endScrub()

    /// Mostra o quadro daquele instante enquanto o dedo arrasta.
    ///
    /// Separado de `seek` de propósito: buscar para valer reinicia áudio,
    /// esvazia filas e recomeça o laço — caro demais para acontecer dezenas de
    /// vezes por segundo. Isto só decodifica e desenha.
    func scrub(to time: Double)

    /// Camada onde o vídeo é desenhado; a view controller insere na hierarquia.
    func makeRenderView() -> UIView
    func teardown()
}

/// Uma faixa selecionável dentro do arquivo.
struct MediaTrack: Identifiable, Hashable {
    /// Índice do stream no contêiner — é por ele que a troca é pedida.
    let id: Int32
    var codec: String
    var language: String?
    var title: String?
    /// Legenda em bitmap (PGS, DVD): imagem, não texto.
    var isBitmap: Bool = false

    /// Rótulo pronto para a lista: idioma quando existe, título quando não,
    /// e o codec como último recurso.
    var label: String {
        if let idioma = MediaInfo.languageName(language) {
            if let title, !title.isEmpty { return "\(idioma) — \(title)" }
            return idioma
        }
        if let title, !title.isEmpty { return title }
        return "Faixa \(id) (\(codec.uppercased()))"
    }
}

/// Superfícies de vídeo que sabem mudar o enquadramento.
///
/// Existe porque cada motor traz a sua: o AVPlayer desenha numa AVPlayerLayer,
/// o FFmpeg numa AVSampleBufferDisplayLayer. O gesto de pinça fala com esta
/// abstração e não precisa saber qual está em uso.
@MainActor
protocol VideoGravityAdjustable: AnyObject {
    func setGravity(_ gravity: AVLayerVideoGravity)
}

enum PlaybackError: LocalizedError {
    case unsupportedOrigin
    case securityScopeDenied
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOrigin:
            return "Esta origem ainda não é suportada por este motor."
        case .securityScopeDenied:
            return "Sem permissão para ler o arquivo. Selecione a pasta novamente."
        case .loadFailed(let reason):
            return "Falha ao carregar: \(reason)"
        }
    }
}

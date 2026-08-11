import Foundation

/// Qual motor de vídeo usar.
///
/// Os dois têm forças opostas, e nenhum vence em tudo:
///
/// - **Próprio** (FFmpeg + VideoToolbox): decodifica quadro exato, o que
///   permite rolagem integral, e desenha na camada do sistema, o que permite
///   janela flutuante. Em compensação, o buffer de rede é ingênuo perto do
///   VLC — foi ele que travava no servidor.
/// - **VLC**: vinte anos de sincronia, buffer e recuperação de erro, e fala SMB
///   nativamente. Mas desenha por conta própria (sem PiP) e busca por
///   keyframe (sem rolagem quadro a quadro).
///
/// No automático, cada um vai para onde é melhor: o próprio nos arquivos do
/// aparelho e do pendrive, onde não há rede para atrapalhar; o VLC na rede.
enum EnginePreference: String, CaseIterable {
    case automatic
    case own
    case vlc

    var label: String {
        switch self {
        case .automatic: return "Automático"
        case .own:       return "Próprio (FFmpeg)"
        case .vlc:       return "VLC"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "VLC — o mais confiável hoje"
        case .own:       return "Experimental: rolagem quadro a quadro e PiP"
        case .vlc:       return "Mais robusto em rede e formatos raros"
        }
    }

    private static let chave = "labplayer.enginePreference"

    static var current: EnginePreference {
        get {
            guard let bruto = UserDefaults.standard.string(forKey: chave),
                  let valor = EnginePreference(rawValue: bruto) else { return .automatic }
            return valor
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: chave) }
    }

    /// Decide para um item concreto.
    func resolve(for origin: MediaOrigin) -> Resolved {
        switch self {
        case .own: return .own
        case .vlc: return .vlc
        case .automatic:
            // VLC em tudo.
            //
            // A ideia de mandar arquivos locais para o motor próprio custou
            // regressões imediatas: um vídeo que fechava o app e um filme que
            // deixou de abrir. Enquanto o motor próprio não estiver estável, o
            // padrão não pode ser ele — quem escolhe experimentar aceita o
            // risco; quem só quer assistir, não.
            return .vlc
        }
    }

    enum Resolved { case own, vlc }
}

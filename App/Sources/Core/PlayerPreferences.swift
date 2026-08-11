import Foundation

/// Preferências do reprodutor que sobrevivem ao fechamento do app.
///
/// Só entra aqui o que é gosto pessoal e não estado de um vídeo específico —
/// estado de vídeo é assunto do `ResumeStore`.
enum PlayerPreferences {

    private static let defaults = UserDefaults.standard

    // MARK: - Tempo até a interface sumir

    /// Quanto tempo os controles ficam na tela sem toque.
    ///
    /// Não existe um número certo aqui: o MX Player também não escolhe um, ele
    /// oferece a opção ("Interface auto hide") justamente porque quem assiste
    /// deitado no escuro quer uma coisa e quem está mexendo no vídeo quer
    /// outra. Copiamos o ajuste, não o padrão dele — que é mais curto que o
    /// nosso e seria um passo para trás.
    enum AutoHide: Double, CaseIterable {
        case dois = 2
        case cinco = 5
        case dez = 10
        /// Só some com um toque na tela.
        case nunca = 0

        var title: String {
            switch self {
            case .nunca: return "Nunca"
            default: return "\(Int(rawValue)) segundos"
            }
        }

        /// `nil` quer dizer "não agende nada".
        var delay: TimeInterval? {
            self == .nunca ? nil : rawValue
        }
    }

    private static let autoHideKey = "controls.autoHide"

    /// 10 segundos de padrão, o teto do que o MX Player oferece.
    ///
    /// Ser generoso aqui não custa nada: um toque na tela esconde a barra na
    /// hora, então quem se incomoda tem saída imediata — enquanto quem perde a
    /// barra rápido demais fica tocando na tela de novo e de novo.
    static var autoHide: AutoHide {
        get {
            guard defaults.object(forKey: autoHideKey) != nil else { return .dez }
            return AutoHide(rawValue: defaults.double(forKey: autoHideKey)) ?? .dez
        }
        set { defaults.set(newValue.rawValue, forKey: autoHideKey) }
    }
}

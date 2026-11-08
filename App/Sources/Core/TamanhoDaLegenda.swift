import Foundation
import MobileVLCKit

/// O tamanho do texto da legenda, em porcentagem do normal. Vale para todos os vídeos.
///
/// O VLC 3 só lê esse tamanho (`--sub-text-scale`) quando o motor nasce —
/// nem por vídeo, nem com o vídeo tocando. Por isso cada tamanho tem a sua
/// biblioteca do VLC, e mudar o tamanho é refazer o reprodutor no mesmo ponto
/// (ver `VLCEngine.refazerComTamanhoDaLegenda`).
enum TamanhoDaLegenda {
    static let opcoes = [50, 60, 70, 80, 90, 100, 115, 130, 150, 175, 200, 250, 300]
    private static let chave = "libertyx.legenda.tamanho"

    static var atual: Int {
        get {
            let lido = UserDefaults.standard.integer(forKey: chave)
            return lido == 0 ? 100 : lido
        }
        set { UserDefaults.standard.set(newValue, forKey: chave) }
    }

    /// No tamanho normal, a biblioteca de sempre; nos outros, uma por tamanho,
    /// guardada — a pessoa costuma ir e voltar entre dois ou três.
    @MainActor
    static func biblioteca() -> VLCLibrary {
        let escala = atual
        if escala == 100 { return VLCLibrary.shared() }
        if let pronta = bibliotecas[escala] { return pronta }
        let nova = VLCLibrary(options: ["--sub-text-scale=\(escala)"])
        // O registro de erros escuta a biblioteca de sempre; esta também.
        nova.loggers = VLCLibrary.shared().loggers
        bibliotecas[escala] = nova
        return nova
    }

    @MainActor private static var bibliotecas: [Int: VLCLibrary] = [:]
}

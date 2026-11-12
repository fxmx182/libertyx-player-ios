import Foundation

/// O tamanho do texto da legenda, em porcentagem do normal. Vale para todos os vídeos.
///
/// O VLC 4 muda esse tamanho com o filme tocando (`VLCEngine.aplicarTamanhoDaLegenda`).
/// No VLC 3 ele só era lido quando o motor nascia, e cada mudança refazia o
/// reprodutor no mesmo ponto.
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

    /// Como o VLC recebe: 1 é o tamanho normal.
    static var escala: Float { Float(atual) / 100 }
}

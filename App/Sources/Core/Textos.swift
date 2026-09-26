import Foundation

// O app fala a língua do aparelho: português, inglês ou espanhol, e inglês
// para qualquer outra. Os textos continuam escritos em português no código —
// são a chave de busca nas tabelas de `en.lproj` e `es.lproj`; em português,
// sem tradução a achar, sai a própria chave.

/// Quantidades com o plural certo de cada língua ("1 vídeo", "2 vídeos").
/// As formas moram em `Localizable.stringsdict`.
enum Plural {
    static func videos(_ n: Int) -> String { String(localized: "\(n) vídeos") }
    static func pastas(_ n: Int) -> String { String(localized: "\(n) pastas") }
    static func minutos(_ n: Int) -> String { String(localized: "\(n) minutos") }
    static func segundos(_ n: Int) -> String { String(localized: "\(n) segundos") }
}

/// Números no formato do país: "1,5×" aqui, "1.5×" lá fora.
enum Formato {
    /// A velocidade sem casas sobrando: "2×", "1,5×", "0,75×".
    static func velocidade<T: BinaryFloatingPoint>(_ v: T) -> String {
        Double(v).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    /// Uma fração como porcentagem inteira: 0,85 → "85%".
    static func porcento<T: BinaryFloatingPoint>(_ v: T) -> String {
        Double(v).formatted(.percent.precision(.fractionLength(0)))
    }
}

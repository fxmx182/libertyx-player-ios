import SwiftUI
import CoreText

/// A linguagem visual do app.
///
/// Estrutura emprestada do painel do datacenter — paleta de sistema da Apple no
/// tom escuro, superfícies de vidro sobre fundo profundo, cantos generosos e
/// tipografia com espaçamento apertado. Cor vinda da marca do app: o amarelo
/// que está no ícone.
///
/// Emprestada, não copiada. Lá é uma página web imitando um app da Apple; aqui
/// já somos um app da Apple, então não faz sentido reconstruir o que o sistema
/// entrega pronto — folhas, menus e listas continuam sendo os nativos. O que
/// vem do painel é a **identidade**: a cor, o peso do texto, o formato das
/// superfícies. O resto é iOS sendo iOS.
enum LabTheme {

    // MARK: - Cor

    /// O amarelo da marca, colhido do próprio ícone.
    ///
    /// Substitui o ciano emprestado do painel: agora existe uma identidade
    /// própria, e o acento tem que ser dela. Sobre preto ele rende ainda mais
    /// contraste que o ciano, que é o que importa num app cujo fundo é imagem
    /// escura quase o tempo todo.
    static let accent = Color(red: 0.984, green: 0.773, blue: 0.004)    // #fbc501
    static let accentUI = UIColor(red: 0.984, green: 0.773, blue: 0.004, alpha: 1)

    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)     // #30d158
    static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)      // #ff9f0a
    static let red = Color(red: 1.0, green: 0.271, blue: 0.227)         // #ff453a

    /// Os três níveis de texto do sistema em modo escuro. Usar exatamente
    /// estes valores é o que faz o app parecer nativo em vez de "escuro".
    static let text = Color(white: 1, opacity: 0.94)
    static let muted = Color(red: 0.922, green: 0.922, blue: 0.961, opacity: 0.6)
    static let faint = Color(red: 0.922, green: 0.922, blue: 0.961, opacity: 0.38)

    // MARK: - Superfície

    /// Vidro: um véu claro sobre o fundo, com a borda um pouco mais viva que o
    /// preenchimento. É essa diferença que dá a impressão de espessura.
    static let glass = Color(white: 1, opacity: 0.07)
    static let glassBorder = Color(white: 1, opacity: 0.13)

    /// Fundo mais fundo que o preto do sistema não existe — mas um cinza muito
    /// escuro faz o vidro ter de onde emergir.
    static let background = Color(red: 0.055, green: 0.055, blue: 0.063)

    // MARK: - Forma

    static let radiusCard: CGFloat = 18
    static let radiusSmall: CGFloat = 12
}

/// A letra do app: Manrope, a mesma do irmão Android.
///
/// A San Francisco do sistema é a letra de todo app de iPhone — e de nenhum em
/// particular. A Manrope tem o mesmo desenho limpo, mas com o "a" e o "g" mais
/// abertos e números de largura constante quando se pede, o que deixa duração
/// e tamanho alinhados sem esforço.
///
/// Se o arquivo não carregar, cai na do sistema no mesmo peso — nunca num texto
/// quebrado.
enum LabFont {

    private static func nome(_ peso: UIFont.Weight) -> String {
        switch peso {
        case .heavy, .black:  return "Manrope-ExtraBold"
        case .bold:           return "Manrope-Bold"
        case .semibold:       return "Manrope-SemiBold"
        case .medium:         return "Manrope-Medium"
        default:              return "Manrope-Regular"
        }
    }

    /// Para UIKit. `mono` liga os números de largura fixa — tempo que muda
    /// de dígito não pode ficar sambando na tela.
    static func ui(_ tamanho: CGFloat, _ peso: UIFont.Weight = .regular, mono: Bool = false) -> UIFont {
        guard let base = UIFont(name: nome(peso), size: tamanho) else {
            return mono ? .monospacedDigitSystemFont(ofSize: tamanho, weight: peso)
                        : .systemFont(ofSize: tamanho, weight: peso)
        }
        guard mono else { return base }
        let descritor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]]
        ])
        return UIFont(descriptor: descritor, size: tamanho)
    }

    /// Para SwiftUI. Acompanha o tamanho de texto escolhido nos ajustes do
    /// iPhone, como a letra do sistema faria.
    static func swiftUI(_ tamanho: CGFloat, _ peso: UIFont.Weight = .regular) -> Font {
        Font.custom(nome(peso), size: tamanho)
    }
}

extension LabTheme {
    /// O título grande de cada tela — pesado e apertado, como capa de revista.
    static let headline = LabFont.swiftUI(32, .heavy)
}

extension View {

    /// Uma superfície de vidro — cartão, linha de lista, painel.
    func labCard(radius: CGFloat = LabTheme.radiusCard) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LabTheme.glass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5)
        )
    }

    /// Título de seção do jeito do painel: caixa alta, pequeno, espaçado.
    ///
    /// O contrário da tipografia do corpo, que é apertada. A diferença entre as
    /// duas é o que organiza a tela sem precisar de linha divisória.
    func labSectionTitle() -> some View {
        font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(LabTheme.faint)
    }
}

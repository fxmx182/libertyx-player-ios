import SwiftUI
import UIKit

/// A tela do LibertyX Pro: o que ele libera, a situação do teste, comprar pelo Telegram e
/// ativar a chave. Aberta das opções, ou no lugar de um recurso Pro depois do teste
/// ([ProPortao], [Pro.exigir]).
struct ProView: View {

    /// O recurso que trouxe a pessoa até aqui, aceso na lista.
    var pedido: Pro.Recurso? = nil
    /// Mostra o X de fechar (quando é apresentada por cima de outra tela).
    var aoFechar: (() -> Void)? = nil

    @ObservedObject private var pro = Pro.shared
    @State private var digitandoChave = false

    static let bot = URL(string: "https://t.me/libertx_partition_bot?start=player")!

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let aoFechar {
                    HStack {
                        Button(action: aoFechar) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(LabTheme.text)
                                .frame(width: 40, height: 40)
                                .background(LabTheme.glass, in: Circle())
                        }
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                Image("AppIconSymbol").resizable().scaledToFit().frame(width: 84, height: 84)
                    .padding(.top, 10)
                HStack(spacing: 8) {
                    Text("LibertyX").font(LabFont.headline).foregroundStyle(LabTheme.text)
                    Text("PRO")
                        .font(.system(size: 15, weight: .heavy)).kerning(1.5)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(LabTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.top, 14)
                situacao.padding(.top, 12)

                VStack(spacing: 2) {
                    ForEach(Pro.Recurso.allCases) { r in
                        linha(r, destaque: r == pedido && pro.estado == .expirado)
                    }
                }
                .padding(.vertical, 6)
                .labCard()
                .padding(.top, 22)

                Text("Todo o resto é grátis para sempre: biblioteca, player, gestos, busca quadro a quadro, legendas e faixas de áudio.")
                    .font(LabFont.swiftUI(13)).foregroundStyle(LabTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)

                if pro.estado != .comprado {
                    Link(destination: Self.bot) {
                        VStack(spacing: 2) {
                            Text("Pagar com Bitcoin ou USDT")
                                .font(LabFont.swiftUI(16, .heavy))
                            Text("Pelo Telegram — a chave chega na hora")
                                .font(LabFont.swiftUI(12)).opacity(0.7)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LabTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.top, 24)
                    Text("Pagamento único, sem assinatura. A mesma chave vale no iPhone, no Android e na TV.")
                        .font(LabFont.swiftUI(12)).foregroundStyle(LabTheme.faint)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                    Button("Tenho uma chave") { digitandoChave = true }
                        .font(LabFont.swiftUI(14, .semibold)).foregroundStyle(LabTheme.muted)
                        .padding(.vertical, 12)
                } else if let id = pro.licenca {
                    Text("Licença \(id)").font(LabFont.swiftUI(12)).foregroundStyle(LabTheme.faint).padding(.top, 20)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) {
            RadialGradient(colors: [LabTheme.accent.opacity(0.20), .clear], center: UnitPoint(x: 0.5, y: 0.18),
                           startRadius: 0, endRadius: 300)
                .frame(height: 480).allowsHitTesting(false)
        }
        .background(LabTheme.background.ignoresSafeArea())
        .onAppear { pro.recalcular() }
        .sheet(isPresented: $digitandoChave) { ChaveView() }
    }

    @ViewBuilder private var situacao: some View {
        let (texto, cor): (String, Color) = {
            switch pro.estado {
            case .comprado: return (String(localized: "Pro ativo — obrigado!"), LabTheme.green)
            case .teste(let dias): return (String(localized: "Teste grátis: \(dias) dias restantes"), LabTheme.accent)
            case .expirado: return (String(localized: "Seu teste grátis terminou"), LabTheme.muted)
            }
        }()
        HStack(spacing: 6) {
            if pro.estado == .comprado {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
            }
            Text(texto).font(LabFont.swiftUI(13, .bold))
        }
        .foregroundStyle(cor)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(cor.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(cor.opacity(0.45), lineWidth: 0.5))
    }

    private func linha(_ r: Pro.Recurso, destaque: Bool) -> some View {
        let (simbolo, titulo, texto): (String, LocalizedStringKey, LocalizedStringKey) = {
            switch r {
            case .rede: return ("server.rack", "Pastas da rede", "Assista direto do PC, NAS ou HD de rede — nada para copiar.")
            case .segundoPlano: return ("headphones", "Áudio em segundo plano", "Continue ouvindo com a tela apagada ou em outro app.")
            case .dormir: return ("timer", "Tempo para dormir", "Pausa sozinho na hora que você escolher.")
            case .captura: return ("camera", "Captura de quadro", "Salva a cena na galeria, na resolução do vídeo.")
            }
        }()
        return HStack(spacing: 14) {
            Image(systemName: simbolo)
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(LabTheme.accent)
                .frame(width: 40, height: 40)
                .background(LabTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(LabFont.swiftUI(15, .bold)).foregroundStyle(LabTheme.text)
                Text(texto).font(LabFont.swiftUI(13)).foregroundStyle(LabTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(destaque ? LabTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(destaque ? LabTheme.accent.opacity(0.6) : .clear, lineWidth: 1))
        .padding(.horizontal, 6)
    }
}

/// Colar a chave que o bot mandou no Telegram.
struct ChaveView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = Pro.shared
    @State private var texto = ""
    @State private var erro: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if pro.estado == .comprado {
                        Label("Pro ativado com a sua chave — obrigado!", systemImage: "checkmark.circle.fill")
                            .font(LabFont.swiftUI(17, .bold)).foregroundStyle(LabTheme.green)
                            .padding(.top, 20)
                        if let id = pro.licenca {
                            Text("Licença \(id)").font(LabFont.swiftUI(12)).foregroundStyle(LabTheme.faint)
                        }
                    } else {
                        Text("Cole a chave que o bot da LibertyX mandou no Telegram. Ela começa com LXP1.")
                            .font(LabFont.swiftUI(14)).foregroundStyle(LabTheme.muted)
                        TextEditor(text: $texto)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 110)
                            .background(LabTheme.glass, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
                            .onChange(of: texto) { erro = nil }
                        if let erro {
                            Text(erro).font(LabFont.swiftUI(13)).foregroundStyle(LabTheme.red)
                        }
                        HStack(spacing: 10) {
                            Button {
                                if let colado = UIPasteboard.general.string { texto = colado.trimmingCharacters(in: .whitespacesAndNewlines) }
                            } label: {
                                Text("Colar").font(LabFont.swiftUI(16, .bold)).foregroundStyle(LabTheme.text)
                                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                                    .background(LabTheme.glass, in: RoundedRectangle(cornerRadius: 16))
                            }
                            Button {
                                if case .recusada(let e) = pro.ativar(texto) { erro = Self.mensagem(e) }
                            } label: {
                                Text("Ativar").font(LabFont.swiftUI(16, .heavy)).foregroundStyle(.black)
                                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                                    .background(LabTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                        Link("Ainda não tem chave? Compre pelo Telegram", destination: ProView.bot)
                            .font(LabFont.swiftUI(14, .semibold)).foregroundStyle(LabTheme.muted)
                            .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .background(LabTheme.background.ignoresSafeArea())
            .navigationTitle("Ativar com uma chave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Concluído") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    static func mensagem(_ e: Chave.Erro) -> String {
        switch e {
        case .formato: return String(localized: "Isso não parece uma chave completa. Copie de novo no Telegram e cole inteira.")
        case .invalida: return String(localized: "Esta chave não é válida. Confira se copiou ela toda.")
        case .outroApp: return String(localized: "Esta chave é de outro app LibertyX, não do Player.")
        case .versao: return String(localized: "Esta chave é de uma versão mais nova. Atualize o app e tente de novo.")
        }
    }
}

/// No lugar de uma tela Pro: mostra a tela quando o Pro está ativo, e a do Pro quando não —
/// e troca sozinho quando a chave é ativada.
struct ProPortao<Conteudo: View>: View {
    let recurso: Pro.Recurso
    @ViewBuilder var conteudo: () -> Conteudo
    @ObservedObject private var pro = Pro.shared

    var body: some View {
        if pro.ativo { conteudo() } else { ProView(pedido: recurso) }
    }
}

extension Pro {
    /// A porta dos recursos Pro no player (UIKit): true quando liberado; senão apresenta a tela
    /// do Pro por cima e devolve false.
    func exigir(_ recurso: Recurso, de vc: UIViewController) -> Bool {
        recalcular()
        if ativo { return true }
        weak var tela: UIViewController?
        let hospedeiro = UIHostingController(rootView: ProView(pedido: recurso, aoFechar: { tela?.dismiss(animated: true) }))
        hospedeiro.overrideUserInterfaceStyle = .dark
        tela = hospedeiro
        vc.present(hospedeiro, animated: true)
        return false
    }
}

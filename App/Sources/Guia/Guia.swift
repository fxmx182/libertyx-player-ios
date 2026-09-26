import SwiftUI

/// O guia da primeira abertura.
///
/// Os gestos são o que o LibertyX tem de melhor, e são invisíveis: nada na tela
/// diz que segurar acelera ou que afastar o dedo da barra afina a rolagem. Um
/// texto explicando não ensina — o dedo aprende fazendo. Por isso cada página
/// tem uma tela de player de mentira onde o gesto funciona de verdade, e a
/// página só dá o "isso!" depois que ele foi feito.
///
/// Nunca prende: "Próximo" e "Pular" funcionam sem fazer gesto nenhum. Aparece
/// uma vez, na primeira abertura, e pode ser revisto em Visualização › Ver o
/// guia. É o mesmo guia do Android, com o que muda no iPhone: a engrenagem no
/// lugar dos três pontos e a pasta autorizada no lugar da permissão.
enum Guia {
    /// A mesma chave do `@AppStorage` da raiz — apagá-la mostra o guia de novo.
    static let chave = "guia.visto.v1"

    /// Pede o guia de volta, depois de a folha que pediu terminar de fechar:
    /// apresentar por cima de uma folha ainda saindo é recusado pelo iOS.
    static func mostrarDeNovo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            UserDefaults.standard.set(false, forKey: chave)
        }
    }
}

private let ouro = LabTheme.accent
private let vidro = Color(red: 0.043, green: 0.043, blue: 0.055, opacity: 0.8)

struct GuiaDeBoasVindas: View {
    let onFim: () -> Void

    @State private var pagina = 0
    @State private var feitas: Set<Int> = []
    @State private var pulso = false

    private let paginas = Pagina.todas
    private var ultima: Bool { pagina == paginas.count - 1 }

    var body: some View {
        ZStack {
            LabTheme.background.ignoresSafeArea()
            // Uma luz dourada no alto, a mesma da biblioteca — o guia já é o app.
            GeometryReader { geo in
                RadialGradient(colors: [ouro.opacity(0.13), .clear],
                               center: UnitPoint(x: 0.2, y: 0),
                               startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.7)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topo
                // A página desliza com o dedo fora das demonstrações; dentro
                // delas, o gesto é da demonstração — é lá que ele se aprende.
                TabView(selection: $pagina) {
                    ForEach(paginas.indices, id: \.self) { i in
                        PaginaDoGuia(pagina: paginas[i], indice: i, total: paginas.count,
                                     feita: feitas.contains(i)) {
                            if !feitas.contains(i) {
                                withAnimation(.easeOut(duration: 0.25)) { _ = feitas.insert(i) }
                            }
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                pe
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Topo: onde se está e a saída.
    private var topo: some View {
        HStack(spacing: 8) {
            Image("AppIconSymbol").resizable().scaledToFit().frame(width: 24, height: 24)
            Text("Guia rápido")
                .font(LabFont.swiftUI(13, .semibold))
                .foregroundStyle(LabTheme.muted)
            Spacer()
            if !ultima {
                Button(action: onFim) {
                    Text("Pular")
                        .font(LabFont.swiftUI(14, .semibold))
                        .foregroundStyle(LabTheme.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .transition(.opacity)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.2), value: ultima)
    }

    /// Pé: os pontos e o próximo passo.
    private var pe: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(paginas.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == pagina ? ouro : feitas.contains(i) ? ouro.opacity(0.45) : .white.opacity(0.18))
                        .frame(width: i == pagina ? 22 : 6, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: pagina)
            Spacer()

            // O botão chama quando a página foi feita: o gesto saiu, é hora
            // de seguir.
            let chama = feitas.contains(pagina) || ultima
            Button {
                if ultima { onFim() } else { withAnimation { pagina += 1 } }
            } label: {
                Text(ultima ? String(localized: "Começar") : String(localized: "Próximo"))
                    .font(LabFont.swiftUI(15, .heavy))
                    .foregroundStyle(Color(red: 0.10, green: 0.08, blue: 0.02))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(ouro, in: Capsule())
                    .background(
                        Capsule()
                            .fill(ouro.opacity(chama ? (pulso ? 0.28 : 0.10) : 0))
                            .padding(-6)
                    )
                    .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: ultima)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulso = true }
        }
    }
}

// MARK: - A página

private struct Pagina {
    let etiqueta: String
    let titulo: String
    let texto: String
    /// O convite para experimentar; `nil` na página que não tem gesto.
    let tente: String?
    let feito: String
    let demo: (@escaping () -> Void) -> AnyView

    static var todas: [Pagina] {
        let player = String(localized: "No player")
        return [
            Pagina(etiqueta: String(localized: "Bem-vindo"),
                   titulo: String(localized: "O seu cinema, sem limites"),
                   texto: String(localized: "O LibertyX abre praticamente tudo — MKV, HEVC, 4K HDR, legendas ASS e PGS, várias faixas de áudio — do aparelho, do pendrive ou do computador de casa. Em um minuto você aprende os atalhos que fazem a diferença."),
                   tente: nil, feito: "",
                   demo: { _ in AnyView(BoasVindas()) }),
            Pagina(etiqueta: player,
                   titulo: String(localized: "Arraste para os lados"),
                   texto: String(localized: "Em qualquer ponto da tela. O quadro exato acompanha o dedo, em vez de pular de cena em cena, e o balão mostra para onde você vai e quanto andou."),
                   tente: String(localized: "arraste o dedo para a direita ou para a esquerda no vídeo"),
                   feito: String(localized: "É assim que se procura uma cena."),
                   demo: { AnyView(DemoBusca(onFeito: $0)) }),
            Pagina(etiqueta: player,
                   titulo: String(localized: "Brilho à esquerda, volume à direita"),
                   texto: String(localized: "Arraste para cima ou para baixo. O volume é o do aparelho, o mesmo dos botões laterais — sem a régua do sistema tapando a imagem."),
                   tente: String(localized: "suba ou desça o dedo em cada metade"),
                   feito: String(localized: "Os dois lados, sem sair do filme."),
                   demo: { AnyView(DemoBrilhoVolume(onFeito: $0)) }),
            Pagina(etiqueta: player,
                   titulo: String(localized: "Toque duas vezes"),
                   texto: String(localized: "À direita avança 10 segundos, à esquerda volta 10. No meio, pausa e continua. Perdeu uma fala? Dois toques à esquerda."),
                   tente: String(localized: "toque duas vezes rápido à direita, à esquerda ou no meio"),
                   feito: String(localized: "Pulou sem nem olhar para os botões."),
                   demo: { AnyView(DemoToqueDuplo(onFeito: $0)) }),
            Pagina(etiqueta: player,
                   titulo: String(localized: "Segure para acelerar"),
                   texto: String(localized: "Enquanto o dedo fica na tela, o vídeo corre a 2× — solte e ele volta ao normal. Ótimo para atravessar uma parte parada. A velocidade do segurar se escolhe na engrenagem, de 1,5× a 4×."),
                   tente: String(localized: "segure o dedo no vídeo por um instante"),
                   feito: String(localized: "Soltou, voltou ao normal."),
                   demo: { AnyView(DemoSegurar(onFeito: $0)) }),
            Pagina(etiqueta: player,
                   titulo: String(localized: "Pinça para ampliar"),
                   texto: String(localized: "Afaste dois dedos para chegar perto de um detalhe, de 0,5× a 6×, e arraste com os dois para mover a imagem ampliada. “Ampliação normal”, na engrenagem, volta ao quadro inteiro."),
                   tente: String(localized: "afaste dois dedos sobre o vídeo"),
                   feito: String(localized: "Detalhe de perto."),
                   demo: { AnyView(DemoPinca(onFeito: $0)) }),
            Pagina(etiqueta: player,
                   titulo: String(localized: "Rolagem fina na barra"),
                   texto: String(localized: "Arrastando a bolinha da barra de tempo, afaste o dedo para cima: a barra passa a andar mais devagar — metade, um quarto, um décimo. É o jeito de acertar o segundo exato num filme de duas horas."),
                   tente: String(localized: "arraste a bolinha e, sem soltar, suba o dedo"),
                   feito: String(localized: "Precisão de relojoeiro."),
                   demo: { AnyView(DemoRolagemFina(onFeito: $0)) }),
            Pagina(etiqueta: String(localized: "Ferramentas"),
                   titulo: String(localized: "A ilha e a engrenagem"),
                   texto: String(localized: "A ilha, no alto da tela, guarda o que se usa durante o filme. A engrenagem, no canto de cima, abre o resto. Toque em cada uma para saber o que faz."),
                   tente: String(localized: "toque em três ferramentas"),
                   feito: String(localized: "Agora você conhece a caixa de ferramentas."),
                   demo: { AnyView(DemoFerramentas(onFeito: $0)) }),
            Pagina(etiqueta: String(localized: "Biblioteca"),
                   titulo: String(localized: "Suas pastas, já organizadas"),
                   texto: String(localized: "As pastas viram capas, e “Continuar assistindo” guarda onde você parou em cada vídeo — ao abrir de novo, o app pergunta se quer continuar. Chegou vídeo novo? Puxe a tela para baixo para atualizar."),
                   tente: String(localized: "puxe a lista para baixo e solte"),
                   feito: String(localized: "Biblioteca atualizada."),
                   demo: { AnyView(DemoBiblioteca(onFeito: $0)) }),
            Pagina(etiqueta: String(localized: "Na rede"),
                   titulo: String(localized: "O computador de casa, no bolso"),
                   texto: String(localized: "O ícone de servidores, no alto da biblioteca, acha sozinho os computadores e NAS da sua rede com pastas compartilhadas e toca direto de lá, sem baixar nada.\n\nO iOS não deixa um app varrer o aparelho inteiro: autorize uma pasta — do aparelho, do iCloud ou do pendrive — e o LibertyX cuida dela sozinho daí em diante. Para rever este guia: Visualização › Ver o guia."),
                   tente: String(localized: "toque no ícone de servidores"),
                   feito: String(localized: "É por aqui que se chega ao computador de casa."),
                   demo: { AnyView(DemoRede(onFeito: $0)) }),
        ]
    }
}

private struct PaginaDoGuia: View {
    let pagina: Pagina
    let indice: Int
    let total: Int
    let feita: Bool
    let onFeito: () -> Void

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                HStack(spacing: 28) {
                    pagina.demo(onFeito)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1.1)
                    ScrollView {
                        TextoDaPagina(pagina: pagina, indice: indice, total: total, feita: feita)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pagina.demo(onFeito)
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                        TextoDaPagina(pagina: pagina, indice: indice, total: total, feita: feita)
                            .padding(.top, 26)
                            .padding(.bottom, 12)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }
}

private struct TextoDaPagina: View {
    let pagina: Pagina
    let indice: Int
    let total: Int
    let feita: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "\(pagina.etiqueta)  ·  \(indice + 1) de \(total)").uppercased())
                .font(LabFont.swiftUI(11, .bold))
                .tracking(1.6)
                .foregroundStyle(ouro)
            Text(pagina.titulo)
                .font(LabFont.swiftUI(28, .heavy))
                .tracking(-0.6)
                .foregroundStyle(LabTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(pagina.texto)
                .font(LabFont.swiftUI(15, .regular))
                .lineSpacing(4)
                .foregroundStyle(LabTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let tente = pagina.tente {
                Convite(tente: tente, feito: pagina.feito, feita: feita)
                    .padding(.top, 8)
            }
        }
    }
}

/// "Experimente: …", que vira "Isso! …" quando o gesto sai.
private struct Convite: View {
    let tente: String
    let feito: String
    let feita: Bool

    var body: some View {
        let cor = feita ? LabTheme.green : ouro
        HStack(spacing: 10) {
            Image(systemName: feita ? "checkmark" : "hand.tap.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(cor)
                .frame(width: 20)
                .contentTransition(.symbolEffect(.replace))
            (Text(feita ? String(localized: "Isso!") : String(localized: "Experimente:"))
                .font(LabFont.swiftUI(14, .heavy))
             + Text(verbatim: " ")
             + Text(feita ? feito : tente).font(LabFont.swiftUI(14, .regular)))
                .foregroundStyle(LabTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(cor.opacity(feita ? 0.14 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(cor.opacity(feita ? 0.55 : 0.40), lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: feita)
    }
}

// MARK: - O player de mentira

private struct Balao: Equatable {
    var titulo: String
    var legenda: String? = nil
    var barra: Double? = nil
    var dourada = false
}

private struct Halo: Equatable {
    /// -1 esquerda, 0 meio, 1 direita.
    let lado: Int
    let texto: String
    let serie: Int
}

/// O estado da tela de demonstração: um filme de 42 minutos que "toca" de
/// verdade — o céu anda, as nuvens passam —, para que pausar, acelerar e
/// buscar tenham efeito visível.
private final class Demo: ObservableObject {
    let duracao: Double = 42 * 60
    @Published var tempo: Double = 12 * 60 + 34
    @Published var tocando = true
    @Published var velocidade: Double = 1
    @Published var brilho: Double = 0.85
    @Published var volume: Double = 0.6
    @Published var zoom: CGFloat = 1
    @Published var desloc: CGSize = .zero
    @Published var balao: Balao?
    /// O último mostrado, para o balão sumir com o texto e não vazio.
    @Published var ultimoBalao = Balao(titulo: "")
    @Published var serieBalao = 0
    @Published var halo: Halo?

    func mostrar(_ b: Balao) { balao = b; ultimoBalao = b; serieBalao += 1 }
    func pular(_ s: Double) { tempo = min(max(tempo + s, 0), duracao) }

    func avancar(_ dt: Double) {
        guard tocando else { return }
        tempo += dt * velocidade
        if tempo >= duracao { tempo = 0 }
    }
}

/// O relógio das demonstrações: faz o filme de mentira andar.
private let quadro = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

/// A moldura do vídeo, com a cena e os avisos do player. Os gestos vêm de fora,
/// de cada página.
private struct TelaDeDemo<Extra: View>: View {
    @ObservedObject var d: Demo
    var mostraBarra = true
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ZStack {
            Color.black
            Cena(tempo: d.tempo)
                .scaleEffect(d.zoom)
                .offset(d.desloc)
            // Brilho: o quanto falta para o máximo vira sombra por cima.
            Color.black.opacity((1 - d.brilho) * 0.8)

            if !d.tocando {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(vidro, in: Circle())
            }

            HaloDoToque(halo: d.halo)

            // A velocidade do segurar, na borda direita — como no player.
            if d.velocidade > 1 {
                Text(verbatim: "\(Formato.velocidade(d.velocidade)) ▸▸")
                    .font(LabFont.swiftUI(15, .heavy))
                    .foregroundStyle(ouro)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(vidro, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .transition(.opacity)
            }

            BalaoDaDemo(b: d.ultimoBalao)
                .opacity(d.balao == nil ? 0 : 1)
                .animation(.easeOut(duration: d.balao == nil ? 0.25 : 0.12), value: d.balao == nil)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)

            if mostraBarra {
                BarraDoTempo(d: d).frame(maxHeight: .infinity, alignment: .bottom)
            }
            extra()
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: d.velocidade)
        .onReceive(quadro) { _ in d.avancar(1.0 / 30) }
        .task(id: d.serieBalao) {
            guard d.balao != nil else { return }
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if !Task.isCancelled { d.balao = nil }
        }
    }
}

extension TelaDeDemo where Extra == EmptyView {
    init(d: Demo, mostraBarra: Bool = true) {
        self.init(d: d, mostraBarra: mostraBarra) { EmptyView() }
    }
}

private struct BalaoDaDemo: View {
    let b: Balao

    var body: some View {
        VStack(spacing: 0) {
            Text(b.titulo)
                .font(LabFont.swiftUI(20, .heavy).monospacedDigit())
                .foregroundStyle(.white)
            if let legenda = b.legenda {
                Text(legenda)
                    .font(LabFont.swiftUI(12, .bold))
                    .foregroundStyle(b.dourada ? ouro : LabTheme.muted)
            }
            if let barra = b.barra {
                Capsule().fill(.white.opacity(0.2))
                    .frame(width: 90, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(ouro).frame(width: 90 * CGFloat(min(max(barra, 0), 1)))
                    }
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(vidro, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

private struct BarraDoTempo: View {
    @ObservedObject var d: Demo

    var body: some View {
        HStack(spacing: 10) {
            Text(TimeFormat.clock(d.tempo))
                .foregroundStyle(.white)
            Capsule().fill(.white.opacity(0.22))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(ouro).frame(width: geo.size.width * CGFloat(d.tempo / d.duracao))
                    }
                }
            Text(TimeFormat.clock(d.duracao))
                .foregroundStyle(LabTheme.muted)
        }
        .font(LabFont.swiftUI(11, .semibold).monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }
}

/// O semicírculo do toque duplo, que nasce da borda tocada e se apaga.
private struct HaloDoToque: View {
    let halo: Halo?
    @State private var alfa: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            if let h = halo {
                ZStack {
                    if h.lado == 0 {
                        Image(systemName: h.texto == "pause" ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(vidro, in: Circle())
                            .position(x: w / 2, y: geo.size.height / 2)
                    } else {
                        Circle().fill(.white.opacity(0.13))
                            .frame(width: w * 0.5, height: w * 0.5)
                            .position(x: h.lado < 0 ? w * 0.13 : w * 0.87, y: geo.size.height / 2)
                        Text(h.texto)
                            .font(LabFont.swiftUI(18, .heavy))
                            .foregroundStyle(.white)
                            .position(x: h.lado < 0 ? w * 0.16 : w * 0.84, y: geo.size.height / 2)
                    }
                }
                .opacity(alfa)
            }
        }
        .allowsHitTesting(false)
        .task(id: halo?.serie) {
            guard halo != nil else { return }
            alfa = 1
            withAnimation(.easeOut(duration: 0.7).delay(0.25)) { alfa = 0 }
        }
    }
}

/// Um pôr do sol que anda com o tempo do filme: o sol cruza o céu, as nuvens
/// e os morros deslizam. Buscar, pausar e acelerar mudam o quadro — é assim que
/// a demonstração mostra que o gesto funcionou.
private struct Cena: View {
    let tempo: Double

    var body: some View {
        Canvas { ctx, size in
            let w = Double(size.width), h = Double(size.height)
            let tudo = Path(CGRect(origin: .zero, size: size))
            ctx.fill(tudo, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x101A3A), Color(hex: 0x3E2B5E), Color(hex: 0xD9745A), Color(hex: 0xF4BC6A)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

            let ciclo = tempo.truncatingRemainder(dividingBy: 240) / 240
            let sol = CGPoint(x: w * (0.12 + 0.76 * ciclo), y: h * 0.72 - sin(ciclo * .pi) * h * 0.42)
            let halo = h * 0.35
            ctx.fill(Path(ellipseIn: CGRect(x: sol.x - halo, y: sol.y - halo, width: halo * 2, height: halo * 2)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xFFD27A).opacity(0.4), .clear]),
                                           center: sol, startRadius: 0, endRadius: halo))
            let r = h * 0.09
            ctx.fill(Path(ellipseIn: CGRect(x: sol.x - r, y: sol.y - r, width: r * 2, height: r * 2)),
                     with: .color(Color(hex: 0xFFE3A3)))

            for i in 0..<4 {
                let x = (Double(i) * w / 3 + tempo * 18 * Double(1 + i % 2)).truncatingRemainder(dividingBy: w * 1.4) - w * 0.2
                let y = h * (0.14 + 0.09 * Double(i))
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: w * 0.18, height: h * 0.05)),
                         with: .color(.white.opacity(0.16)))
                ctx.fill(Path(ellipseIn: CGRect(x: x + w * 0.05, y: y - h * 0.025, width: w * 0.12, height: h * 0.05)),
                         with: .color(.white.opacity(0.12)))
            }

            func morro(_ base: Double, _ amp: Double, _ fase: Double) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h))
                var x = 0.0
                while x <= w {
                    p.addLine(to: CGPoint(x: x, y: base + amp * sin(x / w * 2.4 * .pi + fase)))
                    x += w / 60
                }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
                return p
            }
            ctx.fill(morro(h * 0.70, h * 0.06, tempo * 0.05), with: .color(Color(hex: 0x4A2A4E)))
            ctx.fill(morro(h * 0.80, h * 0.05, tempo * 0.11 + 1.3), with: .color(Color(hex: 0x26162E)))
            ctx.fill(morro(h * 0.90, h * 0.035, tempo * 0.2 + 2.1), with: .color(Color(hex: 0x120B18)))
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - As demonstrações

private struct BoasVindas: View {
    @State private var pulso = false
    @State private var entrou = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [ouro.opacity(pulso ? 0.28 : 0.24), .clear],
                                         center: .center, startRadius: 0, endRadius: 95))
                    .frame(width: 190, height: 190)
                Image("AppIconSymbol")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 116, height: 116)
                    .scaleEffect(entrou ? 1 : 0.6)
            }
            NomeDoApp(tamanho: 34)
            Text("Sua mídia. Sua liberdade.")
                .font(LabFont.swiftUI(14, .semibold))
                .foregroundStyle(LabTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.55)) { entrou = true }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulso = true }
        }
    }
}

private struct DemoBusca: View {
    let onFeito: () -> Void
    @StateObject private var d = Demo()
    @State private var inicio: Double?

    var body: some View {
        TelaDeDemo(d: d)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        let de = inicio ?? d.tempo
                        inicio = de
                        // Uma largura de 320 pontos ≈ 3 minutos, como no Android.
                        d.tempo = min(max(de + Double(g.translation.width) / 320 * 180, 0), d.duracao)
                        let delta = d.tempo - de
                        d.mostrar(Balao(titulo: TimeFormat.clock(d.tempo),
                                        legenda: (delta >= 0 ? "+" : "−") + TimeFormat.clock(abs(delta)),
                                        dourada: true))
                    }
                    .onEnded { _ in
                        if let de = inicio, abs(d.tempo - de) > 15 { onFeito() }
                        inicio = nil
                    }
            )
    }
}

private struct DemoBrilhoVolume: View {
    let onFeito: () -> Void
    @StateObject private var d = Demo()
    @State private var usouBrilho = false
    @State private var usouVolume = false
    @State private var anterior: CGFloat?

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                TelaDeDemo(d: d) {
                    // A divisão das metades, para o dedo saber onde está cada uma.
                    Rectangle().fill(.white.opacity(0.10)).frame(width: 1)
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            let dy = Double(g.translation.height - (anterior ?? 0))
                            anterior = g.translation.height
                            if g.startLocation.x < geo.size.width / 2 {
                                d.brilho = min(max(d.brilho - dy / 180, 0.1), 1)
                                d.mostrar(Balao(titulo: "\(Int((d.brilho * 100).rounded()))%",
                                                legenda: String(localized: "Brilho"), barra: d.brilho))
                                usouBrilho = true
                            } else {
                                d.volume = min(max(d.volume - dy / 180, 0), 1)
                                d.mostrar(Balao(titulo: "\(Int((d.volume * 100).rounded()))%",
                                                legenda: String(localized: "Volume"), barra: d.volume))
                                usouVolume = true
                            }
                            if usouBrilho && usouVolume { onFeito() }
                        }
                        .onEnded { _ in anterior = nil }
                )
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            HStack(spacing: 8) {
                Marcador(texto: String(localized: "Brilho"), feito: usouBrilho)
                Marcador(texto: String(localized: "Volume"), feito: usouVolume)
            }
        }
    }
}

/// Uma das partes de um exercício, que acende quando foi feita.
private struct Marcador: View {
    let texto: String
    let feito: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(texto)
                .font(LabFont.swiftUI(13, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if feito {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LabTheme.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((feito ? LabTheme.green : LabTheme.faint).opacity(0.5), lineWidth: 1))
        .animation(.spring(response: 0.3), value: feito)
    }
}

private struct DemoToqueDuplo: View {
    let onFeito: () -> Void
    @StateObject private var d = Demo()
    @State private var serie = 0
    @State private var feitos: Set<Int> = []

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                TelaDeDemo(d: d) {
                    // Os três terços, bem de leve.
                    HStack(spacing: 0) {
                        ForEach(Array(["−10 s", "⏯", "+10 s"].enumerated()), id: \.offset) { i, rotulo in
                            Text(verbatim: rotulo)
                                .font(LabFont.swiftUI(13, .bold))
                                .foregroundStyle(.white.opacity(0.22))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if i < 2 { Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { toque in
                        let terco = geo.size.width / 3
                        let lado = toque.location.x < terco ? -1 : toque.location.x > terco * 2 ? 1 : 0
                        serie += 1
                        switch lado {
                        case -1: d.pular(-10); d.halo = Halo(lado: -1, texto: "−10 s", serie: serie)
                        case 1:  d.pular(10);  d.halo = Halo(lado: 1, texto: "+10 s", serie: serie)
                        default:
                            d.tocando.toggle()
                            d.halo = Halo(lado: 0, texto: d.tocando ? "play" : "pause", serie: serie)
                        }
                        feitos.insert(lado)
                        onFeito()
                    }
                )
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            HStack(spacing: 8) {
                Marcador(texto: String(localized: "Voltar"), feito: feitos.contains(-1))
                Marcador(texto: String(localized: "Pausar"), feito: feitos.contains(0))
                Marcador(texto: String(localized: "Avançar"), feito: feitos.contains(1))
            }
        }
    }
}

private struct DemoSegurar: View {
    let onFeito: () -> Void
    @StateObject private var d = Demo()
    @State private var segurando: Task<Void, Never>?

    var body: some View {
        TelaDeDemo(d: d)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard segurando == nil else { return }
                        segurando = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled else { return }
                            d.velocidade = 2
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            guard !Task.isCancelled else { return }
                            onFeito()
                        }
                    }
                    .onEnded { _ in
                        segurando?.cancel()
                        segurando = nil
                        d.velocidade = 1
                    }
            )
    }
}

private struct DemoPinca: View {
    let onFeito: () -> Void
    @StateObject private var d = Demo()
    @State private var zoomInicial: CGFloat?
    @State private var deslocInicial: CGSize?

    var body: some View {
        TelaDeDemo(d: d) {
            // Quem já ampliou precisa de um caminho de volta aqui também.
            if d.zoom != 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { d.zoom = 1; d.desloc = .zero }
                } label: {
                    Text("Ampliação normal")
                        .font(LabFont.swiftUI(12, .bold))
                        .foregroundStyle(LabTheme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(vidro, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(10)
            }
        }
        .gesture(
            MagnifyGesture()
                .onChanged { g in
                    let base = zoomInicial ?? d.zoom
                    zoomInicial = base
                    d.zoom = min(max(base * g.magnification, 0.5), 6)
                    if d.zoom <= 1 { d.desloc = .zero }
                    d.mostrar(Balao(titulo: "\(Int((d.zoom * 100).rounded()))%",
                                    legenda: String(localized: "Ampliação")))
                    if d.zoom > 1.4 || d.zoom < 0.8 { onFeito() }
                }
                .onEnded { _ in zoomInicial = nil }
                .simultaneously(with:
                    DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            guard d.zoom > 1 else { return }
                            let base = deslocInicial ?? d.desloc
                            deslocInicial = base
                            d.desloc = CGSize(width: base.width + g.translation.width,
                                              height: base.height + g.translation.height)
                        }
                        .onEnded { _ in deslocInicial = nil }
                )
        )
    }
}

private struct DemoRolagemFina: View {
    let onFeito: () -> Void
    @StateObject private var d = Demo()
    @State private var precisao: Double = 1
    @State private var arrastando = false
    @State private var ultimoX: CGFloat?

    private let alturaDaArea: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            TelaDeDemo(d: d, mostraBarra: false) {
                BalaoDaDemo(b: Balao(titulo: TimeFormat.clock(d.tempo), legenda: legenda, dourada: precisao < 1))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 14)
                    .opacity(arrastando ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: arrastando)
            }
            // A barra fica fora do quadro e com folga em cima, para o dedo ter
            // para onde subir sem sair da área do gesto.
            GeometryReader { geo in
                let trilho = geo.size.height - 28
                ZStack(alignment: .topLeading) {
                    // As faixas de precisão nas mesmas distâncias do player:
                    // 50, 100 e 150 pontos acima da barra. A faixa onde o dedo
                    // está acende.
                    ForEach(Faixa.todas) { faixa in
                        let dist = faixa.distancia, rotulo = faixa.rotulo
                        let acesa = arrastando && precisao == faixa.valor
                        Rectangle()
                            .fill(acesa ? ouro.opacity(0.6) : .white.opacity(0.07))
                            .frame(height: 1)
                            .offset(y: trilho - dist)
                        Text(String(localized: "precisão \(rotulo)"))
                            .font(LabFont.swiftUI(11, acesa ? .bold : .regular))
                            .foregroundStyle(acesa ? ouro : LabTheme.faint.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .offset(y: trilho - dist - 18)
                    }

                    let frac = CGFloat(d.tempo / d.duracao)
                    let raio: CGFloat = arrastando ? 11 : 9
                    Capsule().fill(.white.opacity(0.2))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ouro).frame(width: geo.size.width * frac)
                        }
                        .offset(y: trilho - 2)
                    Circle().fill(ouro)
                        .frame(width: raio * 2, height: raio * 2)
                        .offset(x: (geo.size.width - raio * 2) * frac, y: trilho - raio)
                    Text(TimeFormat.clock(d.tempo))
                        .font(LabFont.swiftUI(11, .regular).monospacedDigit())
                        .foregroundStyle(LabTheme.muted)
                        .offset(y: trilho + 14)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !arrastando { arrastando = true; d.tocando = false }
                            let distancia = abs(g.location.y - trilho)
                            precisao = distancia < 50 ? 1 : distancia < 100 ? 0.5 : distancia < 150 ? 0.25 : 0.1
                            if precisao < 1 { onFeito() }
                            if let x = ultimoX {
                                let fracao = Double((g.location.x - x) / geo.size.width)
                                d.tempo = min(max(d.tempo + fracao * d.duracao * precisao, 0), d.duracao)
                            }
                            ultimoX = g.location.x
                        }
                        .onEnded { _ in
                            arrastando = false; d.tocando = true; precisao = 1; ultimoX = nil
                        }
                )
            }
            .frame(height: alturaDaArea)
        }
    }

    private var legenda: String {
        switch precisao {
        case 1...:    return String(localized: "velocidade normal")
        case 0.4...:  return String(localized: "precisão ½ — afaste mais para afinar")
        case 0.2...:  return String(localized: "precisão \("¼")")
        default:      return String(localized: "precisão \("⅒")")
        }
    }
}

/// Uma das faixas de precisão da rolagem fina.
private struct Faixa: Identifiable {
    let distancia: CGFloat
    let rotulo: String
    let valor: Double
    var id: Double { valor }

    static let todas = [Faixa(distancia: 50, rotulo: "½", valor: 0.5),
                        Faixa(distancia: 100, rotulo: "¼", valor: 0.25),
                        Faixa(distancia: 150, rotulo: "⅒", valor: 0.1)]
}

private struct Ferramenta: Identifiable {
    let simbolo: String
    let nome: String
    let explica: String
    var id: String { simbolo }
}

private struct DemoFerramentas: View {
    let onFeito: () -> Void
    @State private var escolhida: Ferramenta?
    @State private var vistas: Set<String> = []

    private let daIlha = [
        Ferramenta(simbolo: "music.note", nome: String(localized: "Faixa de áudio"),
                   explica: String(localized: "Troca a faixa de som: dublado, original, comentário do diretor.")),
        Ferramenta(simbolo: "captions.bubble", nome: String(localized: "Legenda"),
                   explica: String(localized: "Liga, desliga e escolhe entre as legendas do arquivo.")),
        Ferramenta(simbolo: "repeat", nome: String(localized: "Repetir"),
                   explica: String(localized: "Repete o vídeo atual sem parar. Acende enquanto estiver ligado.")),
        Ferramenta(simbolo: "rotate.right", nome: String(localized: "Girar"),
                   explica: String(localized: "Trava deitado ou em pé; o toque seguinte devolve ao automático.")),
        Ferramenta(simbolo: "speedometer", nome: String(localized: "Velocidade"),
                   explica: String(localized: "De 0,5× a 2×, para quando a fala corre demais ou de menos.")),
    ]

    private let daEngrenagem = [
        Ferramenta(simbolo: "timer", nome: String(localized: "Dormir"),
                   explica: String(localized: "Tempo para dormir: pausa sozinho depois dos minutos que você escolher.")),
        Ferramenta(simbolo: "moon.stars", nome: String(localized: "Noturno"),
                   explica: String(localized: "Escurece a imagem além do mínimo do sistema, para assistir no escuro.")),
        Ferramenta(simbolo: "camera", nome: String(localized: "Captura"),
                   explica: String(localized: "Salva o quadro que está na tela em Fotos.")),
        Ferramenta(simbolo: "hand.tap", nome: String(localized: "Segurar"),
                   explica: String(localized: "A velocidade de segurar para acelerar, de 1,5× a 4×.")),
        Ferramenta(simbolo: "lock", nome: String(localized: "Bloquear"),
                   explica: String(localized: "O cadeado da barra de baixo trava os toques — filme no bolso, criança no colo.")),
        Ferramenta(simbolo: "speaker.slash.fill", nome: String(localized: "Mudo"),
                   explica: String(localized: "Silencia só o vídeo; um alto-falante riscado fica no alto enquanto durar.")),
        Ferramenta(simbolo: "aspectratio", nome: String(localized: "Proporção"),
                   explica: String(localized: "Ajustar, preencher ou esticar a imagem na tela.")),
        Ferramenta(simbolo: "clock.arrow.circlepath", nome: String(localized: "Ocultar"),
                   explica: String(localized: "Quanto tempo a barra fica na tela depois do último toque — ou se ela fica sempre.")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // A ilha, igual à do player.
            HStack(spacing: 0) {
                ForEach(daIlha) { f in
                    IconeDeFerramenta(f: f, ativa: f.id == escolhida?.id, vista: vistas.contains(f.id),
                                      rotulo: false) { tocar(f) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(red: 0.078, green: 0.078, blue: 0.094, opacity: 0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))

            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill").font(.system(size: 10))
                Text("Na engrenagem").textCase(.uppercase)
            }
            .font(LabFont.swiftUI(10, .bold))
            .tracking(1.4)
            .foregroundStyle(LabTheme.faint)
            .padding(.top, 14)
            .padding(.bottom, 8)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(daEngrenagem) { f in
                    IconeDeFerramenta(f: f, ativa: f.id == escolhida?.id, vista: vistas.contains(f.id),
                                      rotulo: true) { tocar(f) }
                }
            }

            Group {
                if let f = escolhida {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.nome)
                            .font(LabFont.swiftUI(14, .heavy))
                            .foregroundStyle(ouro)
                        Text(f.explica)
                            .font(LabFont.swiftUI(13, .regular))
                            .foregroundStyle(LabTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(f.id)
                    .transition(.opacity)
                } else {
                    Text("Toque numa ferramenta para ver o que ela faz.")
                        .font(LabFont.swiftUI(13, .regular))
                        .foregroundStyle(LabTheme.faint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
            .padding(.top, 12)
            .animation(.easeInOut(duration: 0.2), value: escolhida?.id)
        }
    }

    private func tocar(_ f: Ferramenta) {
        escolhida = f
        vistas.insert(f.id)
        if vistas.count >= 3 { onFeito() }
    }
}

private struct IconeDeFerramenta: View {
    let f: Ferramenta
    let ativa: Bool
    let vista: Bool
    let rotulo: Bool
    let onTap: () -> Void

    var body: some View {
        let tinta: Color = ativa ? ouro : vista ? .white : .white.opacity(0.75)
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: f.simbolo)
                    .font(.system(size: rotulo ? 19 : 17, weight: .medium))
                    .frame(width: rotulo ? 30 : 46, height: rotulo ? 30 : 46)
                if rotulo {
                    Text(f.nome)
                        .font(LabFont.swiftUI(10, .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(tinta)
            .frame(maxWidth: rotulo ? .infinity : nil)
            .padding(.vertical, rotulo ? 8 : 0)
            .background(ativa ? ouro.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.nome)
        .animation(.easeInOut(duration: 0.2), value: ativa)
    }
}

private struct DemoBiblioteca: View {
    let onFeito: () -> Void
    @State private var puxao: CGFloat = 0
    @State private var atualizando = false
    @State private var atualizada = false

    private let limite: CGFloat = 70

    var body: some View {
        ZStack(alignment: .top) {
            // O indicador que desce com o dedo.
            ZStack {
                Circle().fill(Color(white: 0.12))
                Circle().strokeBorder(LabTheme.glassBorder, lineWidth: 0.5)
                if atualizando {
                    ProgressView().tint(ouro).scaleEffect(0.8)
                } else {
                    Circle()
                        .trim(from: 0, to: min(puxao / limite, 1))
                        .stroke(ouro, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 36, height: 36)
            .offset(y: puxao * 0.6 - 40)

            VStack(alignment: .leading, spacing: 0) {
                Text("Biblioteca")
                    .font(LabFont.swiftUI(20, .heavy))
                    .foregroundStyle(LabTheme.text)
                Text([Plural.videos(atualizada ? 6 : 5), Plural.pastas(3),
                      atualizada ? String(localized: "atualizada agora") : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(LabFont.swiftUI(11, .medium))
                    .foregroundStyle(atualizada ? LabTheme.green : LabTheme.muted)
                Text("Continuar assistindo").textCase(.uppercase)
                    .font(LabFont.swiftUI(9, .bold)).tracking(1.2)
                    .foregroundStyle(LabTheme.muted)
                    .padding(.top, 12)
                HStack(spacing: 8) {
                    CapaDeMentira(tempo: 0.3, progresso: 0.62, minutos: 16)
                    CapaDeMentira(tempo: 0.7, progresso: 0.25, minutos: 31)
                    CapaDeMentira(tempo: 0.5, progresso: 0.8, minutos: 4)
                }
                .padding(.top, 6)
                Text("Pastas").textCase(.uppercase)
                    .font(LabFont.swiftUI(9, .bold)).tracking(1.2)
                    .foregroundStyle(LabTheme.muted)
                    .padding(.top, 10)
                HStack(spacing: 8) {
                    ForEach([String(localized: "Filmes"), String(localized: "Séries"), String(localized: "Downloads")],
                            id: \.self) { nome in
                        Text(nome)
                            .font(LabFont.swiftUI(11, .semibold))
                            .foregroundStyle(LabTheme.text)
                            .lineLimit(1)
                            .padding(.leading, 10)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.top, 6)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: puxao)
        }
        .frame(height: 262, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.071, green: 0.071, blue: 0.086))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { g in
                    guard !atualizando else { return }
                    // Resistência: puxar vai ficando pesado, como na lista de verdade.
                    puxao = min(max(g.translation.height * 0.55, 0), limite * 1.6)
                }
                .onEnded { _ in
                    guard !atualizando else { return }
                    if puxao >= limite {
                        atualizando = true
                        withAnimation(.easeOut(duration: 0.2)) { puxao = limite * 0.8 }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_100_000_000)
                            atualizando = false
                            atualizada = true
                            onFeito()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { puxao = 0 }
                        }
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { puxao = 0 }
                    }
                }
        )
    }
}

private struct CapaDeMentira: View {
    let tempo: Double
    let progresso: Double
    let minutos: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Cena(tempo: tempo * 240)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) { BarraDeProgresso(progresso: progresso) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(String(localized: "faltam \(TimeFormat.spoken(Double(minutos * 60)))"))
                .font(LabFont.swiftUI(10, .bold))
                .foregroundStyle(ouro)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DemoRede: View {
    let onFeito: () -> Void
    @State private var procurando = false
    @State private var achou = 0
    @State private var onda = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("AppIconSymbol").resizable().scaledToFit().frame(width: 22, height: 22)
                Text("Biblioteca")
                    .font(LabFont.swiftUI(15, .heavy))
                    .foregroundStyle(LabTheme.text)
                Spacer()
                ZStack {
                    if !procurando && achou == 0 {
                        Circle()
                            .fill(ouro.opacity(onda ? 0 : 0.35))
                            .frame(width: onda ? 52 : 31, height: onda ? 52 : 31)
                    }
                    Button {
                        guard !procurando else { return }
                        Task { @MainActor in
                            procurando = true; achou = 0
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            withAnimation { achou = 1 }
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            withAnimation { achou = 2 }
                            procurando = false
                            onFeito()
                        }
                    } label: {
                        Image(systemName: "server.rack")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.08), in: Circle())
                            .overlay(Circle().strokeBorder(achou == 0 ? ouro : LabTheme.glassBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Servidores"))
                }
                .frame(width: 52, height: 52)
            }

            ZStack {
                if !procurando && achou == 0 {
                    Text("Servidores ficam aqui, no alto. →")
                        .font(LabFont.swiftUI(13, .regular))
                        .foregroundStyle(LabTheme.faint)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if procurando {
                                ProgressView().tint(ouro).scaleEffect(0.6).frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(LabTheme.green)
                            }
                            Text(procurando ? String(localized: "Procurando na rede…") : String(localized: "Na sua rede"))
                                .font(LabFont.swiftUI(12, .regular))
                                .foregroundStyle(LabTheme.muted)
                        }
                        let achados = [
                            (String(localized: "Computador da sala"),
                             String(localized: "Filmes") + " · " + String(localized: "Séries")),
                            ("NAS", String(localized: "Mídia")),
                        ]
                        ForEach(Array(achados.prefix(achou).enumerated()), id: \.offset) { _, par in
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(ouro)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(par.0)
                                        .font(LabFont.swiftUI(13, .semibold))
                                        .foregroundStyle(LabTheme.text)
                                    Text(par.1)
                                        .font(LabFont.swiftUI(11, .regular))
                                        .foregroundStyle(LabTheme.faint)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 146)
            .padding(.top, 12)

            Text("Exemplo ilustrativo — os nomes reais são os da sua rede.")
                .font(LabFont.swiftUI(10, .regular))
                .foregroundStyle(LabTheme.faint)
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color(red: 0.071, green: 0.071, blue: 0.086))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { onda = true }
        }
    }
}

import SwiftUI

/// Ajustes › Teste de velocidade: quanto cada servidor entrega até este
/// aparelho, e o que isso quer dizer em vídeo — "347 Mb/s" sozinho não diz
/// se o remux 4K vai engasgar.
struct TesteDeVelocidadeView: View {
    @ObservedObject private var teste = TesteDeVelocidade.shared
    @ObservedObject private var smb = SMBServerStore.shared
    @ObservedObject private var contas = ContasDeRede.shared
    @State private var escolhido: UUID?

    private var alvos: [AlvoDeTeste] {
        smb.servers.map { AlvoDeTeste(origem: .smb($0)) }
            + contas.contas.map { AlvoDeTeste(origem: .conta($0)) }
    }

    /// O servidor do velocímetro: o que está sendo medido, senão o tocado por
    /// último, senão o último medido.
    private var emFoco: AlvoDeTeste? {
        let id = teste.emTeste ?? escolhido ?? teste.ultimo
        return alvos.first { $0.id == id } ?? alvos.first
    }

    var body: some View {
        ZStack {
            FundoDeCapa(capa: nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TituloDeTela(titulo: String(localized: "Velocidade"),
                                 subtitulo: String(localized: "Quanto cada servidor entrega até este aparelho"))
                    if alvos.isEmpty {
                        vazio
                    } else {
                        if let emFoco {
                            PainelDeVelocidade(alvo: emFoco, teste: teste)
                        }
                        botaoPrincipal
                        Secao(titulo: String(localized: "Servidores"), extra: "\(alvos.count)")
                            .padding(.top, 6)
                        VStack(spacing: 10) {
                            ForEach(alvos) { alvo in
                                CartaoDeServidor(alvo: alvo, teste: teste,
                                                 emFoco: emFoco?.id == alvo.id) {
                                    tocar(alvo)
                                }
                            }
                        }
                        rodape
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: Escala.larguraMaxima)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Sair da tela é desistir: o teste ocupa a rede inteira.
        .onDisappear { teste.cancelar() }
    }

    private func tocar(_ alvo: AlvoDeTeste) {
        withAnimation(.snappy) { escolhido = alvo.id }
        guard teste.emTeste != alvo.id else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        teste.testar([alvo])
    }

    private var botaoPrincipal: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if teste.rodando {
                teste.cancelar()
            } else {
                escolhido = nil
                teste.testar(alvos)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: teste.rodando ? "stop.fill" : "gauge.with.dots.needle.67percent")
                    .font(.system(size: 17, weight: .bold))
                Text(teste.rodando ? String(localized: "Parar") :
                        (alvos.count == 1 ? String(localized: "Testar") : String(localized: "Testar todos")))
                    .font(LabFont.swiftUI(17, .bold))
            }
            .foregroundStyle(teste.rodando ? LabTheme.text : Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                if teste.rodando {
                    Capsule().fill(LabTheme.glass)
                        .overlay(Capsule().strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
                } else {
                    Capsule().fill(LinearGradient(colors: [LabTheme.accent, LabTheme.orange],
                                                  startPoint: .leading, endPoint: .trailing))
                        .shadow(color: LabTheme.accent.opacity(0.35), radius: 14, y: 4)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: teste.rodando)
    }

    private var vazio: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(LabTheme.accent)
            Text("Nenhum servidor para medir")
                .font(LabFont.swiftUI(18, .bold))
                .foregroundStyle(LabTheme.text)
            Text("Cadastre um servidor SMB, Jellyfin, Emby ou WebDAV nos Ajustes e volte aqui.")
                .font(LabFont.swiftUI(13, .medium))
                .foregroundStyle(LabTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .labCard()
    }

    private var rodape: some View {
        Text("O teste lê um arquivo de verdade, do jeito que o player lê ao tocar, e não grava nada no servidor. No SMB e no WebDAV ele usa o maior arquivo que achar; no Jellyfin e no Emby, o teste de banda do próprio servidor. A resposta é o tempo de ida e volta até o servidor: quanto menor, mais rápido o vídeo abre e a busca assenta.")
            .font(LabFont.swiftUI(11.5, .medium))
            .foregroundStyle(LabTheme.faint)
            .padding(.top, 6)
    }
}

// MARK: - Painel

/// O cartão grande: o velocímetro, a onda da banda, os números e o que dá
/// para tocar.
private struct PainelDeVelocidade: View {
    let alvo: AlvoDeTeste
    @ObservedObject var teste: TesteDeVelocidade

    private var medindo: Bool { teste.emTeste == alvo.id }
    private var resultado: ResultadoDeVelocidade? { teste.resultados[alvo.id] }
    private var falha: String? { medindo ? nil : teste.falhas[alvo.id] }

    /// O que o ponteiro mostra: ao vivo durante o teste, o resultado depois.
    private var valor: Double {
        if medindo { return teste.agora }
        return falha == nil ? (resultado?.mbps ?? 0) : 0
    }

    private var onda: [Double] {
        medindo ? teste.amostras : (resultado?.amostras ?? [])
    }

    private var legenda: String {
        if medindo {
            switch teste.fase {
            case .resposta:   return String(localized: "Medindo a resposta")
            case .preparando: return String(localized: "Procurando o que ler")
            default:          return String(localized: "Lendo do servidor")
            }
        }
        if falha != nil { return String(localized: "Não deu para medir") }
        if let resultado { return NotaDeVelocidade(resultado.mbps).nome }
        return String(localized: "Ainda não medido")
    }

    var body: some View {
        VStack(spacing: 14) {
            cabecalho
            Velocimetro(valor: valor, legenda: legenda, ativo: medindo,
                        corDaLegenda: corDaLegenda)
                .frame(maxWidth: .infinity)
            if medindo, teste.fase == .baixando || !onda.isEmpty {
                Onda(valores: onda, ativa: true)
                    .frame(height: 54)
                    .transition(.opacity)
            } else if !medindo, falha == nil, let resultado, !resultado.amostras.isEmpty {
                Onda(valores: resultado.amostras, ativa: false)
                    .frame(height: 54)
                    .transition(.opacity)
            }
            numeros
            if let falha {
                Label(falha, systemImage: "exclamationmark.triangle.fill")
                    .font(LabFont.swiftUI(13, .semibold))
                    .foregroundStyle(LabTheme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !medindo, let resultado {
                Escada(mbps: resultado.mbps)
                if let tropecos = resultado.tropecos, tropecos > 0 {
                    Label(Plural.quedas(tropecos), systemImage: "exclamationmark.triangle.fill")
                        .font(LabFont.swiftUI(12.5, .semibold))
                        .foregroundStyle(LabTheme.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(NotaDeVelocidade(resultado.mbps).veredito)
                    .font(LabFont.swiftUI(13.5, .semibold))
                    .foregroundStyle(LabTheme.text.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let lido = resultado.lido {
                    Text(String(localized: "Leu \(Formato.megabytes(resultado.megabytes)) de \(lido)"))
                        .font(LabFont.swiftUI(11.5, .medium))
                        .foregroundStyle(LabTheme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if medindo, let lendo = teste.lendo {
                Text(String(localized: "Lendo \(lendo)"))
                    .font(LabFont.swiftUI(11.5, .medium))
                    .foregroundStyle(LabTheme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LabTheme.glass)
                .overlay(
                    RadialGradient(colors: [LabTheme.accent.opacity(medindo ? 0.16 : 0.08), .clear],
                                   center: .top, startRadius: 0, endRadius: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.35), value: medindo)
        .animation(.easeInOut(duration: 0.35), value: alvo.id)
    }

    private var corDaLegenda: Color {
        if medindo { return LabTheme.muted }
        if falha != nil { return LabTheme.orange }
        guard let resultado else { return LabTheme.faint }
        return Cores.da(resultado.mbps)
    }

    private var cabecalho: some View {
        HStack(spacing: 12) {
            IconeDoServidor(alvo: alvo, tamanho: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(alvo.nome)
                    .font(LabFont.swiftUI(16, .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                Text(verbatim: "\(alvo.tipo) · \(resultado?.ip ?? alvo.endereco)")
                    .font(LabFont.swiftUI(12, .medium))
                    .foregroundStyle(LabTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let resultado, !medindo {
                VStack(alignment: .trailing, spacing: 4) {
                    if let interface = resultado.interface {
                        Etiqueta(texto: interface,
                                 simbolo: interface == String(localized: "Wi-Fi") ? "wifi"
                                    : interface == String(localized: "Cabo") ? "cable.connector"
                                    : "antenna.radiowaves.left.and.right")
                    }
                    if let casa = resultado.naRedeDeCasa {
                        Etiqueta(texto: casa ? String(localized: "Rede de casa") : String(localized: "Internet"),
                                 simbolo: casa ? "house.fill" : "globe")
                    }
                }
            }
        }
    }

    /// Resposta, variação e pico: os três números que explicam a banda.
    private var numeros: some View {
        let resposta = medindo ? teste.resposta : resultado?.resposta
        let variacao = medindo ? nil : resultado?.variacao
        let pico = medindo ? (teste.amostras.max()) : resultado?.pico
        let banda: Double? = medindo ? teste.agora : (falha == nil ? resultado?.mbps : nil)
        return HStack(spacing: 0) {
            Numero(titulo: String(localized: "Resposta"), valor: resposta.map(Formato.milissegundos), unidade: "ms")
            divisoria
            Numero(titulo: String(localized: "Variação"), valor: variacao.map(Formato.milissegundos), unidade: "ms")
            divisoria
            Numero(titulo: String(localized: "Pico"), valor: pico.map(Formato.mbps), unidade: "Mb/s")
            divisoria
            Numero(titulo: "MB/s", valor: banda.map { Formato.mbps($0 / 8) }, unidade: nil)
        }
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divisoria: some View {
        Rectangle().fill(LabTheme.glassBorder).frame(width: 0.5, height: 28)
    }
}

/// Um número pequeno com o nome em cima.
private struct Numero: View {
    let titulo: String
    let valor: String?
    let unidade: String?

    var body: some View {
        VStack(spacing: 3) {
            Text(titulo.uppercased())
                .font(LabFont.swiftUI(9.5, .bold))
                .tracking(0.8)
                .foregroundStyle(LabTheme.faint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: valor ?? "—")
                    .font(LabFont.swiftUI(16, .bold))
                    .monospacedDigit()
                    .foregroundStyle(valor == nil ? LabTheme.faint : LabTheme.text)
                    .contentTransition(.numericText())
                if let unidade, valor != nil {
                    Text(verbatim: unidade)
                        .font(LabFont.swiftUI(10, .semibold))
                        .foregroundStyle(LabTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: valor)
    }
}

private struct Etiqueta: View {
    let texto: String
    let simbolo: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: simbolo).font(.system(size: 9, weight: .bold))
            Text(texto).font(LabFont.swiftUI(10.5, .bold))
        }
        .foregroundStyle(LabTheme.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.07), in: Capsule())
    }
}

// MARK: - Velocímetro

/// O mostrador: 270° em escala logarítmica, de 1 a 1000 Mb/s.
///
/// Logarítmica porque a diferença que importa é entre 5 e 50 (assiste ou
/// não assiste), e não entre 500 e 900 — numa escala comum, tudo o que é
/// Wi-Fi de casa ficaria espremido no começo do arco.
private struct Velocimetro: View {
    let valor: Double
    let legenda: String
    let ativo: Bool
    let corDaLegenda: Color

    private static let arco = 0.75
    private static let marcas: [Double] = [1, 5, 10, 50, 100, 500, 1000]
    private static let lado: CGFloat = 248
    private static let espessura: CGFloat = 14

    static func fracao(_ v: Double) -> Double {
        min(1, max(0, log10(max(v, 1)) / 3))
    }

    var body: some View {
        let f = Self.fracao(valor)
        let raio = Self.lado / 2 - Self.espessura / 2
        ZStack {
            // O trilho, com os tracinhos de cada décimo da escala.
            Circle()
                .trim(from: 0, to: Self.arco)
                .stroke(Color.white.opacity(0.08),
                        style: StrokeStyle(lineWidth: Self.espessura, lineCap: .round))
                .rotationEffect(.degrees(135))
            ForEach(0..<31, id: \.self) { i in
                let principal = i % 10 == 0
                Capsule()
                    .fill(Color.white.opacity(principal ? 0.35 : 0.13))
                    .frame(width: principal ? 2 : 1, height: principal ? 9 : 5)
                    .offset(y: -(raio - Self.espessura - 6))
                    .rotationEffect(.degrees(225 + 270 * Double(i) / 30))
            }
            ForEach(Self.marcas, id: \.self) { marca in
                let angulo = CGFloat((135 + 270 * Self.fracao(marca)) * .pi / 180)
                let r = raio - Self.espessura - 24
                Text(verbatim: marca >= 1000 ? "1G" : "\(Int(marca))")
                    .font(LabFont.swiftUI(10, .bold))
                    .foregroundStyle(valor >= marca && valor > 0 ? LabTheme.text.opacity(0.7) : LabTheme.faint)
                    .offset(x: r * cos(angulo), y: r * sin(angulo))
            }

            // O preenchido: do laranja ao amarelo da marca, e branco no fim.
            Circle()
                .trim(from: 0, to: Self.arco * f)
                .stroke(AngularGradient(colors: [LabTheme.orange, LabTheme.accent, Color(white: 1)],
                                        center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: Self.espessura, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: LabTheme.accent.opacity(0.5), radius: ativo ? 12 : 6)

            // A ponta acesa.
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .shadow(color: LabTheme.accent, radius: 6)
                .offset(y: -raio)
                .rotationEffect(.degrees(225 + 270 * f))
                .opacity(f > 0 ? 1 : 0)

            VStack(spacing: 0) {
                Text(verbatim: Formato.mbps(valor))
                    .font(LabFont.swiftUI(58, .heavy))
                    .monospacedDigit()
                    .tracking(-1.5)
                    .foregroundStyle(LabTheme.text)
                    .contentTransition(.numericText(value: valor))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(verbatim: "Mb/s")
                    .font(LabFont.swiftUI(13, .bold))
                    .tracking(1)
                    .foregroundStyle(LabTheme.muted)
                Text(legenda)
                    .font(LabFont.swiftUI(12.5, .bold))
                    .foregroundStyle(corDaLegenda)
                    .padding(.top, 8)
                    .contentTransition(.opacity)
            }
            .frame(width: Self.lado * 0.62)
            .offset(y: 6)
        }
        .frame(width: Self.lado, height: Self.lado)
        // O arco não desce até embaixo: sem isto sobraria um vão no cartão.
        .padding(.bottom, -Self.lado * 0.12)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: f)
        .animation(.snappy, value: valor)
        .animation(.easeInOut(duration: 0.25), value: legenda)
    }
}

// MARK: - Onda

/// A banda ao longo da leitura. Uma linha reta é rede saudável; dentes de
/// serra são o Wi-Fi brigando com alguém.
private struct Onda: View {
    let valores: [Double]
    let ativa: Bool

    var body: some View {
        let teto = max(1, (valores.max() ?? 1) * 1.15)
        ZStack {
            CurvaDaOnda(valores: valores, teto: teto, fechada: true)
                .fill(LinearGradient(colors: [LabTheme.accent.opacity(0.32), LabTheme.accent.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            CurvaDaOnda(valores: valores, teto: teto, fechada: false)
                .stroke(LinearGradient(colors: [LabTheme.orange, LabTheme.accent],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: LabTheme.accent.opacity(ativa ? 0.6 : 0.3), radius: 4)
        }
        .animation(.linear(duration: 0.2), value: valores.count)
    }
}

private struct CurvaDaOnda: Shape {
    let valores: [Double]
    let teto: Double
    let fechada: Bool

    func path(in r: CGRect) -> Path {
        var caminho = Path()
        guard valores.count > 1 else { return caminho }
        // Durante o teste a onda cresce da esquerda: o eixo é o tempo total.
        let pontos = max(valores.count, Int(TesteDeVelocidade.duracao / 0.2))
        let passo = r.width / CGFloat(pontos - 1)
        func ponto(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) * passo,
                    y: r.maxY - CGFloat(valores[i] / teto) * r.height)
        }
        caminho.move(to: ponto(0))
        for i in 1..<valores.count {
            let anterior = ponto(i - 1)
            let atual = ponto(i)
            let meio = (anterior.x + atual.x) / 2
            caminho.addCurve(to: atual,
                             control1: CGPoint(x: meio, y: anterior.y),
                             control2: CGPoint(x: meio, y: atual.y))
        }
        if fechada {
            caminho.addLine(to: CGPoint(x: ponto(valores.count - 1).x, y: r.maxY))
            caminho.addLine(to: CGPoint(x: 0, y: r.maxY))
            caminho.closeSubpath()
        }
        return caminho
    }
}

// MARK: - O que dá para tocar

private struct Escada: View {
    let mbps: Double

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DegrauDeQualidade.allCases) { degrau in
                let cabe = mbps >= degrau.minimo
                VStack(spacing: 4) {
                    Image(systemName: cabe ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .heavy))
                    Text(degrau.nome)
                        .font(LabFont.swiftUI(11, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(cabe ? LabTheme.green : LabTheme.faint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(cabe ? LabTheme.green.opacity(0.13) : Color.white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(cabe ? LabTheme.green.opacity(0.35) : Color.clear, lineWidth: 0.5)
                )
            }
        }
    }
}

// MARK: - Lista

private struct CartaoDeServidor: View {
    let alvo: AlvoDeTeste
    @ObservedObject var teste: TesteDeVelocidade
    let emFoco: Bool
    let acao: () -> Void

    private var medindo: Bool { teste.emTeste == alvo.id }
    private var naFila: Bool { teste.fila.contains(alvo.id) }
    private var resultado: ResultadoDeVelocidade? { teste.resultados[alvo.id] }
    private var falha: String? { teste.falhas[alvo.id] }

    var body: some View {
        Button(action: acao) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    IconeDoServidor(alvo: alvo, tamanho: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alvo.nome)
                            .font(LabFont.swiftUI(15, .semibold))
                            .foregroundStyle(LabTheme.text)
                            .lineLimit(1)
                        Text(verbatim: "\(alvo.tipo) · \(alvo.endereco)")
                            .font(LabFont.swiftUI(12, .medium))
                            .foregroundStyle(LabTheme.muted)
                            .lineLimit(1)
                        situacao
                    }
                    Spacer(minLength: 8)
                    lado
                }
                if let resultado, !medindo, falha == nil {
                    BarraDeNivel(mbps: resultado.mbps)
                }
            }
            .padding(12)
            .labCard()
            .overlay(
                RoundedRectangle(cornerRadius: LabTheme.radiusCard, style: .continuous)
                    .strokeBorder(LabTheme.accent.opacity(medindo ? 0.8 : (emFoco ? 0.35 : 0)), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: medindo)
        .animation(.snappy, value: resultado)
    }

    @ViewBuilder private var situacao: some View {
        if medindo {
            Text(teste.fase == .resposta ? String(localized: "Medindo a resposta…") :
                    teste.fase == .preparando ? String(localized: "Procurando o que ler…") :
                    String(localized: "Lendo do servidor…"))
                .font(LabFont.swiftUI(11.5, .semibold))
                .foregroundStyle(LabTheme.accent)
        } else if naFila {
            Text("Na fila")
                .font(LabFont.swiftUI(11.5, .semibold))
                .foregroundStyle(LabTheme.faint)
        } else if let falha {
            Text(falha)
                .font(LabFont.swiftUI(11.5, .semibold))
                .foregroundStyle(LabTheme.orange)
                .lineLimit(2)
        } else if let resultado {
            Text(verbatim: [Formato.quando(resultado.quando), resultado.interface]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(LabFont.swiftUI(11.5, .medium))
                .foregroundStyle(LabTheme.faint)
        }
    }

    @ViewBuilder private var lado: some View {
        if medindo {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.04, teste.progresso))
                    .stroke(LabTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: teste.progresso)
                Text(verbatim: Formato.mbps(teste.agora))
                    .font(LabFont.swiftUI(10, .bold))
                    .monospacedDigit()
                    .foregroundStyle(LabTheme.text)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            }
            .frame(width: 44, height: 44)
        } else if let resultado, falha == nil {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: Formato.mbps(resultado.mbps))
                        .font(LabFont.swiftUI(22, .heavy))
                        .monospacedDigit()
                        .foregroundStyle(LabTheme.text)
                    Text(verbatim: "Mb/s")
                        .font(LabFont.swiftUI(10.5, .bold))
                        .foregroundStyle(LabTheme.muted)
                }
                if let resposta = resultado.resposta {
                    Text(verbatim: "\(Formato.milissegundos(resposta)) ms")
                        .font(LabFont.swiftUI(11, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(LabTheme.faint)
                }
            }
        } else {
            Text(falha == nil ? String(localized: "Testar") : String(localized: "De novo"))
                .font(LabFont.swiftUI(13, .bold))
                .foregroundStyle(LabTheme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(LabTheme.accent.opacity(0.14), in: Capsule())
        }
    }
}

/// A banda do servidor na mesma escala do velocímetro, com as faixas de
/// qualidade marcadas por baixo.
private struct BarraDeNivel: View {
    let mbps: Double

    var body: some View {
        GeometryReader { geo in
            let f = CGFloat(Velocimetro.fracao(mbps))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [LabTheme.orange, Cores.da(mbps)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * f))
                ForEach(DegrauDeQualidade.allCases) { degrau in
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * CGFloat(Velocimetro.fracao(degrau.minimo)))
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }
}

private struct IconeDoServidor: View {
    let alvo: AlvoDeTeste
    let tamanho: CGFloat

    var body: some View {
        Group {
            if let imagem = alvo.imagem {
                Image(imagem).resizable().scaledToFit()
                    .frame(width: tamanho * 0.55, height: tamanho * 0.55)
            } else {
                Image(systemName: alvo.simbolo)
                    .font(.system(size: tamanho * 0.42, weight: .semibold))
                    .foregroundStyle(LabTheme.accent)
            }
        }
        .frame(width: tamanho, height: tamanho)
        .background(alvo.imagem == nil ? LabTheme.accent.opacity(0.14) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: tamanho * 0.28, style: .continuous))
    }
}

// MARK: - Cor e número

private enum Cores {
    static func da(_ mbps: Double) -> Color {
        switch NotaDeVelocidade(mbps) {
        case .voando, .excelente, .muitoBoa: return LabTheme.green
        case .boa:                           return LabTheme.accent
        case .razoavel:                      return LabTheme.orange
        case .fraca:                         return LabTheme.red
        }
    }
}

extension Plural {
    static func quedas(_ n: Int) -> String {
        n == 1 ? String(localized: "A leitura caiu 1 vez e foi refeita: o vídeo pode engasgar.")
               : String(localized: "A leitura caiu \(n) vezes e foi refeita: o vídeo pode engasgar.")
    }
}

extension Formato {
    /// "7,4" abaixo de 10, inteiro daí para cima: casa decimal em 347 é ruído.
    static func mbps(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 && v > 0 ? 1 : 0)))
    }

    static func milissegundos(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 1 : 0)))
    }

    static func megabytes(_ v: Double) -> String {
        v >= 1000
            ? ByteCountFormatter.string(fromByteCount: Int64(v * 1_000_000), countStyle: .decimal)
            : "\(Int(v.rounded())) MB"
    }

    static func quando(_ data: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        // Recém-medido sai "agora", e não "em 0 s" (o relógio andou um tico).
        if Date().timeIntervalSince(data) < 5 { return String(localized: "agora") }
        return f.localizedString(for: min(data, Date()), relativeTo: Date())
    }
}

import SwiftUI

// As peças da biblioteca, compartilhadas com a pasta do servidor — as duas
// telas de vídeo têm que ter a mesma cara, senão parecem dois apps.

// MARK: - Fundo

/// O fundo das telas de navegação: a capa do que se está vendo, desfocada.
///
/// Um fundo preto liso deixa a tela parecendo planilha; uma imagem fixa
/// qualquer vira papel de parede e envelhece na primeira semana. A capa do
/// próprio acervo muda com ele — na biblioteca é o vídeo que você estava
/// assistindo, dentro da pasta é a capa da pasta —, então o fundo diz onde você
/// está sem uma palavra. É o que o app da Apple TV faz.
struct FundoDeCapa: View {
    let capa: MediaItem?
    @State private var imagem: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LabTheme.background

                if let imagem {
                    Image(uiImage: imagem)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height * 0.6)
                        .clipped()
                        .blur(radius: 28, opaque: true)
                        .opacity(0.55)
                        .transition(.opacity)
                        .id(capa?.origin.resumeKey)
                }

                // A capa se dissolve antes do meio da tela: é ambiente, e não
                // pode disputar a leitura com as miniaturas por cima dela.
                LinearGradient(stops: [
                    .init(color: LabTheme.background.opacity(0.30), location: 0),
                    .init(color: LabTheme.background.opacity(0.62), location: 0.28),
                    .init(color: LabTheme.background, location: 0.58),
                ], startPoint: .top, endPoint: .bottom)

                // Um halo dourado vindo do canto, da cor da marca. Sem capa, é
                // ele que impede o fundo de ser só preto.
                RadialGradient(colors: [LabTheme.accent.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.05, y: -0.02),
                               startRadius: 0, endRadius: geo.size.width * 1.05)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.7), value: imagem)
        // Guarda a última imagem enquanto a próxima carrega: sem isso o fundo
        // piscaria preto a cada troca de pasta.
        .task(id: capa?.origin.resumeKey) {
            guard let capa else { imagem = nil; return }
            if let pronta = ThumbnailStore.shared.cached(capa) { imagem = pronta; return }
            if let nova = await ThumbnailStore.shared.load(capa) { imagem = nova }
        }
    }
}

// MARK: - Cabeçalhos

/// O título grande de cada tela e, embaixo, o resumo em letra pequena.
struct TituloDeTela: View {
    let titulo: String
    let subtitulo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo)
                .font(LabTheme.headline)
                .tracking(-0.8)
                .foregroundStyle(LabTheme.text)
                .lineLimit(2)
            Text(subtitulo)
                .font(LabFont.swiftUI(13, .medium))
                .foregroundStyle(LabTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// Título de seção: um traço dourado antes, que marca a seção sem precisar de
/// linha divisória atravessando a tela.
struct Secao: View {
    let titulo: String
    var extra: String? = nil

    var body: some View {
        HStack(spacing: 9) {
            Capsule().fill(LabTheme.accent).frame(width: 3, height: 14)
            Text(titulo.uppercased())
                .font(LabFont.swiftUI(11.5, .bold))
                .tracking(1.6)
                .foregroundStyle(LabTheme.text.opacity(0.8))
            if let extra {
                Text(extra)
                    .font(LabFont.swiftUI(11.5, .bold))
                    .tracking(1.6)
                    .foregroundStyle(LabTheme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

/// O símbolo e o nome, com o X na cor da marca — o app se apresenta.
struct MarcaDoApp: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("AppIconSymbol")
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            (Text("Liberty").foregroundStyle(LabTheme.text)
             + Text("X").foregroundStyle(LabTheme.accent))
                .font(LabFont.swiftUI(19, .heavy))
                .tracking(-0.3)
        }
    }
}

/// Botão redondo de vidro da barra de cima.
struct BotaoRedondo: View {
    let simbolo: String

    var body: some View {
        Image(systemName: simbolo)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LabTheme.text)
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(0.08), in: Circle())
            .overlay(Circle().strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
    }
}

// MARK: - Pasta como capa

/// A capa de uma pasta: o vídeo mais novo dela, que é o que se reconhece.
func capaDa(_ grupo: VideoGroup) -> MediaItem? {
    grupo.items.max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
        ?? grupo.items.first
}

/// A pasta como capa, com duas folhas atrás.
///
/// As folhas são o que diz "pasta" sem ícone de pasta: a imagem sozinha seria
/// confundida com um vídeo, e o ícone amarelo do sistema é justamente o que
/// deixava a tela com cara de gerenciador de arquivos.
struct CapaDePasta: View {
    let grupo: VideoGroup

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let w = geo.size.width
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: w * 0.76, height: 20)
                    .offset(x: w * 0.12, y: 0)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: w * 0.88, height: 20)
                    .offset(x: w * 0.06, y: 5)
            }
            .frame(height: 20)

            ZStack(alignment: .bottomLeading) {
                Miniatura(item: capaDa(grupo))
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.7), location: 0.75),
                    .init(color: .black.opacity(0.92), location: 1),
                ], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 2) {
                    Text(grupo.name)
                        .font(LabFont.swiftUI(15, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(grupo.items.count == 1 ? "1 vídeo" : "\(grupo.items.count) vídeos")
                        .font(LabFont.swiftUI(11, .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(12)
            }
            .aspectRatio(1.3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: LabTheme.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LabTheme.radiusCard, style: .continuous)
                .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
            .padding(.top, 10)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Continuar assistindo

/// Continuar: a miniatura larga, a barra do quanto já foi, e quanto falta.
struct CartaoDeContinuar: View {
    let item: MediaItem

    var body: some View {
        let chave = item.origin.resumeKey
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Miniatura(item: item)
                Color.black.opacity(0.18)
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            }
            .overlay(alignment: .bottom) { BarraDeProgresso(progresso: ResumeStore.shared.progress(for: chave)) }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))

            Text(item.title)
                .font(LabFont.swiftUI(13, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .padding(.top, 8)
            if let falta = ResumeStore.shared.remaining(for: chave) {
                Text("faltam \(TimeFormat.spoken(falta))")
                    .font(LabFont.swiftUI(11, .medium))
                    .foregroundStyle(LabTheme.muted)
            }
        }
        .frame(width: 236)
        .contentShape(Rectangle())
    }
}

// MARK: - Vídeos

/// Grade: a miniatura vira o elemento principal, com a duração sobre ela — é
/// como se reconhece um vídeo gravado pelo celular, cujo nome é só data e hora.
/// Sem caixa em volta: o título solto embaixo da imagem, como numa locadora,
/// deixa a tela respirar mais que um cartão dentro de outro.
struct VideoCard: View {
    let item: MediaItem

    var body: some View {
        let progresso = ResumeStore.shared.progress(for: item.origin.resumeKey)
        VStack(alignment: .leading, spacing: 2) {
            Miniatura(item: item)
                .overlay(alignment: .bottomTrailing) {
                    Duracao(item: item).padding(.trailing, 7).padding(.bottom, progresso != nil ? 9 : 7)
                }
                .overlay(alignment: .bottom) { BarraDeProgresso(progresso: progresso) }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
                .padding(.bottom, 6)

            Text(item.title)
                .font(LabFont.swiftUI(13, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Detalhes(item: item)
        }
        .contentShape(Rectangle())
    }
}

/// Lista: mais itens por tela, bom para pastas com muitos vídeos.
struct VideoRow: View {
    let item: MediaItem

    var body: some View {
        let progresso = ResumeStore.shared.progress(for: item.origin.resumeKey)
        HStack(spacing: 14) {
            Miniatura(item: item)
                .overlay(alignment: .bottomTrailing) { Duracao(item: item).padding(5) }
                .overlay(alignment: .bottom) { BarraDeProgresso(progresso: progresso) }
                // Largura e altura fixas, e não proporção: numa pilha
                // preguiçosa a altura proposta pode vir indefinida, e a
                // miniatura sairia sem tamanho.
                .frame(width: 124, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(LabFont.swiftUI(14, .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Detalhes(item: item)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A linha de baixo do título. Quem parou no meio quer saber quanto falta; quem
/// não começou quer saber o tamanho e de quando é.
struct Detalhes: View {
    let item: MediaItem

    var body: some View {
        let chave = item.origin.resumeKey
        if ResumeStore.shared.position(for: chave) != nil {
            let falta = ResumeStore.shared.remaining(for: chave)
            Text(falta.map { "faltam \(TimeFormat.spoken($0))" } ?? "em andamento")
                .font(LabFont.swiftUI(11, .semibold))
                .foregroundStyle(LabTheme.accent)
        } else {
            let partes = [FolderScanner.humanSize(item.fileSize),
                          item.modifiedAt.map { $0.formatted(date: .abbreviated, time: .omitted) }]
                .compactMap { $0 }
            if !partes.isEmpty {
                Text(partes.joined(separator: "  ·  "))
                    .font(LabFont.swiftUI(11, .medium))
                    .foregroundStyle(LabTheme.muted)
            }
        }
    }
}

/// A duração numa pastilha, no canto da miniatura. No servidor ela só se
/// conhece depois da miniatura, e aparece assim que fica pronta.
struct Duracao: View {
    let item: MediaItem

    var body: some View {
        if let duracao = ThumbnailStore.shared.duration(item) {
            Text(TimeFormat.clock(duracao))
                .font(LabFont.swiftUI(10, .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// A régua do quanto já foi visto, rente à base da miniatura.
struct BarraDeProgresso: View {
    let progresso: Double?

    var body: some View {
        if let progresso {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(LabTheme.accent)
                        .frame(width: geo.size.width * max(progresso, 0.03))
                }
            }
            .frame(height: 3)
        }
    }
}

/// A miniatura.
///
/// O espaço reservado tem o mesmo tamanho da imagem final para a lista não
/// pular quando as miniaturas chegam — nada mais desagradável que a linha que
/// você ia tocar se mexer no instante do toque. Sem forma própria: quem a usa
/// decide proporção e cantos.
///
/// A imagem vai numa camada por cima do fundo, e não ao lado dele numa pilha:
/// preenchendo o espaço, uma miniatura de vídeo em pé cresce para baixo muito
/// além do cartão, e a pilha adotaria esse tamanho — as capas saíam do lugar e
/// se empilhavam umas sobre as outras. Por cima, quem manda no tamanho é o
/// fundo, que ocupa exatamente o que lhe dão; a imagem só é recortada nele.
struct Miniatura: View {
    let item: MediaItem?
    @State private var imagem: UIImage?

    var body: some View {
        LinearGradient(colors: [Color(red: 0.137, green: 0.133, blue: 0.157),
                                Color(red: 0.086, green: 0.086, blue: 0.102)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        .overlay {
            if let imagem {
                Image(uiImage: imagem)
                    .resizable()
                    .scaledToFill()
                    // A sobra recortada ainda receberia toques, roubando-os
                    // do cartão vizinho.
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 20))
                    .foregroundStyle(LabTheme.faint)
            }
        }
        .clipped()
        .task(id: item?.origin.resumeKey) {
            guard let item else { imagem = nil; return }
            if let pronta = ThumbnailStore.shared.cached(item) {
                imagem = pronta
                return
            }
            // Só duas miniaturas são geradas por vez; quem não pegou vez volta
            // a tentar, senão a linha ficaria sem imagem para sempre depois de
            // uma rolagem rápida.
            for _ in 0..<12 {
                if let pronta = await ThumbnailStore.shared.load(item) {
                    imagem = pronta
                    return
                }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }
}

/// O cartão da rede — na tela vazia, onde a barra de cima não aparece.
struct CartaoDaRede: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(LabTheme.accent)
                .frame(width: 44, height: 44)
                .background(LabTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Servidores SMB")
                    .font(LabFont.swiftUI(15, .bold))
                    .foregroundStyle(LabTheme.text)
                Text("Os vídeos do computador ou do NAS de casa")
                    .font(LabFont.swiftUI(12, .medium))
                    .foregroundStyle(LabTheme.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LabTheme.faint)
        }
        .padding(14)
        .labCard()
    }
}

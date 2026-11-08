import SwiftUI

/// A página de um filme ou episódio do Jellyfin ou Emby antes de tocar, como
/// no app do próprio servidor: o fundo e o logotipo da série, a data, a
/// duração, a nota, a que horas termina, as faixas do arquivo, a sinopse, os
/// outros episódios da temporada e o elenco.
///
/// Nada disto é do app: os textos, as fotos e o logotipo são o que os
/// provedores de metadados do servidor (TMDB, OMDb, AniDB…) trouxeram, e as
/// faixas são a leitura que ele fez do arquivo. A tela só pergunta e desenha.
struct DetalhesDoServidorView: View {
    let servidor: ServidorDeMidia
    let inicial: ServidorDeMidia.Item

    var escala = Escala()

    @State private var item: ServidorDeMidia.Item?
    @State private var detalhes: ServidorDeMidia.Detalhes?
    @State private var temporada: [ServidorDeMidia.Item] = []
    @State private var falha: String?
    @State private var falhaDeAcao: String?
    @State private var tocando: MediaItem?
    @State private var fila: [MediaItem] = []
    @State private var sinopseAberta = false
    /// As faixas escolhidas nos seletores, pelo número do servidor.
    @State private var audioEscolhido: Int?
    @State private var legendaEscolhida: LegendaEscolhida = .automatica
    @State private var qualidade = 0
    @State private var extras: [ServidorDeMidia.Item] = []
    @Environment(\.openURL) private var abrirEndereco
    /// Conta as voltas do player e as marcas: onde parou e o "visto" mudam.
    @State private var volta = 0

    private typealias Item = ServidorDeMidia.Item

    private var atual: Item { item ?? inicial }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cabeca
                VStack(alignment: .leading, spacing: 18) {
                    titulos
                    botoes
                    if let detalhes { faixas(detalhes) }
                    if let sinopse = detalhes?.sinopse { textoDaSinopse(sinopse) }
                    if let detalhes { creditos(detalhes) }
                    if let falha {
                        Label(falha, systemImage: "wifi.exclamationmark")
                            .font(LabFont.swiftUI(13, .medium))
                            .foregroundStyle(LabTheme.muted)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: Escala.larguraMaxima, alignment: .leading)

                if temporada.count > 1 { maisDaTemporada.padding(.top, 26) }
                if let elenco = detalhes?.pessoasCom(["Actor", "GuestStar"]), !elenco.isEmpty {
                    FaixaDoElenco(servidor: servidor, elenco: Array(elenco.prefix(30))).padding(.top, 26)
                }
                if !extras.isEmpty { faixaDeExtras.padding(.top, 26) }
            }
            .padding(.bottom, 32)
        }
        .background(LabTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: volta) { await carregar() }
        .onAppear { qualidade = Qualidade.da(servidor.conta.id) }
        .fullScreenCover(item: $tocando, onDismiss: { volta += 1 }) { item in
            PlayerScreen(item: item, playlist: fila).ignoresSafeArea()
        }
        .alert("Não conectou", isPresented: Binding(get: { falhaDeAcao != nil },
                                                    set: { if !$0 { falhaDeAcao = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(falhaDeAcao ?? "")
        }
    }

    // MARK: - Partes

    private var cabeca: some View {
        CabecaDoServidor(servidor: servidor, fundoDe: detalhes?.fundoDe ?? atual.serieID ?? atual.id,
                         logoDe: detalhes?.logoDe)
    }

    private var titulos: some View {
        VStack(alignment: .leading, spacing: 6) {
            if atual.tipo == "Episode", let serieID = atual.serieID {
                // O nome da série leva à página dela, com as temporadas.
                NavigationLink {
                    SerieDoServidorView(servidor: servidor, serieID: serieID, nome: atual.serie ?? "")
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: atual.serie ?? atual.nome)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LabTheme.muted)
                    }
                    .font(LabFont.swiftUI(24, .heavy))
                    .foregroundStyle(LabTheme.text)
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: atual.nome)
                    .font(LabFont.swiftUI(24, .heavy))
                    .foregroundStyle(LabTheme.text)
            }
            if atual.tipo == "Episode" {
                Text(verbatim: [detalhes?.nomeDaTemporada, atual.numero.map { "\($0). \(atual.nome)" } ?? atual.nome]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(LabFont.swiftUI(15, .semibold))
                    .foregroundStyle(LabTheme.text.opacity(0.85))
            }
            HStack(spacing: 12) {
                ForEach(Array(informacoes.enumerated()), id: \.offset) { _, info in
                    Text(verbatim: info)
                }
                if let nota = detalhes?.nota {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").foregroundStyle(LabTheme.accent)
                        Text(verbatim: String(format: "%.1f", nota))
                    }
                }
                if let classificacao = detalhes?.classificacao {
                    Text(verbatim: classificacao)
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(LabTheme.faint, lineWidth: 1))
                }
            }
            .font(LabFont.swiftUI(12.5, .medium))
            .foregroundStyle(LabTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(.top, detalhes?.logoDe == nil ? 0 : 8)
    }

    /// Data (o ano, num filme), duração e a hora em que termina se começar agora.
    private var informacoes: [String] {
        var partes: [String] = []
        if atual.tipo == "Episode", let estreia = detalhes?.estreia {
            partes.append(estreia.formatted(date: .numeric, time: .omitted))
        } else if let ano = atual.ano {
            partes.append(String(ano))
        }
        if let duracao = atual.duracao {
            partes.append(TimeFormat.spoken(duracao))
            let fim = Date().addingTimeInterval(max(0, duracao - (atual.posicao ?? 0)))
            partes.append(String(localized: "Termina às \(fim.formatted(date: .omitted, time: .shortened))"))
        }
        return partes
    }

    private var botoes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { tocar(atual.posicao == nil ? nil : .continuar) } label: {
                    VStack(spacing: 1) {
                        Label(atual.posicao == nil ? String(localized: "Assistir") : String(localized: "Continuar"),
                              systemImage: "play.fill")
                            .font(LabFont.swiftUI(16, .bold))
                        if let posicao = atual.posicao {
                            Text(verbatim: TimeFormat.clock(posicao))
                                .font(LabFont.swiftUI(11, .semibold))
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(LabTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                // Com o vídeo começado, as duas saídas lado a lado, como no
                // app do Jellyfin: seguir de onde parou ou rever do começo.
                if atual.posicao != nil {
                    Button { tocar(.doComeco) } label: {
                        Label(String(localized: "Do início"), systemImage: "backward.end.fill")
                            .font(LabFont.swiftUI(14, .bold))
                            .foregroundStyle(LabTheme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(LabTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(LabTheme.glassBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            // As marcas numa fileira própria: com "Continuar" e "Do início"
            // lado a lado, cinco botões numa linha só não cabiam no iPhone.
            HStack(spacing: 10) {
                BotaoDeMarca(simbolo: "checkmark", aceso: atual.visto, cor: LabTheme.accent,
                             rotulo: String(localized: "Já reproduzido")) { mudarVisto() }
                BotaoDeMarca(simbolo: atual.favorito ? "heart.fill" : "heart", aceso: atual.favorito,
                             cor: LabTheme.red, rotulo: String(localized: "Favorito")) { mudarFavorito() }
                if let detalhes, detalhes.trailersNoDisco > 0 || !detalhes.trailersDaInternet.isEmpty {
                    BotaoDeMarca(simbolo: "film", aceso: false, cor: LabTheme.accent,
                                 rotulo: String(localized: "Trailer")) { tocarTrailer(detalhes) }
                }
                Spacer(minLength: 0)
            }
            if let progresso = atual.progresso, let posicao = atual.posicao, let duracao = atual.duracao {
                VStack(alignment: .leading, spacing: 5) {
                    BarraDeProgresso(progresso: progresso)
                        .clipShape(Capsule())
                    Text("faltam \(TimeFormat.spoken(max(0, duracao - posicao)))")
                        .font(LabFont.swiftUI(11.5, .medium))
                        .foregroundStyle(LabTheme.faint)
                }
            }
        }
    }

    /// Vídeo, áudio e legendas como o servidor leu o arquivo, com os
    /// seletores do app do Jellyfin: a faixa escolhida aqui é a que o player
    /// abre. A qualidade vale para a conta inteira (ver `Qualidade`).
    private func faixas(_ detalhes: ServidorDeMidia.Detalhes) -> some View {
        let audios = detalhes.fluxosDo("Audio")
        let legendas = detalhes.fluxosDo("Subtitle")
        return VStack(alignment: .leading, spacing: 11) {
            linha("Vídeo", detalhes.faixasDo("Video"))
            if !audios.isEmpty {
                seletor("Áudio", titulo: audios.first { $0.indice == audioEscolhido }?.titulo ?? audios[0].titulo) {
                    ForEach(audios, id: \.indice) { faixa in
                        Button { audioEscolhido = faixa.indice } label: {
                            marcado(faixa.titulo, audioEscolhido == faixa.indice)
                        }
                    }
                }
            }
            seletor("Legendas", titulo: tituloDaLegenda(legendas)) {
                Button { legendaEscolhida = .automatica } label: {
                    marcado(String(localized: "Automática (só as forçadas)"), legendaEscolhida == .automatica)
                }
                Button { legendaEscolhida = .desligada } label: {
                    marcado(String(localized: "Desligada"), legendaEscolhida == .desligada)
                }
                ForEach(legendas, id: \.indice) { faixa in
                    Button { legendaEscolhida = .faixa(faixa.indice) } label: {
                        marcado(faixa.titulo, legendaEscolhida == .faixa(faixa.indice))
                    }
                }
            }
            seletor("Qualidade", titulo: Qualidade.nome(qualidade)) {
                ForEach(Qualidade.opcoes, id: \.self) { kbps in
                    Button {
                        qualidade = kbps
                        Qualidade.definir(kbps, para: servidor.conta.id)
                    } label: {
                        marcado(Qualidade.nome(kbps), qualidade == kbps)
                    }
                }
            }
            if qualidade > 0 {
                Text("O servidor converte o vídeo para esta qualidade. Legendas de dentro do arquivo não vêm junto.")
                    .font(LabFont.swiftUI(11, .medium))
                    .foregroundStyle(LabTheme.faint)
            }
        }
        .padding(14)
        .background(LabTheme.glass, in: RoundedRectangle(cornerRadius: LabTheme.radiusSmall, style: .continuous))
    }

    private func tituloDaLegenda(_ legendas: [ServidorDeMidia.Detalhes.Fluxo]) -> String {
        switch legendaEscolhida {
        case .automatica:
            return legendas.isEmpty ? String(localized: "Nenhuma") : String(localized: "Automática (só as forçadas)")
        case .desligada:
            return String(localized: "Desligada")
        case .faixa(let indice):
            return legendas.first { $0.indice == indice }?.titulo ?? String(localized: "Desligada")
        }
    }

    @ViewBuilder
    private func linha(_ titulo: LocalizedStringKey, _ valores: [String]) -> some View {
        if !valores.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(titulo)
                    .font(LabFont.swiftUI(12.5, .semibold))
                    .foregroundStyle(LabTheme.muted)
                    .frame(width: 80 * escala.fator, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(valores.prefix(2).enumerated()), id: \.offset) { _, valor in
                        Text(verbatim: valor)
                    }
                }
                .font(LabFont.swiftUI(12.5, .medium))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
            }
        }
    }

    private func seletor<Opcoes: View>(_ rotulo: LocalizedStringKey, titulo: String,
                                       @ViewBuilder opcoes: () -> Opcoes) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(rotulo)
                .font(LabFont.swiftUI(12.5, .semibold))
                .foregroundStyle(LabTheme.muted)
                .frame(width: 80 * escala.fator, alignment: .leading)
            Menu {
                opcoes()
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: titulo)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LabTheme.muted)
                }
                .font(LabFont.swiftUI(12.5, .medium))
                .foregroundStyle(LabTheme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func marcado(_ titulo: String, _ escolhido: Bool) -> some View {
        if escolhido {
            Label(titulo, systemImage: "checkmark")
        } else {
            Text(verbatim: titulo)
        }
    }

    private func textoDaSinopse(_ sinopse: String) -> some View {
        Text(verbatim: sinopse)
            .font(LabFont.swiftUI(14, .regular))
            .foregroundStyle(LabTheme.text.opacity(0.88))
            .lineLimit(sinopseAberta ? nil : 4)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { sinopseAberta.toggle() } }
    }

    @ViewBuilder
    private func creditos(_ detalhes: ServidorDeMidia.Detalhes) -> some View {
        let direcao = detalhes.pessoasCom(["Director"]).map(\.nome)
        let roteiro = detalhes.pessoasCom(["Writer"]).map(\.nome)
        if !detalhes.generos.isEmpty || !direcao.isEmpty || !roteiro.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                credito("Gêneros", detalhes.generos)
                credito("Direção", direcao)
                credito("Roteiro", roteiro)
            }
        }
    }

    @ViewBuilder
    private func credito(_ titulo: LocalizedStringKey, _ nomes: [String]) -> some View {
        if !nomes.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(titulo)
                    .font(LabFont.swiftUI(12.5, .semibold))
                    .foregroundStyle(LabTheme.muted)
                    .frame(width: 74 * escala.fator, alignment: .leading)
                Text(verbatim: nomes.prefix(6).joined(separator: ", "))
                    .font(LabFont.swiftUI(12.5, .medium))
                    .foregroundStyle(LabTheme.text)
            }
        }
    }

    /// Os outros episódios da temporada, já rolados até este.
    private var maisDaTemporada: some View {
        VStack(alignment: .leading, spacing: 10) {
            Secao(titulo: String(localized: "Mais de \(detalhes?.nomeDaTemporada ?? String(localized: "Temporada"))"))
                .padding(.horizontal, 16)
            ScrollViewReader { rolagem in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(temporada) { episodio in
                            NavigationLink {
                                DetalhesDoServidorView(servidor: servidor, inicial: episodio)
                            } label: {
                                CartaoDeitado(servidor: servidor, item: episodio)
                                    .overlay(alignment: .top) {
                                        if episodio.id == atual.id {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(LabTheme.accent, lineWidth: 2)
                                                .aspectRatio(16 / 9, contentMode: .fit)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(episodio.id == atual.id)
                            .id(episodio.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear { rolagem.scrollTo(atual.id, anchor: .leading) }
            }
        }
    }

    /// Bastidores, cenas cortadas, entrevistas — tocam direto.
    private var faixaDeExtras: some View {
        VStack(alignment: .leading, spacing: 10) {
            Secao(titulo: String(localized: "Extras"))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(extras) { extra in
                        Button { tocarSozinho(extra) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ImagemDoServidor(servidor: servidor, id: extra.id, tipos: ["Primary", "Thumb"], largura: 480)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(verbatim: extra.nome)
                                    .font(LabFont.swiftUI(12.5, .semibold))
                                    .foregroundStyle(LabTheme.text)
                                    .lineLimit(2)
                                    .padding(.top, 7)
                            }
                            .frame(width: 220 * escala.fator)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Ações

    /// Episódio toca com a temporada em volta, para o "próximo" do player ir
    /// ao episódio seguinte. O "Você parou em…" é o próprio player que oferece.
    private func tocar(_ inicio: EscolhaDeFaixas.Inicio? = nil) {
        let lista = atual.tipo == "Episode" && temporada.contains(where: { $0.id == atual.id })
            ? temporada : [atual]
        let itens = lista.map(servidor.paraTocar)
        let alvo = servidor.paraTocar(atual).origin
        pedirFaixas(chave: alvo.resumeKey)
        if let inicio { EscolhaDeFaixas.shared.pedirInicio(inicio, para: alvo.resumeKey) }
        fila = itens
        tocando = itens.first { $0.origin == alvo }
    }

    /// Leva os seletores ao player. A posição conta só as faixas de dentro do
    /// arquivo, que é como o VLC as enxerga; a de fora vai pelo número.
    private func pedirFaixas(chave: String) {
        guard let detalhes else { return }
        let audios = detalhes.fluxosDo("Audio").filter { !$0.externo }
        let padrao = audios.first(where: \.padrao)?.indice ?? audios.first?.indice
        var pedido = EscolhaDeFaixas.Pedido()
        if qualidade > 0 {
            // Na conversão o servidor manda uma faixa só: a escolhida.
            Conversoes.shared.pedirAudio(audioEscolhido, para: atual.id)
        } else if let escolhido = audioEscolhido, escolhido != padrao {
            pedido.audio = audios.firstIndex { $0.indice == escolhido }
        }
        switch legendaEscolhida {
        case .automatica:
            break
        case .desligada:
            pedido.legenda = .desligada
        case .faixa(let indice):
            let legendas = detalhes.fluxosDo("Subtitle")
            if let faixa = legendas.first(where: { $0.indice == indice }) {
                if faixa.externo {
                    pedido.legenda = .externa(indice: indice)
                } else if let posicao = legendas.filter({ !$0.externo }).firstIndex(where: { $0.indice == indice }) {
                    pedido.legenda = .interna(posicao: posicao)
                }
            }
        }
        EscolhaDeFaixas.shared.pedir(pedido, para: chave)
    }

    /// Trailer e extra tocam sozinhos, sem fila.
    private func tocarSozinho(_ video: Item) {
        let unico = servidor.paraTocar(video)
        fila = [unico]
        tocando = unico
    }

    /// O trailer guardado no disco toca aqui; o da internet abre no YouTube.
    private func tocarTrailer(_ detalhes: ServidorDeMidia.Detalhes) {
        Task { @MainActor in
            if detalhes.trailersNoDisco > 0,
               let trailer = try? await servidor.trailersNoDisco(atual.id).first {
                tocarSozinho(trailer)
            } else if let endereco = detalhes.trailersDaInternet.first {
                abrirEndereco(endereco)
            }
        }
    }

    private func mudarVisto() {
        let visto = !atual.visto
        let chave = MediaOrigin.midia(conta: servidor.conta.id, item: atual.id).resumeKey
        Task { @MainActor in
            do {
                try await servidor.marcarVisto(atual.id, visto)
                // O servidor zera onde parou nos dois sentidos; a marca daqui segue.
                ResumeStore.shared.clear(key: chave)
                volta += 1
            } catch where error.foiCancelado {
                return
            } catch {
                falhaDeAcao = error.localizedDescription
            }
        }
    }

    private func mudarFavorito() {
        let favorito = !atual.favorito
        Task { @MainActor in
            do {
                try await servidor.marcarFavorito(atual.id, favorito)
                volta += 1
            } catch where error.foiCancelado {
                return
            } catch {
                falhaDeAcao = error.localizedDescription
            }
        }
    }

    // MARK: - Leitura

    private func carregar() async {
        do {
            let lido = try await servidor.detalhes(inicial.id)
            item = lido.item
            detalhes = lido.detalhes
            falha = nil
            if audioEscolhido == nil {
                let audios = lido.detalhes.fluxosDo("Audio")
                audioEscolhido = audios.first(where: \.padrao)?.indice ?? audios.first?.indice
            }
            if lido.detalhes.extras > 0, extras.isEmpty,
               let lista = try? await servidor.extras(lido.item.id) {
                extras = lista
            }
            if lido.item.tipo == "Episode", let lista = try? await servidor.temporada(lido.item) {
                temporada = lista
            }
        } catch where error.foiCancelado {
            return
        } catch {
            // Com a página já desenhada, uma releitura que falha não a apaga.
            if detalhes == nil { falha = error.localizedDescription }
        }
    }
}

/// O botão redondo do "visto" e do favorito, aceso na cor da marca.
struct BotaoDeMarca: View {
    let simbolo: String
    let aceso: Bool
    let cor: Color
    let rotulo: String
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(aceso ? cor : LabTheme.text)
                .frame(width: 48, height: 48)
                .background(LabTheme.glass, in: Circle())
                .overlay(Circle().strokeBorder(aceso ? cor.opacity(0.7) : LabTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: rotulo))
        .accessibilityAddTraits(aceso ? .isSelected : [])
    }
}

/// O logotipo é PNG transparente: vai inteiro, sem corte e sem fundo — o
/// contrário das capas, que preenchem o cartão.
struct LogoDoServidor: View {
    let servidor: ServidorDeMidia
    let id: String

    @State private var imagem: UIImage?

    var body: some View {
        Group {
            if let imagem {
                Image(uiImage: imagem).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }
        }
        .task(id: id) { imagem = await servidor.imagem(id, tipos: ["Logo"], largura: 800) }
    }
}

/// A legenda escolhida no seletor, pelo número do servidor.
private enum LegendaEscolhida: Hashable {
    case automatica
    case desligada
    case faixa(Int)
}

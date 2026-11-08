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
    @State private var abrindoSerie = false
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
        .navigationDestination(isPresented: $abrindoSerie) {
            if let serieID = atual.serieID {
                SerieDoServidorView(servidor: servidor, serieID: serieID, nome: atual.serie ?? "")
            }
        }
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

    /// Os botões do app do Jellyfin, em ícones numa linha só: tocar (de onde
    /// parou, se parou), do começo, visto, favorito e o ⋯ com o resto.
    private var botoes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                BotaoDeIcone(simbolo: "play.fill", cor: LabTheme.accent, destaque: true,
                             rotulo: atual.posicao == nil ? String(localized: "Assistir") : String(localized: "Continuar")) {
                    tocar(atual.posicao == nil ? nil : .continuar)
                }
                if atual.posicao != nil {
                    BotaoDeIcone(simbolo: "arrow.counterclockwise", rotulo: String(localized: "Do início")) {
                        tocar(.doComeco)
                    }
                }
                BotaoDeIcone(simbolo: "checkmark", cor: LabTheme.accent, aceso: atual.visto,
                             rotulo: String(localized: "Já reproduzido")) { mudarVisto() }
                BotaoDeIcone(simbolo: atual.favorito ? "heart.fill" : "heart", cor: LabTheme.red, aceso: atual.favorito,
                             rotulo: String(localized: "Favorito")) { mudarFavorito() }
                menuDeMais
            }
            .frame(maxWidth: .infinity)
            if let progresso = atual.progresso, let posicao = atual.posicao, let duracao = atual.duracao {
                VStack(alignment: .leading, spacing: 5) {
                    BarraDeProgresso(progresso: progresso)
                        .clipShape(Capsule())
                    Text("Parou em \(TimeFormat.clock(posicao)) · faltam \(TimeFormat.spoken(max(0, duracao - posicao)))")
                        .font(LabFont.swiftUI(11.5, .medium))
                        .foregroundStyle(LabTheme.faint)
                }
            }
        }
    }

    /// O ⋯ do app do Jellyfin: o que não precisa de botão próprio.
    private var menuDeMais: some View {
        Menu {
            if let detalhes, detalhes.trailersNoDisco > 0 || !detalhes.trailersDaInternet.isEmpty {
                Button { tocarTrailer(detalhes) } label: { Label("Trailer", systemImage: "film") }
            }
            if atual.tipo == "Episode", atual.serieID != nil {
                Button { abrindoSerie = true } label: { Label("Ir para a série", systemImage: "tv") }
            }
            if let imdb = detalhes?.idsExternos["Imdb"], let url = URL(string: "https://www.imdb.com/title/\(imdb)") {
                Button { abrirEndereco(url) } label: { Label("Abrir no IMDb", systemImage: "arrow.up.right.square") }
            }
            if atual.tipo == "Movie", let tmdb = detalhes?.idsExternos["Tmdb"],
               let url = URL(string: "https://www.themoviedb.org/movie/\(tmdb)") {
                Button { abrirEndereco(url) } label: { Label("Abrir no TMDB", systemImage: "arrow.up.right.square") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(LabTheme.text)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Mais"))
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
                // Picker, e não botões com ✓: no menu do sistema o texto de
                // todas as opções começa no mesmo lugar, marcada ou não.
                seletor("Áudio", titulo: audios.first { $0.indice == audioEscolhido }?.titulo ?? audios[0].titulo) {
                    Picker(selection: $audioEscolhido) {
                        ForEach(audios, id: \.indice) { faixa in
                            Text(verbatim: faixa.titulo).tag(Int?.some(faixa.indice))
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.inline)
                }
            }
            seletor("Legendas", titulo: tituloDaLegenda(legendas)) {
                Picker(selection: $legendaEscolhida) {
                    Text("Automática (só as forçadas)").tag(LegendaEscolhida.automatica)
                    Text("Desligada").tag(LegendaEscolhida.desligada)
                    ForEach(legendas, id: \.indice) { faixa in
                        Text(verbatim: faixa.titulo).tag(LegendaEscolhida.faixa(faixa.indice))
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            }
            seletor("Qualidade", titulo: Qualidade.nome(qualidade)) {
                Picker(selection: Binding(get: { qualidade }, set: { kbps in
                    qualidade = kbps
                    Qualidade.definir(kbps, para: servidor.conta.id)
                })) {
                    ForEach(Qualidade.opcoes, id: \.self) { kbps in
                        Text(verbatim: Qualidade.nome(kbps)).tag(kbps)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
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

/// Um botão da linha de ícones, como no app do Jellyfin: só o símbolo, sem
/// moldura, aceso na cor dele quando marcado. O de tocar vem num círculo
/// dourado — é a ação da página, e tem de se achar sem procurar.
struct BotaoDeIcone: View {
    let simbolo: String
    var cor: Color = LabTheme.text
    var aceso = false
    var destaque = false
    let rotulo: String
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Group {
                if destaque {
                    Image(systemName: simbolo)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 52, height: 52)
                        .background(cor, in: Circle())
                } else {
                    Image(systemName: simbolo)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(aceso ? cor : LabTheme.text)
                        .frame(width: 52, height: 52)
                }
            }
            .contentShape(Rectangle())
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

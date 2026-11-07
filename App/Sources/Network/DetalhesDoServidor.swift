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
                    faixaDoElenco(Array(elenco.prefix(30))).padding(.top, 26)
                }
            }
            .padding(.bottom, 32)
        }
        .background(LabTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: volta) { await carregar() }
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

    /// O fundo da série (ou do filme), apagando para o preto da página, com o
    /// logotipo por cima — é a cara que o app do servidor dá à mesma página.
    private var cabeca: some View {
        ImagemDoServidor(servidor: servidor, id: detalhes?.fundoDe ?? atual.serieID ?? atual.id,
                         tipos: ["Backdrop", "Thumb", "Primary"], largura: 1280)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                LinearGradient(colors: [.clear, LabTheme.background.opacity(0.55), LabTheme.background],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                if let logo = detalhes?.logoDe {
                    LogoDoServidor(servidor: servidor, id: logo)
                        .frame(maxWidth: 260 * escala.fator, maxHeight: 84 * escala.fator)
                        .padding(.bottom, 6)
                }
            }
    }

    private var titulos: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: atual.tipo == "Episode" ? (atual.serie ?? atual.nome) : atual.nome)
                .font(LabFont.swiftUI(24, .heavy))
                .foregroundStyle(LabTheme.text)
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
                Button(action: tocar) {
                    Label(atual.posicao == nil ? String(localized: "Assistir") : String(localized: "Continuar"),
                          systemImage: "play.fill")
                        .font(LabFont.swiftUI(16, .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(LabTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                BotaoDeMarca(simbolo: "checkmark", aceso: atual.visto, cor: LabTheme.accent,
                             rotulo: String(localized: "Já reproduzido")) { mudarVisto() }
                BotaoDeMarca(simbolo: atual.favorito ? "heart.fill" : "heart", aceso: atual.favorito,
                             cor: LabTheme.red, rotulo: String(localized: "Favorito")) { mudarFavorito() }
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

    /// Vídeo, áudio e legendas como o servidor leu o arquivo. Quem escolhe a
    /// faixa na hora de tocar é o player, pela regra de idioma dos Ajustes.
    private func faixas(_ detalhes: ServidorDeMidia.Detalhes) -> some View {
        let legendas = detalhes.faixasDo("Subtitle")
        return VStack(alignment: .leading, spacing: 9) {
            linha("Vídeo", detalhes.faixasDo("Video"))
            linha("Áudio", detalhes.faixasDo("Audio"))
            linha("Legendas", legendas.isEmpty ? [String(localized: "Nenhuma")] : legendas)
        }
        .padding(14)
        .background(LabTheme.glass, in: RoundedRectangle(cornerRadius: LabTheme.radiusSmall, style: .continuous))
    }

    @ViewBuilder
    private func linha(_ titulo: LocalizedStringKey, _ valores: [String]) -> some View {
        if !valores.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(titulo)
                    .font(LabFont.swiftUI(12.5, .semibold))
                    .foregroundStyle(LabTheme.muted)
                    .frame(width: 74 * escala.fator, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(valores.prefix(4).enumerated()), id: \.offset) { _, valor in
                        Text(verbatim: valor)
                    }
                    if valores.count > 4 {
                        Text(verbatim: "+\(valores.count - 4)").foregroundStyle(LabTheme.faint)
                    }
                }
                .font(LabFont.swiftUI(12.5, .medium))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
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
                    LazyHStack(alignment: .top, spacing: 12) {
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

    private func faixaDoElenco(_ elenco: [ServidorDeMidia.Detalhes.Pessoa]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Secao(titulo: String(localized: "Elenco"))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(elenco) { pessoa in
                        VStack(alignment: .leading, spacing: 0) {
                            ImagemDoServidor(servidor: servidor, id: pessoa.id, tipos: ["Primary"],
                                             largura: 240, semImagem: "person.fill")
                                .aspectRatio(2 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(verbatim: pessoa.nome)
                                .font(LabFont.swiftUI(12, .semibold))
                                .foregroundStyle(LabTheme.text)
                                .lineLimit(2)
                                .padding(.top, 6)
                            if let papel = pessoa.papel {
                                Text(verbatim: papel)
                                    .font(LabFont.swiftUI(11, .medium))
                                    .foregroundStyle(LabTheme.muted)
                                    .lineLimit(2)
                            }
                        }
                        .frame(width: 96 * escala.fator)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Ações

    /// Episódio toca com a temporada em volta, para o "próximo" do player ir
    /// ao episódio seguinte. O "Você parou em…" é o próprio player que oferece.
    private func tocar() {
        let lista = atual.tipo == "Episode" && temporada.contains(where: { $0.id == atual.id })
            ? temporada : [atual]
        let itens = lista.map(servidor.paraTocar)
        let alvo = servidor.paraTocar(atual).origin
        fila = itens
        tocando = itens.first { $0.origin == alvo }
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
private struct BotaoDeMarca: View {
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
private struct LogoDoServidor: View {
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

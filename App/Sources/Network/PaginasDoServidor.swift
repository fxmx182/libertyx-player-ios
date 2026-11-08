import SwiftUI

/// Para onde leva um item do Jellyfin ou do Emby: filme e episódio abrem a
/// página deles, série abre a página da série, e o resto (temporada solta,
/// coleção, pasta) continua sendo uma pasta.
@MainActor @ViewBuilder
func paginaDoServidor(_ servidor: ServidorDeMidia, _ item: ServidorDeMidia.Item) -> some View {
    if item.ehVideo {
        DetalhesDoServidorView(servidor: servidor, inicial: item)
    } else if item.tipo == "Series" {
        SerieDoServidorView(servidor: servidor, serieID: item.id, nome: item.nome)
    } else {
        PastaRemotaView(titulo: item.titulo, destino: .midia(servidor.conta, item))
    }
}

// MARK: - Peças comuns

/// O fundo apagando para o preto da página, com o logotipo por cima — é a
/// cara que o app do servidor dá às páginas de filme, episódio e série.
struct CabecaDoServidor: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let fundoDe: String
    let logoDe: String?

    var body: some View {
        ImagemDoServidor(servidor: servidor, id: fundoDe, tipos: ["Backdrop", "Thumb", "Primary"], largura: 1280)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                LinearGradient(colors: [.clear, LabTheme.background.opacity(0.55), LabTheme.background],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                if let logoDe {
                    LogoDoServidor(servidor: servidor, id: logoDe)
                        .frame(maxWidth: 260 * escala.fator, maxHeight: 84 * escala.fator)
                        .padding(.bottom, 6)
                }
            }
    }
}

/// O elenco com foto; tocar numa pessoa abre a página dela.
struct FaixaDoElenco: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let elenco: [ServidorDeMidia.Detalhes.Pessoa]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Secao(titulo: String(localized: "Elenco"))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(elenco) { pessoa in
                        NavigationLink {
                            PessoaDoServidorView(servidor: servidor, pessoa: pessoa)
                        } label: {
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// Sinopse em quatro linhas; um toque abre o resto.
struct SinopseDoServidor: View {
    let texto: String
    @State private var aberta = false

    var body: some View {
        Text(verbatim: texto)
            .font(LabFont.swiftUI(14, .regular))
            .foregroundStyle(LabTheme.text.opacity(0.88))
            .lineLimit(aberta ? nil : 4)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { aberta.toggle() } }
    }
}

// MARK: - Série

/// A página da série, como no app do Jellyfin: fundo e logotipo, sinopse,
/// o próximo episódio a ver num botão só, as temporadas em abas e os
/// episódios da escolhida, com cena, duração e o quanto já foi visto.
struct SerieDoServidorView: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let serieID: String
    let nome: String

    @State private var serie: ServidorDeMidia.Item?
    @State private var detalhes: ServidorDeMidia.Detalhes?
    @State private var temporadas: [ServidorDeMidia.Item] = []
    @State private var escolhida: String?
    @State private var episodios: [ServidorDeMidia.Item] = []
    @State private var proximo: ServidorDeMidia.Item?
    @State private var falha: String?
    @State private var falhaDeAcao: String?
    @State private var tocando: MediaItem?
    @State private var fila: [MediaItem] = []
    @State private var volta = 0

    private typealias Item = ServidorDeMidia.Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CabecaDoServidor(servidor: servidor, fundoDe: detalhes?.fundoDe ?? serieID, logoDe: detalhes?.logoDe)
                VStack(alignment: .leading, spacing: 18) {
                    titulos
                    botoes
                    if let sinopse = detalhes?.sinopse { SinopseDoServidor(texto: sinopse) }
                    if let generos = detalhes?.generos, !generos.isEmpty {
                        Text(verbatim: generos.prefix(5).joined(separator: " · "))
                            .font(LabFont.swiftUI(12.5, .medium))
                            .foregroundStyle(LabTheme.muted)
                    }
                    if let falha {
                        Label(falha, systemImage: "wifi.exclamationmark")
                            .font(LabFont.swiftUI(13, .medium))
                            .foregroundStyle(LabTheme.muted)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: Escala.larguraMaxima, alignment: .leading)

                if !temporadas.isEmpty { abasDeTemporada.padding(.top, 24) }
                listaDeEpisodios
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .frame(maxWidth: Escala.larguraMaxima, alignment: .leading)

                if let elenco = detalhes?.pessoasCom(["Actor", "GuestStar"]), !elenco.isEmpty {
                    FaixaDoElenco(servidor: servidor, elenco: Array(elenco.prefix(30))).padding(.top, 26)
                }
            }
            .padding(.bottom, 32)
        }
        .background(LabTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: volta) { await carregar() }
        .task(id: escolhida) { await carregarEpisodios() }
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

    private var titulos: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: serie?.nome ?? nome)
                .font(LabFont.swiftUI(24, .heavy))
                .foregroundStyle(LabTheme.text)
            HStack(spacing: 12) {
                if let ano = serie?.ano { Text(verbatim: String(ano)) }
                if !temporadas.isEmpty { Text(Plural.temporadas(temporadas.count)) }
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
        }
        .padding(.top, detalhes?.logoDe == nil ? 0 : 8)
    }

    private var botoes: some View {
        HStack(spacing: 10) {
            Button { if let proximo { tocar(proximo) } } label: {
                VStack(spacing: 1) {
                    Label(proximo?.posicao == nil ? String(localized: "Assistir") : String(localized: "Continuar"),
                          systemImage: "play.fill")
                        .font(LabFont.swiftUI(16, .bold))
                    if let proximo, let numero = numeroDoEpisodio(proximo) {
                        Text(verbatim: numero)
                            .font(LabFont.swiftUI(11, .semibold))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(LabTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(proximo == nil ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(proximo == nil)

            BotaoDeMarca(simbolo: "checkmark", aceso: serie?.visto == true, cor: LabTheme.accent,
                         rotulo: String(localized: "Já reproduzido")) { mudar(visto: !(serie?.visto ?? false)) }
            BotaoDeMarca(simbolo: serie?.favorito == true ? "heart.fill" : "heart", aceso: serie?.favorito == true,
                         cor: LabTheme.red, rotulo: String(localized: "Favorito")) { mudarFavorito() }
        }
    }

    private var abasDeTemporada: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(temporadas) { temporada in
                    let ativa = temporada.id == escolhida
                    Button { escolhida = temporada.id } label: {
                        Text(verbatim: temporada.nome)
                            .font(LabFont.swiftUI(13.5, .bold))
                            .foregroundStyle(ativa ? .black : LabTheme.text)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(ativa ? LabTheme.accent : LabTheme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var listaDeEpisodios: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(episodios) { episodio in
                NavigationLink {
                    DetalhesDoServidorView(servidor: servidor, inicial: episodio)
                        .onDisappear { volta += 1 }
                } label: {
                    LinhaDeEpisodio(servidor: servidor, episodio: episodio)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Ações

    /// O episódio toca com a temporada dele em volta, para o "próximo" do player.
    private func tocar(_ episodio: Item) {
        Task { @MainActor in
            let lista = (try? await servidor.temporada(episodio)) ?? [episodio]
            let itens = lista.map(servidor.paraTocar)
            let alvo = servidor.paraTocar(episodio).origin
            fila = itens
            tocando = itens.first { $0.origin == alvo } ?? servidor.paraTocar(episodio)
        }
    }

    private func mudar(visto: Bool) {
        Task { @MainActor in
            do {
                try await servidor.marcarVisto(serieID, visto)
                volta += 1
            } catch where error.foiCancelado {
                return
            } catch {
                falhaDeAcao = error.localizedDescription
            }
        }
    }

    private func mudarFavorito() {
        let favorito = !(serie?.favorito ?? false)
        Task { @MainActor in
            do {
                try await servidor.marcarFavorito(serieID, favorito)
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
        await AvisoAoServidor.emDia()
        do {
            async let lido = servidor.detalhes(serieID)
            async let listaDeTemporadas = servidor.temporadas(serieID)
            async let seguinte = try? servidor.proximoDaSerie(serieID)
            let (item, dados) = try await lido
            serie = item
            detalhes = dados
            temporadas = (try? await listaDeTemporadas) ?? []
            proximo = await seguinte
            // Abre na temporada do próximo episódio a ver; sem ele, na primeira.
            if escolhida == nil || !temporadas.contains(where: { $0.id == escolhida }) {
                escolhida = proximo?.temporadaID.flatMap { id in temporadas.first { $0.id == id }?.id }
                    ?? temporadas.first?.id
            } else {
                await carregarEpisodios()
            }
            falha = nil
        } catch where error.foiCancelado {
            return
        } catch {
            if detalhes == nil { falha = error.localizedDescription }
        }
    }

    private func carregarEpisodios() async {
        guard let escolhida else { return }
        if let lista = try? await servidor.episodios(serieID, temporada: escolhida) {
            episodios = lista
        }
    }
}

/// Um episódio na lista da série: a cena, o número e o nome, a duração e a
/// barra do quanto foi visto.
private struct LinhaDeEpisodio: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let episodio: ServidorDeMidia.Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ImagemDoServidor(servidor: servidor, id: episodio.id, tipos: ["Primary", "Thumb"], largura: 400)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 150 * escala.fator)
                .overlay(alignment: .bottom) { BarraDeProgresso(progresso: episodio.progresso) }
                .overlay(alignment: .topTrailing) {
                    if episodio.visto {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.black)
                            .frame(width: 18, height: 18)
                            .background(LabTheme.accent, in: Circle())
                            .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: episodio.titulo)
                    .font(LabFont.swiftUI(14, .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(2)
                if let duracao = episodio.duracao {
                    Text(verbatim: TimeFormat.spoken(duracao))
                        .font(LabFont.swiftUI(11.5, .medium))
                        .foregroundStyle(LabTheme.faint)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Pessoa

/// A página de um ator, diretor ou roteirista: a foto, a biografia e os
/// filmes e séries dele que estão no servidor.
struct PessoaDoServidorView: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let pessoa: ServidorDeMidia.Detalhes.Pessoa

    @State private var detalhes: ServidorDeMidia.Detalhes?
    @State private var obras: [ServidorDeMidia.Item] = []
    @State private var carregando = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    ImagemDoServidor(servidor: servidor, id: pessoa.id, tipos: ["Primary"],
                                     largura: 360, semImagem: "person.fill")
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .frame(width: 120 * escala.fator)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: pessoa.nome)
                            .font(LabFont.swiftUI(22, .heavy))
                            .foregroundStyle(LabTheme.text)
                        if let nascimento = detalhes?.estreia {
                            Text("Nascimento: \(nascimento.formatted(date: .long, time: .omitted))")
                                .font(LabFont.swiftUI(12.5, .medium))
                                .foregroundStyle(LabTheme.muted)
                        }
                        if !obras.isEmpty {
                            Text(Plural.titulos(obras.count))
                                .font(LabFont.swiftUI(12.5, .medium))
                                .foregroundStyle(LabTheme.muted)
                        }
                    }
                }
                if let biografia = detalhes?.sinopse { SinopseDoServidor(texto: biografia) }

                if carregando && obras.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if !obras.isEmpty {
                    Secao(titulo: String(localized: "No servidor"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104 * escala.fator), spacing: 12, alignment: .top)],
                              spacing: 16) {
                        ForEach(obras) { obra in
                            NavigationLink { paginaDoServidor(servidor, obra) } label: {
                                Cartaz(servidor: servidor, item: obra)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: Escala.larguraMaxima, alignment: .leading)
        }
        .background(LabTheme.background.ignoresSafeArea())
        .navigationTitle(pessoa.nome)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let lido = try? servidor.detalhes(pessoa.id)
            async let lista = try? servidor.obras(daPessoa: pessoa.id)
            detalhes = await lido?.detalhes
            obras = await lista ?? []
            carregando = false
        }
    }
}

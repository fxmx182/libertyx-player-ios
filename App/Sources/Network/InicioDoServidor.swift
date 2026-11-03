import SwiftUI

/// A primeira tela de um Jellyfin ou Emby, como no app do próprio servidor:
/// o que ficou pela metade, o próximo episódio de cada série e o que chegou
/// por último em cada biblioteca.
///
/// As pastas continuam a um toque — nas bibliotecas e no "›" de cada faixa —
/// para quem prefere procurar pelo catálogo inteiro.
struct InicioDoServidorView: View {
    let conta: ContaDeRede

    @State private var inicio: Inicio?
    @State private var falha: String?
    @State private var tocando: MediaItem?
    @State private var fila: [MediaItem] = []
    @State private var abrindo = false
    /// Conta as voltas do player: o filme que acabou de ser visto sai do
    /// "Continuar", e o episódio seguinte entra no "A seguir".
    @State private var volta = 0

    private typealias Item = ServidorDeMidia.Item

    private var servidor: ServidorDeMidia {
        ServidorDeMidia(conta: conta, token: ContasDeRede.shared.segredo(conta))
    }

    var body: some View {
        conteudo
            // A tela antiga fica enquanto a nova carrega, sem piscar.
            .task(id: volta) { await carregar() }
            .refreshable { await carregar() }
            .fullScreenCover(item: $tocando, onDismiss: { volta += 1 }) { item in
                PlayerScreen(item: item, playlist: fila).ignoresSafeArea()
            }
    }

    @ViewBuilder
    private var conteudo: some View {
        if let inicio {
            if inicio.bibliotecas.isEmpty {
                ContentUnavailableView("Nenhum vídeo nesta pasta", systemImage: "folder")
            } else {
                faixas(inicio)
            }
        } else if let falha {
            ContentUnavailableView("Não conectou", systemImage: "wifi.exclamationmark",
                                   description: Text(falha))
        } else {
            ProgressView("Lendo…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func faixas(_ inicio: Inicio) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if !inicio.continuar.isEmpty {
                    FaixaDoServidor(titulo: String(localized: "Continuar assistindo")) {
                        ForEach(inicio.continuar) { item in
                            Button { abrir(item) } label: { CartaoDeitado(servidor: servidor, item: item) }
                                .buttonStyle(.plain)
                                .menuDoVisto(servidor, item) { volta += 1 }
                        }
                    }
                }
                if !inicio.aSeguir.isEmpty {
                    FaixaDoServidor(titulo: String(localized: "A seguir")) {
                        ForEach(inicio.aSeguir) { item in
                            Button { abrir(item) } label: { CartaoDeitado(servidor: servidor, item: item) }
                                .buttonStyle(.plain)
                                .menuDoVisto(servidor, item) { volta += 1 }
                        }
                    }
                }
                FaixaDoServidor(titulo: String(localized: "Bibliotecas")) {
                    ForEach(inicio.bibliotecas) { biblioteca in
                        NavigationLink { pasta(biblioteca) } label: {
                            CartaoDeBiblioteca(servidor: servidor, biblioteca: biblioteca)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(inicio.recentes) { faixa in
                    FaixaDoServidor(titulo: String(localized: "Recentes em \(faixa.biblioteca.nome)"),
                          destino: AnyView(pasta(faixa.biblioteca))) {
                        ForEach(faixa.itens) { item in
                            Group {
                                if item.ehVideo {
                                    Button { abrir(item) } label: { Cartaz(servidor: servidor, item: item) }
                                        .buttonStyle(.plain)
                                } else {
                                    NavigationLink { pasta(item) } label: { Cartaz(servidor: servidor, item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .menuDoVisto(servidor, item) { volta += 1 }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .fundoDaRede()
    }

    private func pasta(_ item: Item) -> some View {
        PastaRemotaView(titulo: item.titulo, destino: .midia(conta, item))
    }

    // MARK: - Tocar

    private func abrir(_ item: Item) {
        guard !abrindo else { return }
        abrindo = true
        Task {
            // Episódio toca com a temporada em volta, para o "próximo" do
            // player ir ao episódio seguinte, e não ao vizinho da faixa.
            var lista = [item]
            if item.tipo == "Episode",
               let temporada = try? await servidor.temporada(item),
               temporada.contains(where: { $0.id == item.id }) {
                lista = temporada
            }
            abrindo = false
            let itens = lista.map(servidor.paraTocar)
            fila = itens
            tocando = itens.first { $0.origin == servidor.paraTocar(item).origin }
        }
    }

    // MARK: - Leitura

    private struct Inicio {
        let continuar: [Item]
        let aSeguir: [Item]
        let bibliotecas: [Item]
        let recentes: [Recentes]
    }

    private struct Recentes: Identifiable {
        let biblioteca: Item
        let itens: [Item]
        var id: String { biblioteca.id }
    }

    /// Tudo junto, em paralelo. Só as bibliotecas derrubam a tela quando
    /// falham — é o pedido que diz se o servidor está lá e aceitou a conta.
    /// Uma faixa que falha sozinha só não aparece.
    private func carregar() async {
        // Quem acabou de fechar o player chega aqui antes de o "parou" chegar
        // ao servidor; sem esperar, o filme que terminou voltaria ao "Continuar".
        await AvisoAoServidor.emDia()
        let servidor = servidor
        do {
            async let continuar = (try? await servidor.continuar()) ?? []
            async let aSeguir = (try? await servidor.aSeguir()) ?? []
            let bibliotecas = try await servidor.bibliotecas()
            // Coleções só repetem filmes que já aparecem na biblioteca deles.
            let comRecentes = bibliotecas.filter { $0.tipoDeColecao != "boxsets" }
            let recentes = await withTaskGroup(of: (Int, [Item]).self) { grupo in
                for (indice, biblioteca) in comRecentes.enumerated() {
                    grupo.addTask { (indice, (try? await servidor.recentes(biblioteca)) ?? []) }
                }
                var porIndice: [Int: [Item]] = [:]
                for await (indice, itens) in grupo { porIndice[indice] = itens }
                return porIndice
            }
            let comecados = await continuar
            let comecadosIDs = Set(comecados.map(\.id))
            inicio = Inicio(
                continuar: comecados,
                // O servidor põe no "A seguir" o episódio que já está no "Continuar".
                aSeguir: await aSeguir.filter { !comecadosIDs.contains($0.id) },
                bibliotecas: bibliotecas,
                recentes: comRecentes.enumerated().compactMap { indice, biblioteca in
                    guard let itens = recentes[indice], !itens.isEmpty else { return nil }
                    return Recentes(biblioteca: biblioteca, itens: itens)
                })
            falha = nil
        } catch where error.foiCancelado {
            return
        } catch {
            if inicio == nil { falha = error.localizedDescription }
        }
    }
}

// MARK: - Peças

/// Um título e, abaixo, a fila de capas que rola de lado.
private struct FaixaDoServidor<Conteudo: View>: View {
    let titulo: String
    var destino: AnyView? = nil
    @ViewBuilder let conteudo: () -> Conteudo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let destino {
                    NavigationLink { destino } label: {
                        HStack(spacing: 2) {
                            Secao(titulo: titulo).fixedSize()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LabTheme.muted)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Secao(titulo: titulo)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { conteudo() }
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// "Continuar" e "A seguir": a cena deitada, com o quanto falta.
private struct CartaoDeitado: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let item: ServidorDeMidia.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // O "Primary" do episódio já é uma cena; o do filme é o cartaz em pé.
            ImagemDoServidor(servidor: servidor, id: item.id,
                             tipos: item.tipo == "Episode" ? ["Primary", "Thumb"] : ["Thumb", "Backdrop", "Primary"],
                             largura: 480)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) { BarraDeProgresso(progresso: item.progresso) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))

            Text(item.serie ?? item.nome)
                .font(LabFont.swiftUI(13, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .padding(.top, 8)
            Text(detalhe)
                .font(LabFont.swiftUI(11, .medium))
                .foregroundStyle(LabTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 236 * escala.fator)
        .contentShape(Rectangle())
    }

    private var detalhe: String {
        if item.tipo == "Episode" {
            return [numeroDoEpisodio(item), item.nome].compactMap { $0 }.joined(separator: " · ")
        }
        if let posicao = item.posicao, let duracao = item.duracao, duracao > posicao {
            return String(localized: "faltam \(TimeFormat.spoken(duracao - posicao))")
        }
        return item.ano.map(String.init) ?? ""
    }
}

private func numeroDoEpisodio(_ item: ServidorDeMidia.Item) -> String? {
    guard let temporada = item.temporada, let numero = item.numero else { return nil }
    return String(localized: "T\(temporada):E\(numero)")
}

/// "Recentes": o cartaz em pé, com os episódios por ver ou a marca de visto.
private struct Cartaz: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let item: ServidorDeMidia.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Episódio solto mostra o cartaz da série: a cena dele, cortada em
            // pé, não diria de onde ele é.
            ImagemDoServidor(servidor: servidor,
                             id: item.tipo == "Episode" ? (item.serieID ?? item.id) : item.id,
                             tipos: ["Primary"], largura: 300, semImagem: "tv")
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .topTrailing) { marca.padding(6) }
                .overlay(alignment: .bottom) { BarraDeProgresso(progresso: item.progresso) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))

            Text(item.tipo == "Episode" ? (item.serie ?? item.nome) : item.nome)
                .font(LabFont.swiftUI(12, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .padding(.top, 6)
            if let ano = item.ano {
                Text(verbatim: String(ano))
                    .font(LabFont.swiftUI(11, .medium))
                    .foregroundStyle(LabTheme.faint)
            }
        }
        .frame(width: 112 * escala.fator)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var marca: some View {
        if let naoVistos = item.naoVistos {
            Text(verbatim: "\(naoVistos)")
                .font(LabFont.swiftUI(11, .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(LabTheme.accent, in: Capsule())
        } else if item.visto {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(LabTheme.accent, in: Circle())
        }
    }
}

private struct CartaoDeBiblioteca: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let biblioteca: ServidorDeMidia.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ImagemDoServidor(servidor: servidor, id: biblioteca.id, tipos: ["Primary"], largura: 400)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
            Text(biblioteca.nome)
                .font(LabFont.swiftUI(12, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .padding(.top, 6)
        }
        .frame(width: 176 * escala.fator)
        .contentShape(Rectangle())
    }
}

// MARK: - Já reproduzido

/// Segurar um vídeo, uma série ou uma temporada do Jellyfin ou do Emby: a
/// caixinha "Já reproduzido", de marcar e desmarcar, como no app do servidor.
/// Numa série vale para todos os episódios. Quem chama relê a tela em
/// `aoMudar`: o item marcado sai do "Continuar", o desmarcado volta a não visto.
private struct MenuDoVisto: ViewModifier {
    let servidor: ServidorDeMidia
    let item: ServidorDeMidia.Item
    let aoMudar: () -> Void

    @State private var falha: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Toggle(isOn: Binding(get: { item.visto }, set: mudar)) {
                    Label("Já reproduzido", systemImage: "checkmark.circle")
                }
            }
            .alert("Não conectou", isPresented: Binding(get: { falha != nil }, set: { if !$0 { falha = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(falha ?? "")
            }
    }

    private func mudar(_ visto: Bool) {
        Task { @MainActor in
            do {
                try await servidor.marcarVisto(item.id, visto)
                // O servidor zera onde parou nos dois sentidos; a marca daqui
                // segue, ou o cartão voltaria com a barrinha.
                ResumeStore.shared.clear(key: MediaOrigin.midia(conta: servidor.conta.id, item: item.id).resumeKey)
                aoMudar()
            } catch where error.foiCancelado {
                return
            } catch {
                falha = error.localizedDescription
            }
        }
    }
}

extension View {
    func menuDoVisto(_ servidor: ServidorDeMidia, _ item: ServidorDeMidia.Item,
                     aoMudar: @escaping () -> Void) -> some View {
        modifier(MenuDoVisto(servidor: servidor, item: item, aoMudar: aoMudar))
    }
}

// MARK: - Capas das pastas

/// Série, temporada ou coleção dentro de uma biblioteca: a capa deitada, como
/// no app do servidor e no do computador. Antes era uma linha com um ícone de
/// pasta, e uma biblioteca de séries virava uma lista de nomes sem rosto.
///
/// O selo diz quantos episódios faltam ver; o visto, quando não falta nenhum.
struct CapaDePastaDoServidor: View {
    let servidor: ServidorDeMidia
    let item: ServidorDeMidia.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ImagemDoServidor(servidor: servidor, id: idDaCapa(item), tipos: ["Thumb", "Backdrop", "Primary"],
                             largura: 480, semImagem: simboloDaCapa(item))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { SeloDeVistos(item: item).padding(7) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
            Text(item.nome)
                .font(LabFont.swiftUI(13, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .padding(.top, 7)
            Text(verbatim: item.ano.map(String.init) ?? " ")
                .font(LabFont.swiftUI(11, .medium))
                .foregroundStyle(LabTheme.faint)
        }
        .contentShape(Rectangle())
    }
}

/// A mesma capa, pequena, na linha da lista — para quem prefere a pasta em lista.
struct LinhaDePastaDoServidor: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let item: ServidorDeMidia.Item

    var body: some View {
        HStack(spacing: 14) {
            ImagemDoServidor(servidor: servidor, id: idDaCapa(item), tipos: ["Thumb", "Backdrop", "Primary"],
                             largura: 320, semImagem: simboloDaCapa(item))
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 124 * escala.fator)
                .overlay(alignment: .bottomTrailing) { SeloDeVistos(item: item).padding(5) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.nome)
                    .font(LabFont.swiftUI(14, .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(2)
                if let ano = item.ano {
                    Text(verbatim: String(ano))
                        .font(LabFont.swiftUI(11, .medium))
                        .foregroundStyle(LabTheme.faint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A temporada quase nunca tem cena deitada própria, só o cartaz em pé — que
/// cortado em 16:9 vira um retalho. A da série serve a todas as temporadas.
private func idDaCapa(_ item: ServidorDeMidia.Item) -> String {
    item.tipo == "Season" ? (item.serieID ?? item.id) : item.id
}

private func simboloDaCapa(_ item: ServidorDeMidia.Item) -> String {
    item.tipo == "Series" || item.tipo == "Season" ? "tv" : "film"
}

private struct SeloDeVistos: View {
    let item: ServidorDeMidia.Item

    var body: some View {
        if let naoVistos = item.naoVistos {
            Text(verbatim: "\(naoVistos)")
                .font(LabFont.swiftUI(11, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.black.opacity(0.72), in: Capsule())
        } else if item.visto {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(LabTheme.accent, in: Circle())
        }
    }
}

// MARK: - Imagens

/// Cartazes e cenas que o servidor já tem prontos — diferente das miniaturas
/// das pastas, aqui não há quadro a tirar do vídeo, só a imagem a baixar.
@MainActor
private enum CapasDoServidor {
    static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()
    static var falharam: Set<String> = []

    static func guardar(_ imagem: UIImage, _ chave: String) {
        let custo = Int(imagem.size.width * imagem.size.height * imagem.scale * imagem.scale * 4)
        cache.setObject(imagem, forKey: chave as NSString, cost: custo)
    }
}

struct ImagemDoServidor: View {
    let servidor: ServidorDeMidia
    let id: String
    let tipos: [String]
    let largura: Int
    var semImagem = "film"

    @State private var imagem: UIImage?

    private var chave: String { "\(servidor.conta.id.uuidString)/\(id)/\(tipos.joined(separator: ","))" }

    var body: some View {
        // A cor ocupa o espaço que a proporção do pai define; a imagem só
        // preenche por cima, sem mudar o tamanho do cartão.
        LinearGradient(colors: [Color(red: 0.137, green: 0.133, blue: 0.157),
                                Color(red: 0.086, green: 0.086, blue: 0.102)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if let imagem {
                    Image(uiImage: imagem).resizable().scaledToFill()
                } else {
                    Image(systemName: semImagem)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(LabTheme.faint)
                }
            }
            .clipped()
            .task(id: chave) { await carregar() }
    }

    private func carregar() async {
        let chave = chave
        if let pronta = CapasDoServidor.cache.object(forKey: chave as NSString) {
            imagem = pronta
            return
        }
        guard !CapasDoServidor.falharam.contains(chave) else { return }
        if let baixada = await servidor.imagem(id, tipos: tipos, largura: largura) {
            CapasDoServidor.guardar(baixada, chave)
            imagem = baixada
        } else {
            CapasDoServidor.falharam.insert(chave)
        }
    }
}

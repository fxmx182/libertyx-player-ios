import SwiftUI

/// A raiz do app: quatro abas na dock de baixo.
///
/// A dock é a barra de abas do próprio iOS — no iOS 26 ela já é a pílula de
/// vidro flutuante, a mesma do Infuse, e herda de graça a área segura, o
/// VoiceOver e o toque duplo que volta ao topo. Desenhar uma à mão seria
/// refazer tudo isso para chegar no mesmo lugar.
///
/// Uma diferença do padrão do iOS, de propósito, para ser igual ao Android:
/// cada aba abre sempre do começo. O iOS guarda a última tela de cada aba, e
/// tocar em Início trazia de volta a pasta do Jellyfin deixada aberta. Quem
/// troca de aba esquece a pilha da aba que deixou — recriada enquanto não
/// aparece, então ninguém vê o salto.
struct Abas: View {
    enum Aba: Hashable { case inicio, arquivos, procurar, ajustes }

    @State private var aba: Aba = .inicio
    /// Muda o `id` da aba, e a pilha dela nasce de novo na raiz.
    @State private var geracao: [Aba: Int] = [:]

    var body: some View {
        TabView(selection: Binding(get: { aba }, set: { nova in
            if nova != aba { geracao[aba, default: 0] += 1 }
            aba = nova
        })) {
            LibraryView()
                .id(geracao[.inicio, default: 0])
                .tabItem { Label("Início", systemImage: "play") }
                .tag(Aba.inicio)
            ArquivosView()
                .id(geracao[.arquivos, default: 0])
                .tabItem { Label("Arquivos", systemImage: "folder") }
                .tag(Aba.arquivos)
            ProcurarView()
                .id(geracao[.procurar, default: 0])
                .tabItem { Label("Procurar", systemImage: "magnifyingglass") }
                .tag(Aba.procurar)
            AjustesView()
                .id(geracao[.ajustes, default: 0])
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
                .tag(Aba.ajustes)
        }
    }
}

// MARK: - Arquivos

/// A aba Arquivos: navegar por pasta, como num gerenciador de arquivos.
///
/// O Início mostra as pastas como capas, para escolher pelo que se vê. Aqui é
/// o caminho de quem sabe onde o vídeo está: uma lista enxuta das pastas do
/// aparelho e, abaixo, cada servidor salvo.
struct ArquivosView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var servidoresSMB: SMBServerStore
    @ObservedObject private var contas = ContasDeRede.shared
    @ObservedObject private var library = MediaLibrary.shared
    @State private var gerenciandoPastas = false
    @State private var tocando: MediaItem?
    @State private var fila: [MediaItem] = []
    @State private var detalhes: MediaItem?
    @State private var volta = 0

    var body: some View {
        NavigationStack {
            ZStack {
                FundoDeCapa(capa: nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        CabecalhoDaAba()
                        TituloDeTela(titulo: String(localized: "Arquivos"),
                                     subtitulo: Plural.pastas(library.groups.count))
                            .padding(.bottom, 8)

                        Secao(titulo: String(localized: "Neste aparelho"),
                              extra: library.groups.isEmpty ? nil : "\(library.groups.count)")
                        ForEach(library.groups) { grupo in
                            NavigationLink(value: grupo) {
                                LinhaDeLugar(simbolo: "folder.fill", titulo: grupo.name,
                                             subtitulo: Plural.videos(grupo.items.count))
                            }
                            .buttonStyle(.plain)
                        }
                        Button { gerenciandoPastas = true } label: {
                            LinhaDeLugar(simbolo: "folder.badge.plus", titulo: String(localized: "Pastas…"),
                                         subtitulo: String(localized: "Conectar e desconectar pastas"))
                        }
                        .buttonStyle(.plain)

                        Secao(titulo: String(localized: "Servidores"),
                              extra: totalDeServidores == 0 ? nil : "\(totalDeServidores)")
                            .padding(.top, 14)
                        ForEach(servidoresSMB.servers) { servidor in
                            NavigationLink { SMBShareListView(server: servidor) } label: {
                                LinhaDeLugar(simbolo: "server.rack", titulo: servidor.name, subtitulo: "SMB")
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(contas.contas) { conta in
                            NavigationLink { PastaRemotaView(titulo: conta.nome, destino: .inicio(conta)) } label: {
                                LinhaDeLugar(simbolo: conta.tipo.simbolo, titulo: conta.nome, subtitulo: conta.tipo.nome)
                            }
                            .buttonStyle(.plain)
                        }
                        // Cadastrar mora nos Ajustes; aqui fica só o atalho,
                        // para a lista vazia não ser um beco sem saída.
                        NavigationLink { SMBServersView(grupo: .servidores) } label: {
                            LinhaDeLugar(simbolo: "plus", titulo: String(localized: "Adicionar servidor"),
                                         subtitulo: String(localized: "SMB, WebDAV, Jellyfin e Emby"), seta: false)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .refreshable { await library.refresh(bookmarks: bookmarks) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: VideoGroup.self) { grupo in
                PastaView(grupo: grupo, volta: volta,
                          onTocar: { item, lista in fila = lista; tocando = item },
                          menu: { item in
                              Button { detalhes = item } label: {
                                  Label("Detalhes do arquivo", systemImage: "info.circle")
                              }
                          })
            }
            .task { if library.lastScan == nil { await library.refresh(bookmarks: bookmarks) } }
            .sheet(isPresented: $gerenciandoPastas, onDismiss: {
                Task { await library.refresh(bookmarks: bookmarks) }
            }) {
                ManageFoldersView()
            }
            .sheet(item: $detalhes) { MediaInfoView(item: $0) }
            .fullScreenCover(item: $tocando, onDismiss: { volta += 1 }) { item in
                PlayerScreen(item: item, playlist: fila).ignoresSafeArea()
            }
        }
    }

    private var totalDeServidores: Int { servidoresSMB.servers.count + contas.contas.count }
}

// MARK: - Procurar

/// A aba Procurar: pelo nome, nos vídeos do aparelho e nos Jellyfin e Emby.
///
/// SMB e WebDAV ficam de fora: não têm busca, e procurar neles seria descer
/// pasta por pasta do servidor inteiro a cada letra digitada.
struct ProcurarView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @ObservedObject private var library = MediaLibrary.shared
    @ObservedObject private var contas = ContasDeRede.shared
    @State private var termo = ""
    @State private var remotos: [Achados] = []
    @State private var buscando = false
    @State private var tocando: MediaItem?
    @State private var fila: [MediaItem] = []
    @FocusState private var digitando: Bool

    /// O que um servidor achou.
    private struct Achados: Identifiable {
        let conta: ContaDeRede
        let itens: [MediaItem]
        var id: UUID { conta.id }
    }

    private var limpo: String { termo.trimmingCharacters(in: .whitespaces) }

    private var locais: [MediaItem] {
        guard !limpo.isEmpty else { return [] }
        // "Ação" acha "acao": ninguém digita acento para procurar.
        let opcoes: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return Array(library.groups.flatMap(\.items)
            .filter { $0.title.range(of: limpo, options: opcoes) != nil }
            .prefix(100))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FundoDeCapa(capa: nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        CabecalhoDaAba()
                        TituloDeTela(titulo: String(localized: "Procurar"),
                                     subtitulo: String(localized: "Vídeos do aparelho e dos servidores Jellyfin e Emby"))
                        campo.padding(.vertical, 12)

                        let achadosAqui = locais
                        if !achadosAqui.isEmpty {
                            Secao(titulo: String(localized: "Neste aparelho"), extra: "\(achadosAqui.count)")
                            lista(achadosAqui)
                        }
                        ForEach(remotos) { grupo in
                            Secao(titulo: grupo.conta.nome, extra: "\(grupo.itens.count)").padding(.top, 10)
                            lista(grupo.itens)
                        }

                        if buscando {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(LabTheme.accent)
                                Text("Procurando nos servidores…")
                                    .font(LabFont.swiftUI(13, .medium))
                                    .foregroundStyle(LabTheme.muted)
                            }
                            .padding(.top, 8)
                        } else if !limpo.isEmpty && achadosAqui.isEmpty && remotos.isEmpty {
                            Text("Nada encontrado para “\(limpo)”.")
                                .font(LabFont.swiftUI(14, .medium))
                                .foregroundStyle(LabTheme.muted)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { if library.lastScan == nil { await library.refresh(bookmarks: bookmarks) } }
            .task(id: limpo) { await buscarNosServidores(limpo) }
            .fullScreenCover(item: $tocando) { item in
                PlayerScreen(item: item, playlist: fila).ignoresSafeArea()
            }
        }
    }

    private var campo: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LabTheme.muted)
            TextField("Filme, episódio, nome do arquivo…", text: $termo)
                .font(LabFont.swiftUI(16, .medium))
                .foregroundStyle(LabTheme.text)
                .focused($digitando)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !termo.isEmpty {
                Button { termo = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(LabTheme.muted)
                }
                .accessibilityLabel("Limpar")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(LabTheme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
    }

    private func lista(_ itens: [MediaItem]) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(itens) { item in
                Button { fila = itens; tocando = item } label: { VideoRow(item: item) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func buscarNosServidores(_ termo: String) async {
        remotos = []
        guard termo.count >= 2 else { buscando = false; return }
        // Espera a pessoa parar de digitar: uma consulta por letra só ocuparia
        // o servidor com buscas que ninguém vai ler. Uma letra nova cancela
        // esta tarefa ainda no sono.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        let alvos = contas.contas.filter { $0.tipo != .webdav }
        guard !alvos.isEmpty else { return }
        buscando = true
        var achados: [Achados] = []
        for conta in alvos {
            let servidor = ServidorDeMidia(conta: conta, token: ContasDeRede.shared.segredo(conta))
            guard let itens = try? await servidor.buscar(termo), !itens.isEmpty else { continue }
            achados.append(Achados(conta: conta, itens: itens.map { item in
                // Episódio solto não diz nada sem a série na frente.
                MediaItem(title: item.serie.map { "\($0) · \(item.titulo)" } ?? item.titulo,
                          origin: .midia(conta: conta.id, item: item.id),
                          modifiedAt: item.dataDeCriacao, duration: item.duracao)
            }))
        }
        guard !Task.isCancelled else { return }
        remotos = achados
        buscando = false
    }
}

// MARK: - Ajustes

/// A aba Ajustes: tudo o que ficava espalhado em botões no alto da tela,
/// numa lista só, no espírito da do Infuse.
struct AjustesView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @ObservedObject private var options = LibraryOptions.shared
    @Environment(\.openURL) private var abrir
    @State private var gerenciandoPastas = false
    @State private var visualizacao = false
    @State private var reproducao = false
    @State private var xEmBreve = false

    private static let site = URL(string: "https://fxmx182.github.io")!
    private static let email = "libertyx.suporte@gmail.com"

    var body: some View {
        NavigationStack {
            ZStack {
                FundoDeCapa(capa: nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        CabecalhoDaAba()
                        TituloDeTela(titulo: String(localized: "Ajustes"),
                                     subtitulo: "LibertyX Player \(AppBuild.version)")
                            .padding(.bottom, 8)

                        grupo(String(localized: "Biblioteca")) {
                            NavigationLink { SMBServersView(grupo: .servidores) } label: {
                                LinhaDeAjuste(simbolo: "server.rack", titulo: String(localized: "Servidores"),
                                              sub: String(localized: "SMB, Jellyfin e Emby"))
                            }
                            divisoria
                            NavigationLink { SMBServersView(grupo: .webdav) } label: {
                                LinhaDeAjuste(simbolo: "cloud", titulo: String(localized: "WebDAV / Nextcloud"),
                                              sub: String(localized: "Nextcloud, ownCloud e outros"))
                            }
                            divisoria
                            Button { gerenciandoPastas = true } label: {
                                LinhaDeAjuste(simbolo: "folder", titulo: String(localized: "Pastas do aparelho"),
                                              sub: Plural.pastas(bookmarks.folders.count))
                            }
                        }

                        grupo(String(localized: "Preferências")) {
                            Button { visualizacao = true } label: {
                                LinhaDeAjuste(simbolo: "slider.horizontal.3", titulo: String(localized: "Visualização"),
                                              sub: String(localized: "Grade ou lista, e a ordem"))
                            }
                            divisoria
                            Button { reproducao = true } label: {
                                LinhaDeAjuste(simbolo: "play.circle", titulo: String(localized: "Reprodução"),
                                              sub: String(localized: "Controles e velocidade"))
                            }
                        }

                        grupo("LibertyX") {
                            Button { Guia.mostrarDeNovo() } label: {
                                LinhaDeAjuste(simbolo: "hand.tap", titulo: String(localized: "Ver o guia dos gestos e ferramentas"))
                            }
                            divisoria
                            NavigationLink { LicencasView() } label: {
                                LinhaDeAjuste(simbolo: "doc.text", titulo: String(localized: "Licenças de código aberto"))
                            }
                        }

                        grupo(String(localized: "Fale com a gente")) {
                            ShareLink(item: Self.site,
                                      message: Text("O LibertyX Player toca qualquer vídeo, do celular ou direto do servidor de casa.")) {
                                LinhaDeAjuste(simbolo: "square.and.arrow.up", titulo: String(localized: "Compartilhar o LibertyX"),
                                              externo: true)
                            }
                            divisoria
                            Button { xEmBreve = true } label: {
                                LinhaDeAjuste(imagem: "LogoX", titulo: String(localized: "Seguir no X"),
                                              valor: String(localized: "Em breve"), externo: true)
                            }
                            divisoria
                            Button { escreverEmail() } label: {
                                LinhaDeAjuste(simbolo: "envelope", titulo: String(localized: "Enviar um email"),
                                              sub: Self.email, externo: true)
                            }
                        }

                        // Qual build está instalado, à mão: "a mudança não
                        // funcionou" e "instalei o .ipa antigo" são a mesma
                        // tela sem isto.
                        Text(verbatim: "LibertyX Player \(AppBuild.version) · \(AppBuild.commit)")
                            .font(LabFont.swiftUI(11, .medium))
                            .foregroundStyle(LabTheme.faint)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                    .frame(maxWidth: Escala.larguraMaxima)
                    .frame(maxWidth: .infinity)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $gerenciandoPastas, onDismiss: {
                Task { await MediaLibrary.shared.refresh(bookmarks: bookmarks) }
            }) {
                ManageFoldersView()
            }
            .sheet(isPresented: $visualizacao) { LibraryOptionsSheet(options: options) }
            .sheet(isPresented: $reproducao) { OpcoesDeReproducao() }
            .alert("Seguir no X", isPresented: $xEmBreve) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nosso perfil no X chega em breve.")
            }
        }
    }

    /// Um bloco de linhas com o título em cima, como os grupos dos Ajustes do iPhone.
    private func grupo<Conteudo: View>(_ titulo: String,
                                       @ViewBuilder linhas: () -> Conteudo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Secao(titulo: titulo)
            VStack(spacing: 0) { linhas() }
                .buttonStyle(.plain)
                .labCard()
                .clipShape(RoundedRectangle(cornerRadius: LabTheme.radiusCard, style: .continuous))
        }
        .padding(.bottom, 12)
    }

    private var divisoria: some View {
        Rectangle().fill(LabTheme.glassBorder).frame(height: 0.5).padding(.leading, 58)
    }

    private func escreverEmail() {
        var partes = URLComponents()
        partes.scheme = "mailto"
        partes.path = Self.email
        partes.queryItems = [URLQueryItem(name: "subject", value: "LibertyX Player \(AppBuild.version) (iPhone)")]
        if let url = partes.url { abrir(url) }
    }
}

/// Uma linha dos Ajustes: o ícone na cor da marca, o nome, e a seta — ou a
/// setinha para fora, quando a linha leva para fora do app.
private struct LinhaDeAjuste: View {
    var simbolo: String? = nil
    var imagem: String? = nil
    let titulo: String
    var sub: String? = nil
    var valor: String? = nil
    var externo = false

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let imagem {
                    Image(imagem).renderingMode(.template).resizable().scaledToFit().frame(width: 19, height: 19)
                } else if let simbolo {
                    Image(systemName: simbolo).font(.system(size: 20, weight: .regular))
                }
            }
            .foregroundStyle(LabTheme.accent)
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo)
                    .font(LabFont.swiftUI(16, .medium))
                    .foregroundStyle(LabTheme.text)
                    .multilineTextAlignment(.leading)
                if let sub {
                    Text(sub)
                        .font(LabFont.swiftUI(12, .medium))
                        .foregroundStyle(LabTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let valor {
                Text(valor)
                    .font(LabFont.swiftUI(13, .medium))
                    .foregroundStyle(LabTheme.muted)
            }
            Image(systemName: externo ? "arrow.up.right.square" : "chevron.right")
                .font(.system(size: externo ? 15 : 13, weight: .semibold))
                .foregroundStyle(LabTheme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// As preferências do player, que antes só se mudavam com um vídeo aberto.
private struct OpcoesDeReproducao: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ocultar = PlayerPreferences.autoHide
    @State private var velocidade = PlayerPreferences.holdSpeed

    private let colunas = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ocultar controles depois").font(.headline)
                        LazyVGrid(columns: colunas, spacing: 10) {
                            ForEach(PlayerPreferences.AutoHide.allCases, id: \.self) { opcao in
                                pilula(opcao.title, ativa: ocultar == opcao) {
                                    ocultar = opcao
                                    PlayerPreferences.autoHide = opcao
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Segurar para acelerar").font(.headline)
                        HStack(spacing: 8) {
                            ForEach(PlayerPreferences.holdSpeedOptions, id: \.self) { opcao in
                                pilula(Self.velocidadeEmTexto(opcao), ativa: velocidade == opcao) {
                                    velocidade = opcao
                                    PlayerPreferences.holdSpeed = opcao
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Reprodução")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Concluído") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pilula(_ titulo: String, ativa: Bool, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Text(titulo)
                .font(.callout.weight(ativa ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(ativa ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(ativa ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private static func velocidadeEmTexto(_ valor: Float) -> String {
        valor.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(valor))×"
            : String(format: "%.1f×", valor)
    }
}

// MARK: - Peças das abas

/// O alto de cada aba: só a marca, alinhada como no Início.
private struct CabecalhoDaAba: View {
    var body: some View {
        HStack { MarcaDoApp(); Spacer() }.frame(height: 52)
    }
}

/// Uma pasta ou um servidor: o ícone numa caixinha, o nome e o que tem lá.
private struct LinhaDeLugar: View {
    let simbolo: String
    let titulo: String
    var subtitulo: String? = nil
    var seta = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: simbolo)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LabTheme.accent)
                .frame(width: 40, height: 40)
                .background(LabTheme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo)
                    .font(LabFont.swiftUI(15, .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                if let subtitulo {
                    Text(subtitulo)
                        .font(LabFont.swiftUI(12, .medium))
                        .foregroundStyle(LabTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if seta {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LabTheme.faint)
            }
        }
        .padding(10)
        .labCard()
        .contentShape(Rectangle())
    }
}

import UniformTypeIdentifiers
import SwiftUI

/// Tela inicial: todos os vídeos que o app encontra, agrupados por pasta.
///
/// A varredura é automática. O usuário autoriza uma pasta uma vez — pendrive,
/// iCloud, o que for — e a partir daí não precisa navegar pasta por pasta a
/// cada vez que abre o app.
struct LibraryView: View {

    @EnvironmentObject private var bookmarks: BookmarkStore
    @StateObject private var library = MediaLibrary()
    @ObservedObject private var options = LibraryOptions.shared
    @State private var showingOptions = false

    @State private var showingFolderPicker = false
    @State private var showingFilePicker = false
    @State private var managingFolders = false
    @State private var playing: MediaItem?
    @State private var playlist: [MediaItem] = []
    @State private var showingInfo: MediaItem?
    @State private var errorMessage: String?
    @State private var pendingDeletion: MediaItem?
    /// Conta as voltas do player. A marca de onde parou muda enquanto o filme
    /// toca; sem reler ao voltar, "continuar" mostraria o ponto de antes.
    @State private var volta = 0

    var body: some View {
        NavigationStack {
            raiz
                .navigationDestination(for: VideoGroup.self) { grupo in
                    PastaView(grupo: grupo, volta: volta,
                              onTocar: tocar, menu: menuDoItem)
                }
                .toolbar(.hidden, for: .navigationBar)
            // Apagar arquivo não tem desfazer no iOS — a confirmação é a
            // única chance de voltar atrás.
            .alert("Excluir vídeo?", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { item in
                Button("Excluir", role: .destructive) { excluir(item) }
                Button("Cancelar", role: .cancel) {}
            } message: { item in
                Text("“\(item.title)” será apagado do aparelho. Não dá para desfazer.")
            }
            .task { await library.refresh(bookmarks: bookmarks) }
            .sheet(isPresented: $showingFolderPicker) {
                DocumentPicker(mode: .folder) { urls in
                    guard let url = urls.first else { return }
                    do {
                        try bookmarks.add(url: url)
                        Task { await library.refresh(bookmarks: bookmarks) }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingFilePicker) {
                DocumentPicker(mode: .videos) { urls in
                    guard let url = urls.first else { return }
                    playlist = []
                    playing = MediaItem(title: url.lastPathComponent,
                                        origin: .file(url: url, bookmark: nil))
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingOptions) {
                LibraryOptionsSheet(options: options)
            }
            .sheet(isPresented: $managingFolders, onDismiss: {
                // Tirar a autorização de uma pasta tem que sumir com os vídeos
                // dela da lista na hora — senão ficam ali, sem abrir.
                Task { await library.refresh(bookmarks: bookmarks) }
            }) {
                ManageFoldersView()
            }
            .sheet(item: $showingInfo) { item in
                MediaInfoView(item: item)
            }
            .fullScreenCover(item: $playing, onDismiss: { volta += 1 }) { item in
                PlayerScreen(item: item, playlist: playlist).ignoresSafeArea()
            }
            .alert("Ops", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - A estante

    /// O que se estava vendo por último, para o fundo e para a faixa de cima.
    ///
    /// Casado pela chave de retomada, e não pelo identificador: cada varredura
    /// cria itens novos, e a marca de onde parou precisa sobreviver a ela.
    private var continuar: [MediaItem] {
        _ = volta
        let porChave = Dictionary(library.groups.flatMap(\.items).map { ($0.origin.resumeKey, $0) },
                                  uniquingKeysWith: { a, _ in a })
        return ResumeStore.shared.recent().compactMap { porChave[$0] }.prefix(12).map { $0 }
    }

    /// Navega como uma estante, e não como uma árvore: a primeira tela mostra o
    /// que você estava vendo e as pastas como capas; tocar numa pasta entra
    /// nela. A versão anterior abria e fechava as pastas ali mesmo, numa lista
    /// só — com três pastas é prático, com trinta vira uma parede de títulos em
    /// caixa alta onde nada se destaca.
    @ViewBuilder
    private var raiz: some View {
        let pastaUnica = library.groups.count == 1 ? library.groups.first : nil
        let continuando = continuar

        ZStack(alignment: .bottom) {
            FundoDeCapa(capa: continuando.first ?? library.groups.first.flatMap(capaDa))

            if library.groups.isEmpty {
                if library.isScanning { Color.clear } else { vazio }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        barraDoTopo
                        if let pastaUnica {
                            // Uma pasta só não vira estante de uma capa: os
                            // vídeos dela já são a biblioteca, e entrar nela
                            // seria um toque a mais para nada.
                            TituloDeTela(titulo: String(localized: "Biblioteca"), subtitulo: resumoDa(pastaUnica))
                            faixaDeContinuar(continuando)
                            if !continuando.isEmpty { Secao(titulo: pastaUnica.name) }
                            ListaDeVideos(itens: options.sorted(pastaUnica.items), layout: options.layout,
                                          onTocar: tocar, menu: menuDoItem)
                        } else {
                            let total = library.groups.reduce(0) { $0 + $1.items.count }
                            TituloDeTela(titulo: String(localized: "Biblioteca"),
                                         subtitulo: Plural.videos(total) + "  ·  " + Plural.pastas(library.groups.count))
                            faixaDeContinuar(continuando)
                            Secao(titulo: String(localized: "Pastas"), extra: "\(library.groups.count)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                                ForEach(library.groups) { grupo in
                                    NavigationLink(value: grupo) { CapaDePasta(grupo: grupo) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 72)
                }
                .refreshable { await library.refresh(bookmarks: bookmarks) }
            }

            if library.isScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(LabTheme.accent)
                    Text("Procurando vídeos…")
                        .font(LabFont.swiftUI(12, .medium))
                        .foregroundStyle(LabTheme.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color(white: 0.09).opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
                .padding(.bottom, 18)
            }
        }
    }

    private var barraDoTopo: some View {
        HStack(spacing: 10) {
            MarcaDoApp()
            Spacer()
            NavigationLink { SMBServersView() } label: { BotaoRedondo(simbolo: "server.rack") }
            Button { showingOptions = true } label: { BotaoRedondo(simbolo: "slider.horizontal.3") }
            Menu {
                // Uma entrada só para pasta: "Pastas…" leva à tela que conecta
                // e desconecta. Dois caminhos para o mesmo lugar fazem parar
                // para escolher entre coisas iguais.
                Button { managingFolders = true } label: {
                    Label("Pastas…", systemImage: "folder.badge.gearshape")
                }
                Button { showingFilePicker = true } label: {
                    Label("Abrir arquivo…", systemImage: "doc.badge.plus")
                }
                Divider()
                Button { Task { await library.refresh(bookmarks: bookmarks) } } label: {
                    Label("Procurar de novo", systemImage: "arrow.clockwise")
                }
            } label: { BotaoRedondo(simbolo: "plus") }
        }
        .frame(height: 52)
    }

    @ViewBuilder
    private func faixaDeContinuar(_ itens: [MediaItem]) -> some View {
        if !itens.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Secao(titulo: String(localized: "Continuar assistindo"))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(itens) { item in
                            Button { tocar(item, itens) } label: { CartaoDeContinuar(item: item) }
                                .buttonStyle(.plain)
                                .contextMenu { menuDoItem(item) }
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private func resumoDa(_ grupo: VideoGroup) -> String {
        let n = grupo.items.count
        let bytes = grupo.items.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        return [Plural.videos(n), FolderScanner.humanSize(bytes)]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }

    // MARK: - Ações

    /// A lista de reprodução segue a ordem exibida — "próxima" deve ir para o
    /// que está à frente na tela, não para uma ordem interna invisível.
    private func tocar(_ item: MediaItem, _ fila: [MediaItem]) {
        playlist = fila
        playing = item
    }

    @ViewBuilder
    private func menuDoItem(_ item: MediaItem) -> some View {
        Button {
            showingInfo = item
        } label: {
            Label("Detalhes do arquivo", systemImage: "info.circle")
        }

        // Só arquivo local: no servidor, apagar seria mexer no acervo de
        // verdade, e um toque errado ali não tem desfazer.
        if case .file = item.origin {
            Button(role: .destructive) {
                pendingDeletion = item
            } label: {
                Label("Excluir do aparelho", systemImage: "trash")
            }
        }
    }

    /// Apaga o arquivo de verdade, dentro do escopo que a pasta autoriza.
    private func excluir(_ item: MediaItem) {
        guard case .file(let url, let bookmark) = item.origin else { return }

        let guarda = ScopedAccess(url: url, bookmark: bookmark)
        defer { withExtendedLifetime(guarda) {} }
        guard guarda.path != nil else {
            errorMessage = String(localized: "O iOS não autorizou apagar este arquivo. Reautorize a pasta e tente de novo.")
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            // A marca de onde parou não pode sobreviver ao arquivo: ela
            // reapareceria num arquivo futuro de mesmo nome.
            ResumeStore.shared.clear(key: item.origin.resumeKey)
            Task { await library.refresh(bookmarks: bookmarks) }
        } catch {
            errorMessage = String(localized: "Não deu para apagar: \(error.localizedDescription)")
        }
    }

    private var vazio: some View {
        ScrollView {
            VStack(spacing: 0) {
                // A marca no lugar do ícone genérico: é a primeira tela de quem
                // acabou de instalar, e a única chance de o app se apresentar.
                Image("AppIconSymbol")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .padding(.top, 80)
                NomeDoApp(tamanho: 30)
                    .padding(.top, 14)
                Text(verbatim: "PLAYER")
                    .font(LabFont.swiftUI(11, .semibold))
                    .tracking(6)
                    .foregroundStyle(LabTheme.muted)
                Text("Nenhum vídeo ainda")
                    .font(LabFont.swiftUI(18, .bold))
                    .foregroundStyle(LabTheme.text)
                    .padding(.top, 28)
                // A limitação do iOS explicada onde ela é sentida, em vez de o
                // usuário concluir que o app não funciona.
                Text("O iOS não deixa um app varrer o aparelho inteiro. Autorize uma pasta uma vez — pendrive na USB-C, iCloud ou local — e o LibertyX varre ela sozinho daí em diante, incluindo as subpastas.")
                    .font(LabFont.swiftUI(13, .medium))
                    .foregroundStyle(LabTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)

                Button { showingFolderPicker = true } label: {
                    Text("Adicionar pasta")
                        .font(LabFont.swiftUI(15, .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LabTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 24)
                Button("Abrir um arquivo avulso") { showingFilePicker = true }
                    .font(LabFont.swiftUI(14, .semibold))
                    .padding(.top, 12)

                // O cartão da rede fica só aqui: com vídeos, a barra de cima já
                // tem o botão de servidores, e repetir ao pé da tela disputaria
                // atenção com as capas.
                NavigationLink { SMBServersView() } label: { CartaoDaRede() }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Dentro da pasta

/// Uma pasta aberta: título grande, o resumo, e os vídeos em grade ou lista.
///
/// Empilhada na navegação do sistema — e não trocada no lugar —, para o gesto
/// de voltar deslizando da borda funcionar como em qualquer app de iPhone.
struct PastaView: View {
    let grupo: VideoGroup
    let volta: Int
    let onTocar: (MediaItem, [MediaItem]) -> Void
    let menu: (MediaItem) -> AnyView

    @ObservedObject private var options = LibraryOptions.shared
    @State private var showingOptions = false

    init<Menu: View>(grupo: VideoGroup, volta: Int,
                     onTocar: @escaping (MediaItem, [MediaItem]) -> Void,
                     menu: @escaping (MediaItem) -> Menu) {
        self.grupo = grupo
        self.volta = volta
        self.onTocar = onTocar
        self.menu = { AnyView(menu($0)) }
    }

    var body: some View {
        let ordenados = options.sorted(grupo.items)
        let n = grupo.items.count
        let bytes = grupo.items.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        let resumo = [Plural.videos(n), FolderScanner.humanSize(bytes)]
            .compactMap { $0 }.joined(separator: "  ·  ")

        ZStack {
            FundoDeCapa(capa: capaDa(grupo))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TituloDeTela(titulo: grupo.name, subtitulo: resumo)
                    ListaDeVideos(itens: ordenados, layout: options.layout,
                                  onTocar: onTocar, menu: menu)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 72)
                .id(volta)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingOptions = true } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showingOptions) {
            LibraryOptionsSheet(options: options)
        }
    }
}

/// Os vídeos de uma pasta, em grade ou em lista, na ordem escolhida.
struct ListaDeVideos: View {
    let itens: [MediaItem]
    let layout: LibraryLayout
    let onTocar: (MediaItem, [MediaItem]) -> Void
    let menu: (MediaItem) -> AnyView

    init<Menu: View>(itens: [MediaItem], layout: LibraryLayout,
                     onTocar: @escaping (MediaItem, [MediaItem]) -> Void,
                     menu: @escaping (MediaItem) -> Menu) {
        self.itens = itens
        self.layout = layout
        self.onTocar = onTocar
        self.menu = { AnyView(menu($0)) }
    }

    var body: some View {
        if layout == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                ForEach(itens) { item in
                    Button { onTocar(item, itens) } label: { VideoCard(item: item) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(item) }
                }
            }
        } else {
            LazyVStack(spacing: 4) {
                ForEach(itens) { item in
                    Button { onTocar(item, itens) } label: { VideoRow(item: item) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(item) }
                }
            }
        }
    }
}

/// Conectar e desconectar pastas — o único lugar onde isso se faz.
struct ManageFoldersView: View {

    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss
    @State private var escolhendoPasta = false

    var body: some View {
        NavigationStack {
            List {
                // A seção só existe quando há o que listar. Antes o cabeçalho e
                // o rodapé ficavam na tela com nada entre eles, e por cima
                // aparecia um aviso de "nenhuma pasta" repetindo a mesma
                // informação — dois textos disputando o mesmo espaço para dizer
                // a mesma coisa.
                if !bookmarks.folders.isEmpty {
                    Section {
                        ForEach(bookmarks.folders) { pasta in
                            HStack {
                                Label(pasta.name, systemImage: "folder")
                                Spacer()
                                // Botão à mostra, e não só o deslizar: o gesto
                                // não se anuncia, e quem não sabe que ele
                                // existe conclui que a opção não existe.
                                Button("Desconectar", role: .destructive) {
                                    bookmarks.remove(pasta)
                                }
                                .buttonStyle(.borderless)
                                .font(.callout)
                            }
                        }
                        .onDelete { indices in
                            indices.map { bookmarks.folders[$0] }.forEach(bookmarks.remove)
                        }
                    } header: {
                        Text("Pastas conectadas")
                    } footer: {
                        Text("Desconectar só tira a autorização — nenhum arquivo é apagado do aparelho.")
                    }
                }

                Section {
                    Button {
                        escolhendoPasta = true
                    } label: {
                        Label("Conectar uma pasta…", systemImage: "folder.badge.plus")
                    }
                } footer: {
                    Text("O iOS não deixa um app varrer o aparelho inteiro. Cada pasta conectada aqui passa a ser varrida sozinha, incluindo as subpastas.")
                }
            }
            .navigationTitle("Pastas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .fileImporter(isPresented: $escolhendoPasta,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: true) { resultado in
                guard case .success(let urls) = resultado else { return }
                for url in urls {
                    try? bookmarks.add(url: url)
                }
            }
        }
    }
}

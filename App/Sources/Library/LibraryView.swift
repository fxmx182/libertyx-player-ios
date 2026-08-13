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
    @State private var showingJellyfin = false

    var body: some View {
        NavigationStack {
            Group {
                if library.groups.isEmpty {
                    vazio
                } else {
                    lista
                }
            }
            .navigationTitle("Vídeos")
            // O Jellyfin abre com pilha de navegação própria.
            //
            // Empilhado dentro da pilha da biblioteca, ele misturava dois
            // jeitos de navegar no mesmo caminho, e o SwiftUI respondia
            // voltando ao início ao tocar numa pasta. Com pilha separada, o
            // que acontece lá dentro não depende de nada do lado de fora.
            .fullScreenCover(isPresented: $showingJellyfin) {
                NavigationStack { JellyfinServersView() }
            }
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
            .toolbar {
                // SMB à esquerda, separado das ações locais: são dois mundos
                // diferentes, e misturá-los num menu só esconderia a rede.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingJellyfin = true
                    } label: {
                        Image(systemName: "play.rectangle.on.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SMBServersView()
                    } label: {
                        Image(systemName: "server.rack")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingOptions = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingFolderPicker = true
                        } label: {
                            Label("Adicionar pasta…", systemImage: "folder.badge.plus")
                        }
                        Button {
                            showingFilePicker = true
                        } label: {
                            Label("Abrir arquivo…", systemImage: "doc.badge.plus")
                        }
                        Divider()
                        Button {
                            managingFolders = true
                        } label: {
                            Label("Pastas autorizadas", systemImage: "folder.badge.gearshape")
                        }
                        Button {
                            Task { await library.refresh(bookmarks: bookmarks) }
                        } label: {
                            Label("Varrer de novo", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { await library.refresh(bookmarks: bookmarks) }
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
            .sheet(isPresented: $managingFolders) {
                ManageFoldersView()
            }
            .sheet(item: $showingInfo) { item in
                MediaInfoView(item: item)
            }
            .fullScreenCover(item: $playing) { item in
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

    // MARK: - Conteúdo

    private var lista: some View {
        Group {
            if options.layout == .grid { grade } else { linhas }
        }
        .overlay(alignment: .bottom) {
            if library.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Procurando vídeos…").font(.caption)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
    }

    /// Lista compacta: mais itens por tela, bom para pastas com muitos vídeos.
    private var linhas: some View {
        List {
            ForEach(library.groups) { grupo in
                Section {
                    ForEach(options.sorted(grupo.items)) { item in
                        Button {
                            abrir(item, em: grupo)
                        } label: {
                            VideoRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menuDoItem(item) }
                    }
                } header: {
                    cabecalho(grupo)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Grade: a miniatura vira o elemento principal, com a duração sobre ela —
    /// é como se reconhece um vídeo gravado, cujo nome é só data e hora.
    private var grade: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(library.groups) { grupo in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                                  spacing: 18) {
                            ForEach(options.sorted(grupo.items)) { item in
                                Button {
                                    abrir(item, em: grupo)
                                } label: {
                                    VideoCard(item: item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { menuDoItem(item) }
                            }
                        }
                        .padding(.horizontal, 16)
                    } header: {
                        cabecalho(grupo)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func cabecalho(_ grupo: VideoGroup) -> some View {
        HStack {
            Image(systemName: "folder.fill").font(.caption2)
            Text(grupo.name)
            Spacer()
            Text("\(grupo.items.count)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
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
            errorMessage = "O iOS não autorizou apagar este arquivo. Reautorize a pasta e tente de novo."
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            // A marca de onde parou não pode sobreviver ao arquivo: ela
            // reapareceria num arquivo futuro de mesmo nome.
            ResumeStore.shared.clear(key: item.origin.resumeKey)
            Task { await library.refresh(bookmarks: bookmarks) }
        } catch {
            errorMessage = "Não deu para apagar: \(error.localizedDescription)"
        }
    }

    /// A lista de reprodução segue a ordem exibida — "próxima" deve ir para o
    /// que está à frente na tela, não para uma ordem interna invisível.
    private func abrir(_ item: MediaItem, em grupo: VideoGroup) {
        playlist = options.sorted(grupo.items)
        playing = item
    }

    private var vazio: some View {
        ContentUnavailableView {
            Label("Nenhum vídeo ainda", systemImage: "film.stack")
        } description: {
            // A limitação do iOS explicada onde ela é sentida, em vez de o
            // usuário concluir que o app não funciona.
            Text("O iOS não deixa um app varrer o aparelho inteiro. Autorize uma pasta uma vez — pendrive na USB-C, iCloud ou local — e o LabPlayer varre ela sozinho daí em diante, incluindo as subpastas.")
        } actions: {
            Button("Adicionar pasta") { showingFolderPicker = true }
                .buttonStyle(.borderedProminent)
            Button("Abrir um arquivo avulso") { showingFilePicker = true }
            NavigationLink {
                SMBServersView()
            } label: {
                Text("Conectar a um servidor SMB")
            }
            Button("Conectar ao Jellyfin") { showingJellyfin = true }
        }
    }
}

/// Gerenciar as pastas autorizadas.
struct ManageFoldersView: View {

    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(bookmarks.folders) { pasta in
                        Label(pasta.name, systemImage: "folder")
                    }
                    .onDelete { indices in
                        indices.map { bookmarks.folders[$0] }.forEach(bookmarks.remove)
                    }
                } footer: {
                    Text("Remover uma pasta só tira a autorização — nenhum arquivo é apagado.")
                }
            }
            .navigationTitle("Pastas autorizadas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .overlay {
                if bookmarks.folders.isEmpty {
                    ContentUnavailableView("Nenhuma pasta autorizada",
                                           systemImage: "folder.badge.questionmark")
                }
            }
        }
    }
}

struct VideoRow: View {
    let item: MediaItem
    @State private var miniatura: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item, image: $miniatura)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2)
                HStack(spacing: 6) {
                    if let tamanho = FolderScanner.humanSize(item.fileSize) {
                        Text(tamanho)
                    }
                    // Mostrar que há retomada guardada evita a dúvida de "será
                    // que ele volta de onde parei?".
                    if let retomada = ResumeStore.shared.position(for: item.origin.resumeKey) {
                        Text("· parou em \(TimeFormat.clock(retomada))")
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Cartão da grade: a miniatura ocupa o lugar principal, com a duração no
/// canto — em vídeo gravado pelo celular, cujo nome é só data e hora, a imagem
/// é a única coisa que identifica o arquivo.
struct VideoCard: View {
    let item: MediaItem
    @State private var miniatura: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(item: item, image: $miniatura, largura: nil, altura: 92)

                if let duracao = ThumbnailStore.shared.duration(item) {
                    Text(TimeFormat.clock(duracao))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            Text(item.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let retomada = ResumeStore.shared.position(for: item.origin.resumeKey) {
                Text("parou em \(TimeFormat.clock(retomada))")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// Miniatura da lista: mostra o quadro quando existe, e um espaço reservado
/// enquanto não existe.
///
/// O espaço tem o mesmo tamanho da imagem final para a lista não pular quando
/// as miniaturas chegam — nada mais desagradável que a linha que você ia tocar
/// se mexer no instante do toque.
struct ThumbnailView: View {
    let item: MediaItem
    @Binding var image: UIImage?
    /// `nil` ocupa toda a largura disponível — é assim na grade.
    var largura: CGFloat? = 64
    var altura: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.18))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: largura, height: altura)
        .frame(maxWidth: largura == nil ? .infinity : nil)
        .clipped()
        .task(id: item.id) {
            if let pronta = ThumbnailStore.shared.cached(item) {
                image = pronta
                return
            }
            // Só duas miniaturas são geradas por vez; quem não pegou vez volta
            // a tentar, senão a linha ficaria sem imagem para sempre depois de
            // uma rolagem rápida.
            for _ in 0..<12 {
                if let pronta = await ThumbnailStore.shared.load(item) {
                    image = pronta
                    return
                }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }
}

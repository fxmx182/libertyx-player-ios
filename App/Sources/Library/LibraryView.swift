import SwiftUI

/// Tela inicial: todos os vídeos que o app encontra, agrupados por pasta.
///
/// A varredura é automática. O usuário autoriza uma pasta uma vez — pendrive,
/// iCloud, o que for — e a partir daí não precisa navegar pasta por pasta a
/// cada vez que abre o app.
struct LibraryView: View {

    @EnvironmentObject private var bookmarks: BookmarkStore
    @StateObject private var library = MediaLibrary()

    @State private var showingFolderPicker = false
    @State private var showingFilePicker = false
    @State private var managingFolders = false
    @State private var playing: MediaItem?
    @State private var playlist: [MediaItem] = []
    @State private var showingInfo: MediaItem?
    @State private var errorMessage: String?

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
            .toolbar {
                // SMB à esquerda, separado das ações locais: são dois mundos
                // diferentes, e misturá-los num menu só esconderia a rede.
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SMBServersView()
                    } label: {
                        Image(systemName: "server.rack")
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
        List {
            ForEach(library.groups) { grupo in
                Section {
                    ForEach(grupo.items) { item in
                        Button {
                            playlist = grupo.items
                            playing = item
                        } label: {
                            VideoRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                showingInfo = item
                            } label: {
                                Label("Detalhes do arquivo", systemImage: "info.circle")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "folder.fill").font(.caption2)
                        Text(grupo.name)
                        Spacer()
                        Text("\(grupo.items.count)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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

/// Miniatura da lista: mostra o quadro quando existe, e um espaço reservado
/// enquanto não existe.
///
/// O espaço tem o mesmo tamanho da imagem final para a lista não pular quando
/// as miniaturas chegam — nada mais desagradável que a linha que você ia tocar
/// se mexer no instante do toque.
struct ThumbnailView: View {
    let item: MediaItem
    @Binding var image: UIImage?

    private let largura: CGFloat = 64
    private let altura: CGFloat = 40

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
        .clipped()
        .task(id: item.id) {
            if let pronta = ThumbnailStore.shared.cached(item) {
                image = pronta
                return
            }
            image = await ThumbnailStore.shared.load(item)
        }
    }
}

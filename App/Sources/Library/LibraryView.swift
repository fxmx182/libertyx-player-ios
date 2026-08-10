import SwiftUI

/// Tela inicial: as fontes de mídia.
///
/// Três origens previstas — pastas autorizadas (pendrive USB / iCloud / app),
/// servidores SMB do homelab, e arquivos soltos. A aba SMB ainda está
/// desligada porque depende do motor FFmpeg para ler os bytes pela rede.
struct LibraryView: View {

    @EnvironmentObject private var bookmarks: BookmarkStore

    @State private var showingFolderPicker = false
    @State private var showingFilePicker = false
    @State private var playing: MediaItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                foldersSection
                networkSection
                quickOpenSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("LabPlayer")
            .toolbar {
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
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingFolderPicker) {
                DocumentPicker(mode: .folder) { urls in
                    guard let url = urls.first else { return }
                    do { try bookmarks.add(url: url) }
                    catch { errorMessage = error.localizedDescription }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingFilePicker) {
                DocumentPicker(mode: .videos) { urls in
                    guard let url = urls.first else { return }
                    playing = MediaItem(title: url.lastPathComponent,
                                        origin: .file(url: url, bookmark: nil))
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $playing) { item in
                PlayerScreen(item: item).ignoresSafeArea()
            }
            // Binding real em vez de `.constant`: com constant o alerta nunca
            // se fecha de verdade e volta a aparecer no próximo redesenho.
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

    // MARK: - Seções

    private var foldersSection: some View {
        Section {
            if bookmarks.folders.isEmpty {
                emptyFoldersHint
            } else {
                ForEach(bookmarks.folders) { folder in
                    NavigationLink {
                        FolderBrowserView(folder: folder)
                    } label: {
                        Label(folder.name, systemImage: "folder.fill")
                    }
                }
                .onDelete { indexSet in
                    indexSet.map { bookmarks.folders[$0] }.forEach(bookmarks.remove)
                }
            }
        } header: {
            Text("Pastas")
        } footer: {
            Text("Pendrives ligados na USB-C aparecem no seletor do iOS em “Procurar”. Autorize a pasta uma vez e o LabPlayer lembra dela.")
        }
    }

    private var emptyFoldersHint: some View {
        Button {
            showingFolderPicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adicionar uma pasta").fontWeight(.medium)
                    Text("Pendrive USB, iCloud ou local")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var networkSection: some View {
        Section {
            NavigationLink {
                SMBServersView()
            } label: {
                Label("Servidores SMB", systemImage: "server.rack")
            }
        } header: {
            Text("Rede")
        } footer: {
            Text("Navegar pelos compartilhamentos já funciona. Reproduzir direto do servidor depende do motor FFmpeg — o AVFoundation não fala SMB.")
        }
    }

    private var quickOpenSection: some View {
        Section {
            Button {
                showingFilePicker = true
            } label: {
                Label("Abrir um arquivo avulso", systemImage: "play.rectangle")
            }
        } footer: {
            // Prova de linkagem, não enfeite: se o xcframework não tivesse
            // linkado, o app nem iniciaria. Ver isto no aparelho confirma que
            // a biblioteca está viva antes de existir motor para usá-la.
            Text("FFmpeg \(FFmpegRuntime.version) · \(FFmpegRuntime.demuxerCount) contêineres")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Navegação dentro de uma pasta autorizada.
struct FolderBrowserView: View {

    @EnvironmentObject private var bookmarks: BookmarkStore

    let folder: SavedFolder
    /// Quando não-nulo, estamos numa subpasta e o escopo já está aberto acima.
    var subdirectory: URL?

    @State private var listing = FolderScanner.Listing()
    @State private var resolvedRoot: URL?
    @State private var playing: MediaItem?
    @State private var showingInfo: MediaItem?
    @State private var failedToResolve = false

    private var currentURL: URL? { subdirectory ?? resolvedRoot }

    var body: some View {
        List {
            if failedToResolve {
                ContentUnavailableView(
                    "Pasta indisponível",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("O pendrive pode ter sido removido. Adicione a pasta de novo.")
                )
            }

            ForEach(listing.directories, id: \.self) { url in
                NavigationLink {
                    FolderBrowserView(folder: folder, subdirectory: url)
                } label: {
                    Label(url.lastPathComponent, systemImage: "folder")
                }
            }

            ForEach(listing.videos) { item in
                Button {
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
        }
        .navigationTitle(currentURL?.lastPathComponent ?? folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onDisappear {
            // Só a raiz abriu o escopo; subpastas herdam e não devem fechá-lo.
            if subdirectory == nil { resolvedRoot?.stopAccessingSecurityScopedResource() }
        }
        .fullScreenCover(item: $playing) { item in
            PlayerScreen(item: item).ignoresSafeArea()
        }
        .sheet(item: $showingInfo) { item in
            MediaInfoView(item: item)
        }
        .overlay {
            if listing.directories.isEmpty, listing.videos.isEmpty, !failedToResolve {
                ContentUnavailableView("Nenhum vídeo aqui", systemImage: "film.stack")
            }
        }
    }

    private func refresh() {
        if let subdirectory {
            listing = FolderScanner.scan(subdirectory)
            return
        }
        guard let root = bookmarks.resolve(folder) else {
            failedToResolve = true
            return
        }
        resolvedRoot = root
        listing = FolderScanner.scan(root)
    }
}

private struct VideoRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2)
                if let size = FolderScanner.humanSize(item.fileSize) {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

import SwiftUI

/// Lista de servidores SMB salvos.
struct SMBServersView: View {

    @EnvironmentObject private var store: SMBServerStore
    @State private var editing: SMBServer?
    @State private var pendingDeletion: SMBServer?
    @State private var addingNew = false

    var body: some View {
        List {
            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum servidor", systemImage: "server.rack")
                } description: {
                    Text("Adicione o servidor de casa para abrir os vídeos direto dele.")
                } actions: {
                    Button("Adicionar servidor") { addingNew = true }
                }
            }

            ForEach(store.servers) { server in
                NavigationLink {
                    SMBShareListView(server: server)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).fontWeight(.medium)
                        Text(server.isGuest
                             ? "\(server.displayHost) · convidado"
                             : "\(server.displayHost) · \(server.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDeletion = server
                    } label: {
                        Label("Excluir", systemImage: "trash")
                    }
                    Button {
                        editing = server
                    } label: {
                        Label("Editar", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                // Deslizar o dedo é discreto demais para uma ação que só se
                // usa de vez em quando; segurar é o gesto que o resto do app
                // já usa para menus.
                .contextMenu {
                    Button {
                        editing = server
                    } label: {
                        Label("Editar informações do servidor", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDeletion = server
                    } label: {
                        Label("Excluir servidor", systemImage: "trash")
                    }
                }
            }
        }
        // Confirmação porque excluir também apaga a senha do Keychain — e não
        // há como desfazer isso.
        .alert("Excluir servidor?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { server in
            Button("Excluir", role: .destructive) { store.remove(server) }
            Button("Cancelar", role: .cancel) {}
        } message: { server in
            Text("Remove “\(server.name)” da lista e apaga a senha guardada no Keychain do aparelho.")
        }
        .navigationTitle("Servidores")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addingNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $addingNew) {
            SMBServerEditView(server: nil)
        }
        .sheet(item: $editing) { server in
            SMBServerEditView(server: server)
        }
    }
}

/// Formulário de servidor.
struct SMBServerEditView: View {

    @EnvironmentObject private var store: SMBServerStore
    @Environment(\.dismiss) private var dismiss

    let server: SMBServer?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "445"
    @State private var username = ""
    @State private var password = ""
    @State private var isGuest = false

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && (isGuest || !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor") {
                    TextField("Apelido", text: $name)
                    TextField("Endereço ou IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Porta", text: $port)
                        .keyboardType(.numberPad)
                }

                Section("Acesso") {
                    Toggle("Entrar como convidado", isOn: $isGuest)
                    if !isGuest {
                        TextField("Usuário", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Senha", text: $password)
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("A senha fica no Keychain do aparelho, não junto das outras configurações.")
                }
            }
            .navigationTitle(server == nil ? "Novo servidor" : "Editar servidor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { salvar() }.disabled(!isValid)
                }
            }
            .onAppear(perform: preencher)
        }
    }

    private func preencher() {
        guard let server else { return }
        name = server.name
        host = server.host
        port = String(server.port)
        username = server.username
        isGuest = server.isGuest
        password = store.password(for: server) ?? ""
    }

    private func salvar() {
        let limpo = host.trimmingCharacters(in: .whitespaces)
        var novo = server ?? SMBServer(name: "", host: "", username: "")
        novo.name = name.isEmpty ? limpo : name
        novo.host = limpo
        novo.port = Int(port) ?? 445
        novo.username = username.trimmingCharacters(in: .whitespaces)
        novo.isGuest = isGuest
        store.save(novo, password: isGuest ? nil : password)
        dismiss()
    }
}

/// Shares disponíveis no servidor.
struct SMBShareListView: View {

    @EnvironmentObject private var store: SMBServerStore
    let server: SMBServer

    @State private var shares: [String] = []
    @State private var connection: SMBConnection?
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Conectando…").foregroundStyle(.secondary) }
            } else if let failure {
                ContentUnavailableView("Não conectou", systemImage: "wifi.exclamationmark",
                                       description: Text(failure))
            }

            ForEach(shares, id: \.self) { share in
                if let connection {
                    NavigationLink {
                        SMBDirectoryView(connection: connection, share: share,
                                         path: "", title: share, server: server)
                    } label: {
                        Label(share, systemImage: "externaldrive.connected.to.line.below")
                    }
                }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await conectar() }
    }

    private func conectar() async {
        let conexao = SMBConnection(server: server, password: store.password(for: server))
        connection = conexao
        do {
            shares = try await conexao.listShares()
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }
}

/// Navegação dentro de um share.
struct SMBDirectoryView: View {

    let connection: SMBConnection
    let share: String
    let path: String
    let title: String
    let server: SMBServer

    @State private var entries: [SMBConnection.Entry] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: MediaItem?
    @State private var showingInfo: SMBConnection.Entry?

    /// A pasta inteira vira lista de reprodução, igual às pastas locais.
    private var playlist: [MediaItem] {
        entries.filter { !$0.isDirectory && isVideo($0.name) }.map(mediaItem(for:))
    }

    private func mediaItem(for entry: SMBConnection.Entry) -> MediaItem {
        MediaItem(
            title: entry.name,
            origin: .smb(share: SMBShareRef(serverID: server.id, host: server.host, share: share),
                         path: entry.path),
            fileSize: Int64(entry.size),
            modifiedAt: entry.modifiedAt
        )
    }

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Lendo…").foregroundStyle(.secondary) }
            } else if let failure {
                ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            }

            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        SMBDirectoryView(connection: connection, share: share,
                                         path: entry.path, title: entry.name, server: server)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                } else if isVideo(entry.name) {
                    Button {
                        playing = mediaItem(for: entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "film").foregroundStyle(.tint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).lineLimit(2)
                                Text(FolderScanner.humanSize(Int64(entry.size)) ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            showingInfo = entry
                        } label: {
                            Label("Detalhes do arquivo", systemImage: "info.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await carregar() }
        .sheet(item: $showingInfo) { entry in
            SMBMediaInfoView(connection: connection, share: share,
                             path: entry.path, title: entry.name, size: entry.size)
        }
        .fullScreenCover(item: $playing) { item in
            PlayerScreen(item: item, playlist: playlist).ignoresSafeArea()
        }
        .overlay {
            if !loading, failure == nil, entries.isEmpty {
                ContentUnavailableView("Pasta vazia", systemImage: "folder")
            }
        }
    }

    private func isVideo(_ name: String) -> Bool {
        MediaItem.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func carregar() async {
        do {
            entries = try await connection.list(share: share, path: path)
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }
}

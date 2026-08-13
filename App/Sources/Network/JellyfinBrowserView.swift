import SwiftUI

/// Lista de servidores Jellyfin salvos.
struct JellyfinServersView: View {

    @StateObject private var store = JellyfinStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var addingNew = false
    @State private var editing: JellyfinServer?
    @State private var pendingDeletion: JellyfinServer?

    var body: some View {
        List {
            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum servidor", systemImage: "play.rectangle.on.rectangle")
                } description: {
                    Text("O Jellyfin abre aqui dentro com a interface dele — a mesma do app oficial de celular, com capas, sinopses e a marca de onde você parou. O vídeo toca pelo reprodutor da Apple, que oferece a janela flutuante.")
                } actions: {
                    Button("Conectar ao Jellyfin") { addingNew = true }
                }
            }

            ForEach(store.servers) { servidor in
                NavigationLink {
                    JellyfinWebScreen(server: servidor)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(servidor.name).fontWeight(.medium)
                        Text("\(servidor.displayHost) · \(servidor.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button {
                        editing = servidor
                    } label: {
                        Label("Entrar de novo", systemImage: "person.badge.key")
                    }
                    Button(role: .destructive) {
                        pendingDeletion = servidor
                    } label: {
                        Label("Remover servidor", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Jellyfin")
        .alert("Remover servidor?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { servidor in
            Button("Remover", role: .destructive) { store.remove(servidor) }
            Button("Cancelar", role: .cancel) {}
        } message: { servidor in
            Text("Apaga “\(servidor.name)” e o acesso guardado no Keychain do aparelho.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Fechar") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { addingNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $addingNew) { JellyfinLoginView(existing: nil) }
        .sheet(item: $editing) { servidor in JellyfinLoginView(existing: servidor) }
    }
}

/// Entrar no servidor.
struct JellyfinLoginView: View {

    @StateObject private var store = JellyfinStore.shared
    @Environment(\.dismiss) private var dismiss

    let existing: JellyfinServer?

    @State private var endereco = ""
    @State private var usuario = ""
    @State private var senha = ""
    @State private var entrando = false
    @State private var falha: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor") {
                    TextField("http://192.168.0.10:8096", text: $endereco)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("Acesso") {
                    TextField("Usuário", text: $usuario)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Senha", text: $senha)
                }

                if let falha {
                    Section {
                        Text(falha).foregroundStyle(.red).font(.callout)
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    // A senha é usada uma vez e descartada: o servidor devolve
                    // um token, e é ele que fica.
                    Text("A senha é usada só para entrar. O que fica guardado no Keychain é o acesso que o servidor devolve, não a senha.")
                }
            }
            .navigationTitle(existing == nil ? "Conectar ao Jellyfin" : "Entrar de novo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if entrando {
                        ProgressView()
                    } else {
                        Button("Entrar") { Task { await entrar() } }
                            .disabled(endereco.isEmpty || usuario.isEmpty)
                    }
                }
            }
            .onAppear {
                guard let existing else { return }
                endereco = existing.baseURL.absoluteString
                usuario = existing.username
            }
        }
    }

    private func entrar() async {
        entrando = true
        falha = nil
        defer { entrando = false }

        // Digitar "192.168.0.10:8096" sem esquema é o normal; completar isso é
        // trabalho do app, não do usuário.
        var texto = endereco.trimmingCharacters(in: .whitespaces)
        if !texto.lowercased().hasPrefix("http") { texto = "http://" + texto }
        while texto.hasSuffix("/") { texto.removeLast() }

        guard let url = URL(string: texto) else {
            falha = "Endereço inválido."
            return
        }

        do {
            let (userID, token) = try await JellyfinClient.authenticate(
                baseURL: url, username: usuario, password: senha)

            // O identificador e o nome do servidor vêm de um pedido público:
            // é o que a interface web usa para reconhecer a sessão que
            // entregamos pronta, e evita você digitar a senha duas vezes.
            let publico = try? await JellyfinClient.publicInfo(baseURL: url)

            var servidor = existing ?? JellyfinServer(name: "", baseURL: url,
                                                      username: usuario, userID: userID)
            servidor.name = publico?.name ?? (url.host ?? texto)
            servidor.baseURL = url
            servidor.username = usuario
            servidor.userID = userID
            servidor.systemID = publico?.id
            store.save(servidor, token: token)
            dismiss()
        } catch {
            falha = error.localizedDescription
        }
    }
}

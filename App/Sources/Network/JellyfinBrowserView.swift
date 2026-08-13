import SwiftUI

/// Lista de servidores Jellyfin salvos.
struct JellyfinServersView: View {

    @StateObject private var store = JellyfinStore.shared
    @State private var addingNew = false
    @State private var editing: JellyfinServer?
    @State private var pendingDeletion: JellyfinServer?

    var body: some View {
        List {
            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum servidor", systemImage: "play.rectangle.on.rectangle")
                } description: {
                    Text("Com o Jellyfin, os filmes chegam com capa, sinopse e a marca de onde você parou — e o servidor reembala o vídeo para o reprodutor da Apple, o que traz rolagem quadro a quadro e janela flutuante.")
                } actions: {
                    Button("Conectar ao Jellyfin") { addingNew = true }
                }
            }

            ForEach(store.servers) { servidor in
                NavigationLink {
                    JellyfinLibraryView(server: servidor, parent: nil, title: servidor.name)
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

            var servidor = existing ?? JellyfinServer(name: "", baseURL: url,
                                                      username: usuario, userID: userID)
            servidor.name = url.host ?? texto
            servidor.baseURL = url
            servidor.username = usuario
            servidor.userID = userID
            store.save(servidor, token: token)
            dismiss()
        } catch {
            falha = error.localizedDescription
        }
    }
}

/// Uma biblioteca ou pasta do servidor.
struct JellyfinLibraryView: View {

    let server: JellyfinServer
    /// `nil` na raiz: aí o que se lista são as bibliotecas.
    let parent: String?
    let title: String

    @State private var itens: [JellyfinClient.Item] = []
    @State private var carregando = true
    @State private var falha: String?
    @State private var tocando: MediaItem?
    @State private var retomada: Double?

    private var client: JellyfinClient? {
        guard let token = JellyfinStore.shared.token(for: server) else { return nil }
        return JellyfinClient(server: server, token: token)
    }

    private let colunas = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        ScrollView {
            if carregando {
                ProgressView().padding(.top, 40)
            } else if let falha {
                ContentUnavailableView("Não deu para ler", systemImage: "wifi.exclamationmark",
                                       description: Text(falha))
                    .padding(.top, 30)
            } else if itens.isEmpty {
                ContentUnavailableView("Nada aqui", systemImage: "film.stack").padding(.top, 30)
            } else {
                LazyVGrid(columns: colunas, spacing: 14) {
                    ForEach(itens) { item in
                        if item.isFolder {
                            NavigationLink {
                                JellyfinLibraryView(server: server, parent: item.id, title: item.name)
                            } label: {
                                JellyfinCard(item: item, client: client)
                            }
                            .buttonStyle(.plain)
                        } else if item.isPlayable {
                            Button {
                                abrir(item)
                            } label: {
                                JellyfinCard(item: item, client: client)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await carregar() }
        .fullScreenCover(item: $tocando) { item in
            PlayerScreen(item: item, playlist: [item]).ignoresSafeArea()
        }
    }

    private func abrir(_ item: JellyfinClient.Item) {
        guard let client, let url = client.streamURL(for: item) else { return }

        // A marca de onde parou vem do servidor, então ela vale em qualquer
        // aparelho — é para isso que serve ter um Jellyfin.
        if let posicao = item.resumePosition, let duracao = item.duration {
            ResumeStore.shared.save(position: posicao, duration: duracao,
                                    for: MediaOrigin.remote(url: url).resumeKey)
        }
        tocando = MediaItem(title: item.name, origin: .remote(url: url))
    }

    private func carregar() async {
        guard let client else {
            falha = "Acesso não encontrado. Entre no servidor de novo."
            carregando = false
            return
        }
        do {
            itens = parent == nil ? try await client.views() : try await client.children(of: parent!)
        } catch {
            falha = error.localizedDescription
        }
        carregando = false
    }
}

/// Cartão com a capa que o servidor já tem pronta.
///
/// Nenhuma extração de quadro aqui: o Jellyfin guarda pôster de verdade, com
/// o nome do filme escrito nele. É melhor do que qualquer miniatura que a
/// gente conseguisse tirar.
struct JellyfinCard: View {

    let item: JellyfinClient.Item
    let client: JellyfinClient?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))

                if let url = client?.imageURL(for: item, maxWidth: 300) {
                    AsyncImage(url: url) { imagem in
                        imagem.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ProgressView()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: item.isFolder ? "folder" : "film")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                // A faixa de progresso repete o que o servidor sabe: quanto
                // deste filme você já viu.
                if let posicao = item.resumePosition, let duracao = item.duration, duracao > 0 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * min(1, posicao / duracao), height: 3)
                            .offset(y: geo.size.height - 3)
                    }
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipped()

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)

            if let ano = item.year {
                Text(String(ano)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

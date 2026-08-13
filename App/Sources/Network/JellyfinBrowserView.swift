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
                NavigationLink(value: JellyfinRoute(server: servidor, parent: nil,
                                                    title: servidor.name,
                                                    collectionType: nil)) {
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
        // Um registro só, aqui na base, valendo para toda a pilha.
        //
        // Misturar link por destino com link por valor no mesmo caminho faz o
        // SwiftUI desistir da navegação e voltar à raiz — era isso que
        // acontecia ao tocar numa pasta. Agora todos os saltos do Jellyfin
        // falam a mesma língua.
        .navigationDestination(for: JellyfinRoute.self) { rota in
            JellyfinLibraryView(server: rota.server, parent: rota.parent,
                                title: rota.title, collectionType: rota.collectionType)
        }
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

/// Para onde um toque leva, como dado.
///
/// Ser `Hashable` é o que permite ao SwiftUI empilhar a tela certa: o destino
/// deixa de ser uma view construída antes da hora e passa a ser uma escolha
/// resolvida na hora de navegar.
struct JellyfinRoute: Hashable {
    let server: JellyfinServer
    /// `nil` na raiz do servidor, onde o que se lista são as bibliotecas.
    let parent: String?
    let title: String
    let collectionType: String?
}

/// Uma biblioteca ou pasta do servidor.
struct JellyfinLibraryView: View {

    let server: JellyfinServer
    /// `nil` na raiz: aí o que se lista são as bibliotecas.
    let parent: String?
    let title: String
    /// "livetv" quando esta tela é a da TV ao vivo — ela se lê de outro jeito.
    var collectionType: String? = nil

    @State private var itens: [JellyfinClient.Item] = []
    @State private var carregando = true
    @State private var falha: String?
    @State private var tocando: MediaItem?
    /// Qual cartão está esperando resposta do servidor.
    @State private var abrindo: String?

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
                            // Navegação por valor, e não por destino embutido.
                            //
                            // Construir a tela de destino dentro de uma grade
                            // preguiçosa deixa o SwiftUI livre para casar
                            // destino e célula errados — era isso que abria
                            // Séries ao tocar em Filmes. Dar identidade não
                            // bastou; o jeito é o destino ser um dado e a tela
                            // ser montada só no momento de empilhar.
                            NavigationLink(value: JellyfinRoute(
                                server: server,
                                parent: item.id,
                                title: item.name,
                                collectionType: item.collectionType
                            )) {
                                JellyfinCard(item: item, client: client)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        } else if item.isPlayable {
                            Button {
                                abrir(item)
                            } label: {
                                JellyfinCard(item: item, client: client)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
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
        .overlay {
            if abrindo != nil {
                ProgressView("Preparando…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Não deu para abrir", isPresented: Binding(
            get: { falha != nil && !carregando },
            set: { if !$0 { falha = nil } }
        )) {
            Button("Fechar", role: .cancel) { falha = nil }
        } message: {
            Text(falha ?? "")
        }
        .fullScreenCover(item: $tocando) { item in
            PlayerScreen(item: item, playlist: [item]).ignoresSafeArea()
        }
    }

    private func abrir(_ item: JellyfinClient.Item) {
        guard let client else { return }
        abrindo = item.id
        Task {
            defer { abrindo = nil }
            do {
                // Quem decide como o vídeo vem é o servidor, não nós — daí
                // isto ser uma ida à rede e não uma URL montada na hora.
                let url = try await client.playbackURL(for: item)

                // A marca de onde parou vem do servidor, então ela vale em
                // qualquer aparelho — é para isso que serve ter um Jellyfin.
                if let posicao = item.resumePosition, let duracao = item.duration {
                    ResumeStore.shared.save(position: posicao, duration: duracao,
                                            for: MediaOrigin.remote(url: url).resumeKey)
                }
                tocando = MediaItem(title: item.name, origin: .remote(url: url),
                                    isLiveStream: item.type == "TvChannel")
            } catch {
                falha = error.localizedDescription
            }
        }
    }

    private func carregar() async {
        guard let client else {
            falha = "Acesso não encontrado. Entre no servidor de novo."
            carregando = false
            return
        }
        do {
            if collectionType == "livetv" {
                itens = try await client.liveChannels()
            } else if let parent {
                itens = try await client.children(of: parent)
            } else {
                itens = try await client.views()
            }
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
            // Quem manda no tamanho é este retângulo invisível, e só ele.
            //
            // Antes o pôster estava dentro de uma pilha, junto de um leitor de
            // geometria — que ocupa tudo o que puder. A célula deixava de ter
            // tamanho próprio e os cartões passavam por cima uns dos outros.
            // Em sobreposição, `overlay` é diferente de empilhar: o conteúdo de
            // um overlay não pode aumentar quem o hospeda.
            Color.clear
                // Canal de TV tem logotipo largo; filme tem pôster em pé.
                // Forçar a mesma forma nos dois deixaria um dos dois torto.
                .aspectRatio(item.type == "TvChannel" ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
                .overlay { capa }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(alignment: .bottom) { progresso }

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)

            if let agora = item.nowPlaying {
                Text(agora).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            } else if let ano = item.year {
                Text(String(ano)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var capa: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.18))

            if let url = client?.imageURL(for: item, maxWidth: 300) {
                AsyncImage(url: url) { fase in
                    switch fase {
                    case .success(let imagem):
                        imagem.resizable()
                            .aspectRatio(contentMode: item.type == "TvChannel" ? .fit : .fill)
                            .padding(item.type == "TvChannel" ? 8 : 0)
                    case .failure:
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    default:
                        ProgressView()
                    }
                }
                .id(url)
            } else {
                Image(systemName: item.isFolder ? "folder" : "film")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Quanto deste filme você já viu, do jeito que o servidor sabe.
    @ViewBuilder
    private var progresso: some View {
        if let posicao = item.resumePosition, let duracao = item.duration, duracao > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.35))
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * min(1, posicao / duracao))
                }
            }
            .frame(height: 3)
        }
    }
}

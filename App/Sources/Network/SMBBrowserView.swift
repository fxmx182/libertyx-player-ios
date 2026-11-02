import SwiftUI

/// Um cadastro de servidor pedido de fora da tela de servidores — o "+" da
/// biblioteca.
enum NovoServidor: Hashable {
    case smb
    case conta(ContaDeRede.Tipo)
}

/// Como os Ajustes separam os cadastros: os servidores de casa (SMB, Jellyfin,
/// Emby) de um lado, o WebDAV do outro.
enum GrupoDeServidores: Hashable {
    case todos, servidores, webdav

    func mostra(_ tipo: ContaDeRede.Tipo) -> Bool {
        switch self {
        case .todos:      return true
        case .servidores: return tipo != .webdav
        case .webdav:     return tipo == .webdav
        }
    }

    var temSMB: Bool { self != .webdav }
}

/// Lista de servidores salvos: SMB, WebDAV, Jellyfin e Emby.
struct SMBServersView: View {
    /// Abre o formulário daquele tipo assim que a tela aparece.
    var cadastroInicial: NovoServidor? = nil
    /// Que parte dos cadastros esta tela mostra — ver `GrupoDeServidores`.
    var grupo: GrupoDeServidores = .todos
    @State private var cadastroAberto = false

    @EnvironmentObject private var store: SMBServerStore
    @ObservedObject private var contas = ContasDeRede.shared
    @StateObject private var discovery = SMBDiscovery()
    @State private var editing: SMBServer?
    @State private var pendingDeletion: SMBServer?
    @State private var addingNew = false
    @State private var prefilled: SMBServer?
    @State private var novaConta: ContaDeRede.Tipo?
    @State private var editandoConta: ContaDeRede?
    @State private var removendoConta: ContaDeRede?

    private var servidores: [SMBServer] { grupo.temSMB ? store.servers : [] }
    private var contasVisiveis: [ContaDeRede] { contas.contas.filter { grupo.mostra($0.tipo) } }

    var body: some View {
        List {
            // Os servidores salvos primeiro: é para eles que se entra aqui na
            // maioria das vezes. A procura automática interessa uma vez, no dia
            // em que se cadastra um servidor novo — e ficava justamente no
            // caminho de quem só quer abrir um vídeo.
            if servidores.isEmpty && contasVisiveis.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum servidor", systemImage: grupo == .webdav ? ContaDeRede.Tipo.webdav.simbolo : "server.rack")
                } description: {
                    Text("Adicione o servidor de casa para abrir os vídeos direto dele.")
                } actions: {
                    if grupo == .webdav {
                        Button("Adicionar WebDAV") { novaConta = .webdav }
                    } else {
                        Menu("Adicionar servidor") { opcoesDeServidor }
                    }
                }
            }

            ForEach(servidores) { server in
                NavigationLink {
                    SMBShareListView(server: server)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).fontWeight(.medium)
                        Text(server.isGuest
                             ? String(localized: "\(server.displayHost) · convidado")
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

            ForEach(contasVisiveis) { conta in
                NavigationLink {
                    PastaRemotaView(titulo: conta.nome, destino: .inicio(conta))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: conta.tipo.simbolo)
                            .foregroundStyle(LabTheme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conta.nome).fontWeight(.medium)
                            Text(conta.usuario.isEmpty
                                 ? "\(conta.tipo.nome) · \(conta.enderecoCurto)"
                                 : "\(conta.tipo.nome) · \(conta.enderecoCurto) · \(conta.usuario)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        removendoConta = conta
                    } label: {
                        Label("Excluir", systemImage: "trash")
                    }
                    Button {
                        editandoConta = conta
                    } label: {
                        Label("Editar", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button {
                        editandoConta = conta
                    } label: {
                        Label("Editar informações do servidor", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        removendoConta = conta
                    } label: {
                        Label("Excluir servidor", systemImage: "trash")
                    }
                }
            }

            // WebDAV não se anuncia na rede: nada a procurar.
            if grupo.temSMB { procuraAutomatica }
        }
        .alert("Excluir servidor?", isPresented: Binding(
            get: { removendoConta != nil },
            set: { if !$0 { removendoConta = nil } }
        ), presenting: removendoConta) { conta in
            Button("Excluir", role: .destructive) { contas.remover(conta) }
            Button("Cancelar", role: .cancel) {}
        } message: { conta in
            Text("Remove “\(conta.nome)” da lista e apaga a senha guardada no Keychain do aparelho.")
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
        // Largura com teto e centrada: num iPad deitado, linhas de ponta a
        // ponta deixavam o nome do servidor de um lado da tela e a ação do
        // outro.
        .frame(maxWidth: Escala.larguraMaxima)
        .frame(maxWidth: .infinity)
        .fundoDaRede()
        .navigationTitle(grupo == .webdav ? String(localized: "WebDAV / Nextcloud") : String(localized: "Servidores"))
        .task { if grupo.temSMB { discovery.start(conhecidos: store.servers.map(\.host)) } }
        .onAppear {
            // Uma vez só: voltar de dentro de um servidor não pode reabrir
            // o formulário.
            guard let cadastroInicial, !cadastroAberto else { return }
            cadastroAberto = true
            switch cadastroInicial {
            case .smb:              addingNew = true
            case .conta(let tipo):  novaConta = tipo
            }
        }
        .onDisappear { discovery.stop() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // WebDAV tem um tipo só: o "+" vai direto ao formulário.
                if grupo == .webdav {
                    Button { novaConta = .webdav } label: { Image(systemName: "plus") }
                } else {
                    Menu { opcoesDeServidor } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $addingNew) {
            SMBServerEditView(server: nil)
        }
        .sheet(item: $novaConta) { tipo in
            ContaDeRedeEditView(tipo: tipo, conta: nil)
        }
        .sheet(item: $editandoConta) { conta in
            ContaDeRedeEditView(tipo: conta.tipo, conta: conta)
        }
        .sheet(item: $editing) { server in
            SMBServerEditView(server: server)
        }
        .sheet(item: $prefilled) { server in
            SMBServerEditView(server: server, isNew: true)
        }
    }

    /// Os tipos de servidor que dá para cadastrar.
    @ViewBuilder
    private var opcoesDeServidor: some View {
        if grupo.temSMB {
            Button { addingNew = true } label: {
                Label("SMB (Windows, NAS, Samba)", systemImage: "server.rack")
            }
        }
        if grupo.mostra(.webdav) {
            Button { novaConta = .webdav } label: {
                Label("WebDAV (Nextcloud)", systemImage: ContaDeRede.Tipo.webdav.simbolo)
            }
        }
        if grupo.mostra(.jellyfin) {
            Button { novaConta = .jellyfin } label: {
                Label("Jellyfin", systemImage: ContaDeRede.Tipo.jellyfin.simbolo)
            }
            Button { novaConta = .emby } label: {
                Label("Emby", systemImage: ContaDeRede.Tipo.emby.simbolo)
            }
        }
    }

    /// Servidores achados na rede, com o que já está salvo filtrado fora —
    /// oferecer de novo o que o usuário já cadastrou só polui a lista.
    @ViewBuilder
    private var procuraAutomatica: some View {
        let novos = discovery.results.filter { achado in
            !store.servers.contains { $0.host.caseInsensitiveCompare(achado.host) == .orderedSame }
        }

        if discovery.isSearching || !novos.isEmpty || discovery.hasFinished {
            Section {
                ForEach(novos) { achado in
                    Button {
                        // Abre o formulário já preenchido: o endereço é a parte
                        // chata de descobrir, o usuário só completa o acesso.
                        prefilled = SMBServer(name: achado.name, host: achado.host, username: "")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(achado.name).foregroundStyle(.primary)
                                Text("SMB").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                }

                if discovery.isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Procurando na rede…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if novos.isEmpty {
                    // Silêncio no fim da busca parece busca quebrada. Diz o que
                    // houve — inclusive quando ela achou, mas só o que já
                    // estava salvo.
                    Text(discovery.results.isEmpty
                         ? String(localized: "Nada encontrado na rede. É comum quando o servidor não se anuncia — adicione pelo endereço, no botão +.")
                         : String(localized: "Na rede só apareceram servidores que já estão salvos."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Encontrados na rede")
            } footer: {
                Text("Servidores que responderam na sua rede e ainda não estão salvos. Toque para cadastrar com o endereço já preenchido.")
            }
        }
    }
}

/// Formulário de servidor.
struct SMBServerEditView: View {

    @EnvironmentObject private var store: SMBServerStore
    @Environment(\.dismiss) private var dismiss

    let server: SMBServer?
    /// Vindo da procura automática o formulário chega preenchido, mas ainda é
    /// um cadastro novo — o título precisa dizer isso.
    var isNew = false

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
            .navigationTitle((server == nil || isNew) ? String(localized: "Novo servidor") : String(localized: "Editar servidor"))
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
                        LinhaDePastaDeRede(nome: share, simbolo: "externaldrive.fill.badge.wifi", seta: false)
                    }
                    .linhaDeVidro()
                }
            }
        }
        .fundoDaRede()
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
    // Não privado: um campo privado tornaria privado o init gerado da view.
    var escala = Escala()

    let connection: SMBConnection
    let share: String
    let path: String
    let title: String
    let server: SMBServer

    /// As mesmas opções da biblioteca local, e não um conjunto à parte: quem
    /// escolheu grade e ordem por data espera encontrar a pasta de rede igual.
    @ObservedObject private var options = LibraryOptions.shared

    @State private var entries: [SMBConnection.Entry] = []
    /// Um item por arquivo, criado uma vez por listagem.
    ///
    /// Recriar a cada desenho daria identidade nova ao mesmo vídeo, e o player
    /// não o acharia na própria lista de reprodução — "próximo" iria para o
    /// começo em vez de seguir.
    @State private var itensPorCaminho: [String: MediaItem] = [:]
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: MediaItem?
    @State private var showingInfo: SMBConnection.Entry?
    @State private var mostrandoOpcoes = false

    /// Subpastas sempre em cima e por nome: são caminho, não conteúdo, e
    /// ordená-las por tamanho ou duração não diria nada.
    private var pastas: [SMBConnection.Entry] {
        entries.filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Só os vídeos, na ordem escolhida. A lista de reprodução segue esta ordem:
    /// "próximo" vai para o que está à frente na tela.
    private var videos: [MediaItem] {
        options.sorted(entries
            .filter { !$0.isDirectory && isVideo($0.name) }
            .compactMap { itensPorCaminho[$0.path] })
    }

    var body: some View {
        conteudo
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { mostrandoOpcoes = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .task { await carregar() }
            .sheet(isPresented: $mostrandoOpcoes) {
                LibraryOptionsSheet(options: options)
            }
            .sheet(item: $showingInfo) { entry in
                SMBMediaInfoView(connection: connection, share: share,
                                 path: entry.path, title: entry.name, size: entry.size)
            }
            .fullScreenCover(item: $playing) { item in
                PlayerScreen(item: item, playlist: videos).ignoresSafeArea()
            }
    }

    @ViewBuilder
    private var conteudo: some View {
        if loading {
            ProgressView("Lendo…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if pastas.isEmpty && videos.isEmpty {
            ContentUnavailableView("Nenhum vídeo nesta pasta", systemImage: "folder")
        } else if options.layout == .grid {
            grade
        } else {
            lista
        }
    }

    // MARK: - Lista e grade

    private var lista: some View {
        List {
            if !pastas.isEmpty {
                Section {
                    ForEach(pastas) { pasta in
                        NavigationLink { destino(pasta) } label: {
                            LinhaDePastaDeRede(nome: pasta.name, seta: false)
                        }
                        .linhaDeVidro()
                    }
                }
            }
            if !videos.isEmpty {
                Section {
                    ForEach(videos) { item in
                        Button { playing = item } label: {
                            // Mesma linha da biblioteca local, para o servidor
                            // não parecer um lugar de segunda classe no app.
                            VideoRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(item) }
                        .linhaDeVidro()
                    }
                }
            }
        }
        .listStyle(.plain)
        .fundoDaRede()
    }

    private var grade: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !pastas.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(pastas) { pasta in
                            NavigationLink { destino(pasta) } label: {
                                LinhaDePastaDeRede(nome: pasta.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: escala.capa), spacing: 12, alignment: .top)], spacing: 14) {
                    ForEach(videos) { item in
                        Button { playing = item } label: { VideoCard(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(item) }
                    }
                }
            }
            .padding(16)
        }
        .fundoDaRede()
    }

    // MARK: - Peças

    private func destino(_ pasta: SMBConnection.Entry) -> some View {
        SMBDirectoryView(connection: connection, share: share,
                         path: pasta.path, title: pasta.name, server: server)
    }

    @ViewBuilder
    private func menu(_ item: MediaItem) -> some View {
        if case .smb(_, let caminho) = item.origin,
           let entrada = entries.first(where: { $0.path == caminho }) {
            Button {
                showingInfo = entrada
            } label: {
                Label("Detalhes do arquivo", systemImage: "info.circle")
            }
        }
    }

    private func isVideo(_ name: String) -> Bool {
        MediaItem.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func carregar() async {
        do {
            let lidas = try await connection.list(share: share, path: path)
            let referencia = SMBShareRef(serverID: server.id, host: server.host, share: share)
            var itens: [String: MediaItem] = [:]
            for entrada in lidas where !entrada.isDirectory && isVideo(entrada.name) {
                itens[entrada.path] = MediaItem(
                    title: entrada.name,
                    origin: .smb(share: referencia, path: entrada.path),
                    fileSize: Int64(entrada.size),
                    modifiedAt: entrada.modifiedAt
                )
            }
            itensPorCaminho = itens
            entries = lidas
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }
}

/// Uma pasta de rede: o ícone num ladrilho, e não solto.
///
/// O ladrilho dá à linha um ponto de apoio à esquerda e deixa a pasta de rede
/// com a mesma família visual do cartão de servidores da biblioteca.
struct LinhaDePastaDeRede: View {
    let nome: String
    var simbolo = "folder.fill"
    /// Numa `List` o próprio sistema desenha a seta; ali a nossa sai.
    var seta = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: simbolo)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LabTheme.accent)
                .frame(width: 40, height: 40)
                .background(LabTheme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(nome)
                .font(LabFont.swiftUI(15, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if seta {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LabTheme.faint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .labCard()
        .contentShape(Rectangle())
    }
}

extension View {
    /// Linha de lista sem o fundo nem o separador do sistema: o que desenha
    /// a linha é a própria peça, e o cinza de formulário por trás tiraria o
    /// app do fundo de capa.
    func linhaDeVidro() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    /// O mesmo fundo da biblioteca: passar para a rede não pode parecer
    /// trocar de app.
    func fundoDaRede() -> some View {
        scrollContentBackground(.hidden)
            .background(FundoDeCapa(capa: nil))
    }
}

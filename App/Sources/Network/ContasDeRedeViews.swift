import SwiftUI

extension ContaDeRede.Tipo: Identifiable {
    var id: String { rawValue }
}

// MARK: - Cadastro

/// Formulário de conta WebDAV, Jellyfin ou Emby.
///
/// Salvar já testa a conta: um endereço errado descoberto só na hora de abrir
/// a pasta parece defeito do app. No Jellyfin/Emby salvar é também entrar —
/// o que se guarda é o token, não a senha.
struct ContaDeRedeEditView: View {

    @ObservedObject private var contas = ContasDeRede.shared
    @Environment(\.dismiss) private var dismiss

    let tipo: ContaDeRede.Tipo
    let conta: ContaDeRede?

    @State private var nome = ""
    @State private var endereco = ""
    @State private var usuario = ""
    @State private var senha = ""
    @State private var testando = false
    @State private var falha: String?
    /// Os usuários que o servidor mostra na tela de entrada dele.
    @State private var usuariosDoServidor: [String] = []
    /// O código do Quick Connect enquanto espera a aprovação.
    @State private var codigoQuick: String?
    @State private var tarefaQuick: Task<Void, Never>?

    private var isValid: Bool {
        !endereco.trimmingCharacters(in: .whitespaces).isEmpty
            && (!tipo.ehServidorDeMidia || !usuario.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var exemplo: String {
        switch tipo {
        case .webdav:   return "https://nuvem.exemplo.com/remote.php/dav/files/usuario/"
        case .jellyfin: return "http://192.168.0.10:8096"
        case .emby:     return "http://192.168.0.10:8096"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor") {
                    TextField("Apelido", text: $nome)
                    TextField(exemplo, text: $endereco)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("Acesso") {
                    TextField("Usuário", text: $usuario)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !usuariosDoServidor.isEmpty {
                        Menu {
                            ForEach(usuariosDoServidor, id: \.self) { nome in
                                Button(nome) { usuario = nome }
                            }
                        } label: {
                            Label("Escolher usuário", systemImage: "person.2")
                        }
                    }
                    SecureField(conta != nil && tipo.ehServidorDeMidia
                                ? String(localized: "Senha (só para entrar de novo)")
                                : String(localized: "Senha"),
                                text: $senha)
                }

                if tipo.ehServidorDeMidia { secaoQuickConnect }

                if let falha {
                    Section {
                        Label(falha, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text(tipo == .webdav
                         ? String(localized: "No Nextcloud basta o endereço do servidor: o app completa o caminho dos seus arquivos. A senha fica no Keychain do aparelho.")
                         : String(localized: "A senha serve só para entrar. O app guarda a chave de acesso que o servidor devolve, no Keychain do aparelho, e toca os arquivos originais, sem conversão."))
                }
            }
            .disabled(testando)
            .navigationTitle(conta == nil
                             ? String(localized: "Novo servidor \(tipo.nome)")
                             : String(localized: "Editar servidor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if testando {
                        ProgressView()
                    } else {
                        Button("Salvar") { Task { await salvar() } }.disabled(!isValid)
                    }
                }
            }
            .onAppear(perform: preencher)
            .onDisappear { tarefaQuick?.cancel() }
            .task(id: endereco) { await lerUsuarios() }
        }
    }

    // MARK: - Quick Connect

    /// Entrar sem digitar a senha: o app mostra um código, e alguém já
    /// conectado a este servidor (no app dele ou no navegador) aprova.
    private var secaoQuickConnect: some View {
        Section {
            if let codigoQuick {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Aprove este código em outro aparelho já conectado ao servidor (Configurações › Quick Connect):")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: codigoQuick)
                        .font(.system(size: 34, weight: .heavy, design: .monospaced))
                        .tracking(6)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Esperando a aprovação…").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button("Cancelar", role: .cancel) {
                    tarefaQuick?.cancel()
                    self.codigoQuick = nil
                }
            } else {
                Button { comecarQuickConnect() } label: {
                    Label("Entrar com Quick Connect", systemImage: "number.square")
                }
                .disabled(endereco.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Text("Sem digitar a senha: o app mostra um código, e você aprova num aparelho que já está conectado.")
        }
    }

    private func comecarQuickConnect() {
        falha = nil
        tarefaQuick?.cancel()
        tarefaQuick = Task { @MainActor in
            let candidatos = enderecosPossiveis
            for candidato in candidatos {
                do {
                    let pedido = try await ServidorDeMidia.iniciarQuickConnect(tipo: tipo, endereco: candidato)
                    codigoQuick = pedido.Code
                    let acesso = try await ServidorDeMidia.esperarQuickConnect(tipo: tipo, endereco: candidato, pedido)
                    var nova = conta ?? ContaDeRede(tipo: tipo, nome: "", endereco: "", usuario: "")
                    nova.endereco = candidato
                    nova.usuario = acesso.usuario
                    nova.nome = nome.isEmpty ? nova.enderecoCurto : nome
                    nova.idNoServidor = acesso.usuarioID
                    contas.salvar(nova, segredo: acesso.token)
                    codigoQuick = nil
                    dismiss()
                    return
                } catch where error.foiCancelado {
                    codigoQuick = nil
                    return
                } catch is URLError where candidato != candidatos.last {
                    continue
                } catch {
                    falha = error.localizedDescription
                    codigoQuick = nil
                    return
                }
            }
        }
    }

    /// Os usuários visíveis do servidor, para escolher sem digitar. Espera a
    /// pessoa parar de digitar o endereço.
    private func lerUsuarios() async {
        guard tipo.ehServidorDeMidia,
              !endereco.trimmingCharacters(in: .whitespaces).isEmpty else {
            usuariosDoServidor = []
            return
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }
        for candidato in enderecosPossiveis {
            let nomes = await ServidorDeMidia.usuariosVisiveis(tipo: tipo, endereco: candidato)
            guard !Task.isCancelled else { return }
            if !nomes.isEmpty {
                usuariosDoServidor = nomes
                return
            }
        }
        usuariosDoServidor = []
    }

    private func preencher() {
        guard let conta else { return }
        nome = conta.nome
        endereco = conta.endereco
        usuario = conta.usuario
        if conta.tipo == .webdav { senha = contas.segredo(conta) ?? "" }
    }

    /// Os endereços a tentar, na ordem.
    ///
    /// Sem esquema não dá para saber: `maujellyfin.uk` atrás do Cloudflare só
    /// fala HTTPS, e `192.168.0.10:8096` em casa só fala HTTP. Tenta HTTPS
    /// primeiro e cai para HTTP só se nem conectar — erro de senha num deles
    /// já é resposta e encerra a tentativa.
    private var enderecosPossiveis: [String] {
        let texto = endereco.trimmingCharacters(in: .whitespacesAndNewlines)
        let minusculo = texto.lowercased()
        if minusculo.hasPrefix("http://") || minusculo.hasPrefix("https://") { return [texto] }
        return ["https://" + texto, "http://" + texto]
    }

    private func salvar() async {
        testando = true
        falha = nil
        defer { testando = false }

        let candidatos = enderecosPossiveis
        for (indice, candidato) in candidatos.enumerated() {
            do {
                try await salvar(em: candidato)
                dismiss()
                return
            } catch let erro as URLError where indice < candidatos.count - 1 {
                LabLog.problem("conta: \(candidato) não conectou (\(erro.code.rawValue)), tentando o próximo")
            } catch {
                falha = error.localizedDescription
                return
            }
        }
    }

    private func salvar(em endereco: String) async throws {
        var nova = conta ?? ContaDeRede(tipo: tipo, nome: "", endereco: "", usuario: "")
        nova.endereco = endereco
        nova.usuario = usuario.trimmingCharacters(in: .whitespaces)
        nova.nome = nome.isEmpty ? nova.enderecoCurto : nome

        if tipo == .webdav {
            nova = try await testarWebDAV(nova)
            contas.salvar(nova, segredo: senha)
            return
        }
        // Editar só o apelido não pede a senha de novo; trocar o servidor ou o
        // usuário pede, porque o token antigo não vale lá.
        let mesmoAcesso = conta.map { $0.endereco == nova.endereco && $0.usuario == nova.usuario } ?? false
        if mesmoAcesso && senha.isEmpty {
            contas.salvar(nova, segredo: nil)
        } else {
            let acesso = try await ServidorDeMidia.entrar(tipo: tipo, endereco: nova.endereco,
                                                          usuario: nova.usuario, senha: senha)
            nova.idNoServidor = acesso.usuarioID
            contas.salvar(nova, segredo: acesso.token)
        }
    }

    /// Lista a pasta do endereço; se ele for só o servidor, tenta o caminho
    /// do Nextcloud antes de desistir.
    private func testarWebDAV(_ conta: ContaDeRede) async throws -> ContaDeRede {
        let cliente = WebDAV(conta: conta, senha: senha)
        do {
            _ = try await cliente.listar(cliente.raiz)
            return conta
        } catch {
            guard cliente.raiz == "/", !conta.usuario.isEmpty,
                  var partes = conta.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            else { throw error }
            partes.percentEncodedPath = "/remote.php/dav/files/\(WebDAV.escapar(conta.usuario))/"
            guard let url = partes.url else { throw error }

            var nextcloud = conta
            nextcloud.endereco = url.absoluteString
            let outro = WebDAV(conta: nextcloud, senha: senha)
            guard (try? await outro.listar(outro.raiz)) != nil else { throw error }
            return nextcloud
        }
    }
}

// MARK: - Navegação

/// Para onde uma pasta remota leva.
enum DestinoRemoto: Hashable {
    case webdav(ContaDeRede, caminho: String)
    case bibliotecas(ContaDeRede)
    case midia(ContaDeRede, ServidorDeMidia.Item)

    var conta: ContaDeRede {
        switch self {
        case .webdav(let conta, _), .bibliotecas(let conta), .midia(let conta, _): return conta
        }
    }

    /// Ponto de entrada de uma conta.
    static func inicio(_ conta: ContaDeRede) -> DestinoRemoto {
        conta.tipo == .webdav
            ? .webdav(conta, caminho: WebDAV(conta: conta, senha: nil).raiz)
            : .bibliotecas(conta)
    }
}

struct PastaRemota: Identifiable, Hashable {
    var id: String { "\(destino.hashValue)" }
    let nome: String
    let simbolo: String
    let destino: DestinoRemoto
    /// Jellyfin e Emby: a série, temporada ou coleção por trás — é o que
    /// ganha capa (ver `CapaDePastaDoServidor`) e o "Já reproduzido".
    var doServidor: ServidorDeMidia.Item? = nil
}

/// Uma pasta de WebDAV, ou uma biblioteca, série ou temporada de
/// Jellyfin/Emby — o mesmo desenho das pastas SMB.
struct PastaRemotaView: View {
    // Não privado: um campo privado tornaria privado o init gerado da view.
    var escala = Escala()

    let titulo: String
    let destino: DestinoRemoto

    @ObservedObject private var options = LibraryOptions.shared

    @State private var pastas: [PastaRemota] = []
    /// Criados uma vez por leitura: o player acha o vídeo na própria lista
    /// pela identidade, e recriar a cada desenho quebraria o "próximo".
    @State private var lidos: [MediaItem] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: MediaItem?
    @State private var mostrandoOpcoes = false
    /// Jellyfin e Emby: o item do servidor por trás de cada vídeo, pela
    /// chave da retomada — para o "Já reproduzido" ao segurar.
    @State private var doServidor: [String: ServidorDeMidia.Item] = [:]
    /// Biblioteca de filmes ou séries: ordem e filtros do servidor.
    @State private var filtro = ServidorDeMidia.Filtro()
    @State private var generos: [String] = []

    /// Só Jellyfin e Emby têm capas e "Já reproduzido"; o WebDAV fica como era.
    private var servidorDaPasta: ServidorDeMidia? {
        guard case .midia(let conta, _) = destino else { return nil }
        return servidor(conta)
    }

    /// Na ordem escolhida nas opções, como no SMB. Episódio se chama
    /// "3. Nome", e a ordem por título é natural — então a ordem padrão já é
    /// a da temporada.
    private var videos: [MediaItem] { bibliotecaFiltravel != nil ? lidos : options.sorted(lidos) }

    /// A biblioteca de filmes ou de séries, que o servidor sabe ordenar por
    /// nota, data e gênero — a ordem dela vem de lá, não das opções.
    private var bibliotecaFiltravel: ServidorDeMidia.Item? {
        guard case .midia(_, let pai) = destino,
              pai.tipoDeColecao == "movies" || pai.tipoDeColecao == "tvshows" else { return nil }
        return pai
    }

    var body: some View {
        if case .bibliotecas(let conta) = destino {
            // O começo de um Jellyfin ou Emby é a tela de faixas, que se
            // carrega sozinha; as bibliotecas estão nela.
            InicioDoServidorView(conta: conta)
                .navigationTitle(titulo)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            pasta
        }
    }

    private var pasta: some View {
        conteudo
            .navigationTitle(titulo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if bibliotecaFiltravel != nil {
                    ToolbarItem(placement: .topBarTrailing) { menuDeFiltro }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { mostrandoOpcoes = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .task(id: filtro) { await carregar() }
            .task {
                if let biblioteca = bibliotecaFiltravel, let servidor = servidorDaPasta {
                    generos = (try? await servidor.generos(biblioteca)) ?? []
                }
            }
            .sheet(isPresented: $mostrandoOpcoes) {
                LibraryOptionsSheet(options: options)
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
            ContentUnavailableView("Não conectou", systemImage: "wifi.exclamationmark",
                                   description: Text(failure))
        } else if pastas.isEmpty && videos.isEmpty {
            ContentUnavailableView("Nenhum vídeo nesta pasta", systemImage: "folder")
        } else if options.layout == .grid {
            grade
        } else {
            lista
        }
    }

    private var lista: some View {
        List {
            if !pastas.isEmpty {
                Section {
                    ForEach(pastas) { pasta in
                        NavigationLink {
                            destinoDaPasta(pasta)
                        } label: {
                            if let servidor = servidorDaPasta, let item = pasta.doServidor {
                                LinhaDePastaDoServidor(servidor: servidor, item: item)
                            } else {
                                LinhaDePastaDeRede(nome: pasta.nome, simbolo: pasta.simbolo, seta: false)
                            }
                        }
                        .linhaDeVidro()
                        .menuDoVistoSeHouver(servidorDaPasta, pasta.doServidor) { recarregar() }
                    }
                }
            }
            if !videos.isEmpty {
                Section {
                    ForEach(videos) { item in
                        abrir(item) { VideoRow(item: item) }
                            .linhaDeVidro()
                            .menuDoVistoSeHouver(servidorDaPasta, doServidor[item.origin.resumeKey]) { recarregar() }
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
                if let servidor = servidorDaPasta, pastas.contains(where: { $0.doServidor != nil }) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: escala.capa), spacing: 12, alignment: .top)], spacing: 14) {
                        ForEach(pastas) { pasta in
                            NavigationLink {
                                destinoDaPasta(pasta)
                            } label: {
                                if let item = pasta.doServidor {
                                    CapaDePastaDoServidor(servidor: servidor, item: item)
                                } else {
                                    LinhaDePastaDeRede(nome: pasta.nome, simbolo: pasta.simbolo)
                                }
                            }
                            .buttonStyle(.plain)
                            .menuDoVistoSeHouver(servidor, pasta.doServidor) { recarregar() }
                        }
                    }
                } else if !pastas.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(pastas) { pasta in
                            NavigationLink {
                                destinoDaPasta(pasta)
                            } label: {
                                LinhaDePastaDeRede(nome: pasta.nome, simbolo: pasta.simbolo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: escala.capa), spacing: 12, alignment: .top)], spacing: 14) {
                    ForEach(videos) { item in
                        abrir(item) { VideoCard(item: item) }
                            .menuDoVistoSeHouver(servidorDaPasta, doServidor[item.origin.resumeKey]) { recarregar() }
                    }
                }
            }
            .padding(16)
        }
        .fundoDaRede()
    }

    /// A série abre a página dela, com as temporadas em abas; o resto é pasta.
    @ViewBuilder
    private func destinoDaPasta(_ pasta: PastaRemota) -> some View {
        if let servidor = servidorDaPasta, let item = pasta.doServidor, item.tipo == "Series" {
            SerieDoServidorView(servidor: servidor, serieID: item.id, nome: item.nome)
                .onDisappear { recarregar() }
        } else {
            PastaRemotaView(titulo: pasta.nome, destino: pasta.destino)
        }
    }

    /// Ordem, não vistos, favoritos e gênero — os filtros do app do Jellyfin.
    private var menuDeFiltro: some View {
        Menu {
            Picker("Ordenar por", selection: $filtro.ordem) {
                ForEach(ServidorDeMidia.Filtro.Ordem.allCases, id: \.self) { ordem in
                    Text(nomeDaOrdem(ordem)).tag(ordem)
                }
            }
            Toggle("Decrescente", isOn: $filtro.decrescente)
            Divider()
            Toggle("Não vistos", isOn: $filtro.naoVistos)
            Toggle("Favoritos", isOn: $filtro.favoritos)
            if !generos.isEmpty {
                Picker("Gênero", selection: $filtro.genero) {
                    Text("Todos os gêneros").tag(String?.none)
                    ForEach(generos, id: \.self) { genero in
                        Text(verbatim: genero).tag(String?.some(genero))
                    }
                }
                .pickerStyle(.menu)
            }
            if filtro.ativo {
                Divider()
                Button("Limpar filtros", role: .destructive) { filtro = ServidorDeMidia.Filtro() }
            }
        } label: {
            Image(systemName: filtro.ativo ? "line.3.horizontal.decrease.circle.fill"
                                           : "line.3.horizontal.decrease.circle")
        }
    }

    private func nomeDaOrdem(_ ordem: ServidorDeMidia.Filtro.Ordem) -> LocalizedStringKey {
        switch ordem {
        case .nome:       return "Nome"
        case .adicionado: return "Adicionado em"
        case .lancamento: return "Lançamento"
        case .nota:       return "Nota"
        case .aleatorio:  return "Aleatório"
        }
    }

    /// Do Jellyfin e do Emby, o vídeo abre a página dele, com a sinopse e o
    /// "Assistir"; do WebDAV, que só tem o arquivo, toca direto.
    @ViewBuilder
    private func abrir<Rotulo: View>(_ item: MediaItem, @ViewBuilder rotulo: () -> Rotulo) -> some View {
        if let servidor = servidorDaPasta, let doServidor = doServidor[item.origin.resumeKey] {
            NavigationLink {
                DetalhesDoServidorView(servidor: servidor, inicial: doServidor)
                    .onDisappear { recarregar() }
            } label: { rotulo() }
            .buttonStyle(.plain)
        } else {
            Button { playing = item } label: { rotulo() }
                .buttonStyle(.plain)
        }
    }

    // MARK: - Leitura

    private func carregar() async {
        do {
            switch destino {
            case .webdav(let conta, let caminho):
                try await lerWebDAV(conta, caminho)
            case .bibliotecas(let conta):
                let itens = try await servidor(conta).bibliotecas()
                pastas = itens.map {
                    PastaRemota(nome: $0.nome, simbolo: simbolo(daColecao: $0.tipoDeColecao),
                                destino: .midia(conta, $0))
                }
            case .midia(let conta, let pai):
                let itens: [ServidorDeMidia.Item]
                if bibliotecaFiltravel != nil {
                    itens = try await servidor(conta).itens(de: pai, filtro: filtro)
                } else {
                    itens = try await servidor(conta).itens(de: pai)
                }
                pastas = itens.filter(\.ehPasta).map {
                    PastaRemota(nome: $0.titulo, simbolo: simbolo(doTipo: $0.tipo), destino: .midia(conta, $0),
                                doServidor: $0)
                }
                doServidor = Dictionary(
                    itens.filter(\.ehVideo).map { (MediaOrigin.midia(conta: conta.id, item: $0.id).resumeKey, $0) },
                    uniquingKeysWith: { primeiro, _ in primeiro })
                lidos = itens.filter(\.ehVideo)
                    .map {
                        MediaItem(title: $0.titulo, origin: .midia(conta: conta.id, item: $0.id),
                                  modifiedAt: $0.dataDeCriacao, duration: $0.duracao)
                    }
            }
        } catch where error.foiCancelado {
            return
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }

    /// Depois do "Já reproduzido": a pasta se relê por baixo, sem apagar a tela.
    private func recarregar() {
        Task { await carregar() }
    }

    private func lerWebDAV(_ conta: ContaDeRede, _ caminho: String) async throws {
        let cliente = WebDAV(conta: conta, senha: ContasDeRede.shared.segredo(conta))
        let entradas = try await cliente.listar(caminho)
        pastas = entradas.filter(\.ehPasta)
            .sorted { $0.nome.localizedStandardCompare($1.nome) == .orderedAscending }
            .map { PastaRemota(nome: $0.nome, simbolo: "folder.fill", destino: .webdav(conta, caminho: $0.caminho)) }
        lidos = entradas
            .filter { !$0.ehPasta && MediaItem.videoExtensions.contains(($0.nome as NSString).pathExtension.lowercased()) }
            .map {
                MediaItem(title: $0.nome, origin: .webdav(conta: conta.id, caminho: $0.caminho),
                          fileSize: $0.tamanho, modifiedAt: $0.modificado)
            }
    }

    private func servidor(_ conta: ContaDeRede) -> ServidorDeMidia {
        ServidorDeMidia(conta: conta, token: ContasDeRede.shared.segredo(conta))
    }

    private func simbolo(daColecao colecao: String?) -> String {
        switch colecao {
        case "movies":  return "film.fill"
        case "tvshows": return "tv.fill"
        default:        return "folder.fill"
        }
    }

    private func simbolo(doTipo tipo: String) -> String {
        switch tipo {
        case "Series":   return "tv.fill"
        case "Season":   return "square.stack.fill"
        case "BoxSet":   return "rectangle.stack.fill"
        default:         return "folder.fill"
        }
    }
}

private extension View {
    /// O "Já reproduzido" só onde há item do servidor por trás.
    @ViewBuilder
    func menuDoVistoSeHouver(_ servidor: ServidorDeMidia?, _ item: ServidorDeMidia.Item?,
                             aoMudar: @escaping () -> Void) -> some View {
        if let servidor, let item {
            menuDoVisto(servidor, item, aoMudar: aoMudar)
        } else {
            self
        }
    }
}

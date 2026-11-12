import UIKit
import AVFoundation
import VLCKit

/// Motor de reprodução sobre o VLCKit.
///
/// Substitui o motor próprio nas partes que se mostraram difíceis de acertar
/// do zero: sincronia entre som e imagem, buffer de rede e recuperação de
/// erro. São vinte anos de correções acumuladas contra alguns dias de código
/// meu — e o sintoma que mais atrapalhava, o vídeo do servidor travando,
/// vinha justamente daí.
///
/// Ganho secundário grande: o VLC fala SMB nativamente. Toda a ponte de
/// leitura por blocos, prazos e cache que eu tinha escrito vira uma URL
/// `smb://`.
@MainActor
final class VLCEngine: NSObject, PlaybackEngine {

    /// Criado depois de `prepararEventos`, que o VLC lê aqui, ao nascer.
    private let player: VLCMediaPlayer = {
        VLCEngine.prepararEventos()
        return VLCMediaPlayer()
    }()
    private let container = VLCRenderView()
    private var savedVolume: Float = 1.0

    /// Tamanho do arquivo, quando a listagem soube dizer. É o que permite
    /// traduzir "bytes lidos" em "segundos prontos".
    /// De onde vem o que está tocando — o tamanho do buffer depende disso.
    private var origemAtual: MediaOrigin?

    private var tamanhoDoArquivo: Int64?
    /// Quantos bytes já tinham sido lidos quando a posição atual começou.
    private var bytesNaBusca: (bytes: Int64, instante: Double)?

    /// Até onde o vídeo já está carregado, estimado pelo que o VLC leu.
    ///
    /// Não existe API que responda isso diretamente — o que há são as
    /// estatísticas de leitura. A conta é simples e a aproximação é honesta:
    /// a fração do arquivo lida desde a última busca vale, em segundos, a mesma
    /// fração da duração. Erra em vídeo de taxa muito variável, e para uma
    /// barra de progresso isso não tem importância.
    var bufferedTime: Double {
        guard let tamanho = tamanhoDoArquivo, tamanho > 0, duration > 0 else { return 0 }
        let lidos = Int64(player.media?.statistics.demuxReadBytes ?? 0)
        guard lidos > 0 else { return 0 }

        let referencia = bytesNaBusca ?? (bytes: 0, instante: 0)
        let desde = max(0, lidos - referencia.bytes)
        let segundos = Double(desde) / Double(tamanho) * duration
        return min(duration, referencia.instante + segundos)
    }

    /// Depois de buscar, a contagem recomeça: o que estava em memória era de
    /// outro trecho do arquivo.
    private func marcarBusca(em instante: Double) {
        let lidos = Int64(player.media?.statistics.demuxReadBytes ?? 0)
        bytesNaBusca = (bytes: lidos, instante: instante)
    }
    /// Avisa a interface só na mudança.
    ///
    /// Emitir a cada atualização de tempo fazia o transporte piscar; emitir só
    /// quando o VLC anuncia "tocando" deixava o indicador aceso para sempre,
    /// porque ele emite "carregando" durante a reprodução normal e nem sempre
    /// volta a anunciar. Reagir à transição resolve os dois.
    private var buffering = false {
        didSet {
            guard buffering != oldValue else { return }
            onBufferingChange?(buffering)
        }
    }

    private var pendingScrub: Double?
    private var scrubWork: DispatchWorkItem?
    private var lastScrubApplied: CFTimeInterval = 0

    /// O último destino pedido ao arrastar — não é apagado quando aplicado,
    /// para o fim do arrasto sempre ter a palavra final.
    private var alvoDaRolagem: Double?
    /// Enquanto o dedo arrasta, o tempo que o VLC informa não vai para a tela.
    private var emRolagem = false
    /// O VLC chegou ao fim com o dedo ainda arrastando. Quem decide o que isso
    /// significa é o ponto onde o dedo for solto.
    private var terminouNaRolagem = false

    /// Destino de uma busca que o VLC ainda não alcançou.
    ///
    /// Enquanto uma busca não termina, o VLC continua respondendo o tempo
    /// **antigo** — em rede, por um ou dois segundos. Era a causa do "às vezes
    /// não volta": solta-se o dedo lá atrás, o VLC ainda diz o ponto de antes,
    /// a barra pula de volta para ele, e um segundo arrasto nesse intervalo
    /// partia do lugar errado. Até o VLC chegar, quem responde é o destino.
    private var alvoPendente: (tempo: Double, desde: CFTimeInterval, tentativas: Int)?

    /// Permissão de leitura do arquivo, mantida enquanto a reprodução durar.
    ///
    /// No iOS quem autoriza é a pasta escolhida no seletor, e o acesso só vale
    /// com o escopo aberto. Sem isto o VLC recebe o caminho e não consegue ler
    /// — o contêiner é reconhecido, mas nenhuma faixa aparece, que é o sintoma
    /// exato de leitura barrada disfarçada de arquivo inválido.
    private var access: ScopedAccess?

    /// Quem escolheu a legenda no menu manda nela até o vídeo trocar.
    private var legendaDoUsuario = false
    private var origemDaLegenda: MediaOrigin?

    /// O áudio e a legenda escolhidos na página do servidor (ver
    /// `EscolhaDeFaixas`), à espera de as faixas aparecerem.
    private var pedidoDeFaixas: EscolhaDeFaixas.Pedido?
    /// As legendas que já vinham no arquivo — as que existiam antes da
    /// primeira de fora entrar. As de fora chegam depois, na ordem em que
    /// foram acrescentadas, com o nome de cada uma aqui.
    private var idsInternos: Set<Int32>?
    private var legendasDeFora: [String] = []

    /// Se o vídeo chegou a tocar: o VLC 4 anuncia o fim como "parou", e só
    /// parar depois de ter tocado é o fim de verdade.
    private var tocou = false

    /// A janela flutuante, quando o VLC a deixa pronta para abrir.
    fileprivate var janela: VLCPictureInPictureWindowControlling?
    fileprivate(set) var janelaAberta = false
    var onJanelaPronta: ((Bool) -> Void)?
    var onJanela: ((Bool) -> Void)?

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onTimeUpdate: ((Double) -> Void)?
    var onStateChange: ((PlaybackState) -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    /// Nunca chamado: o VLC desenha a legenda dentro do próprio vídeo, então
    /// não há texto para a interface exibir por fora.
    var onSubtitle: ((String?) -> Void)?

    // MARK: - Estado básico

    var currentTime: Double {
        if let alvo = alvoPendente { return alvo.tempo }
        return tempoDoVLC
    }

    private var tempoDoVLC: Double { Double(player.time.intValue) / 1000 }

    /// Toda ida a um ponto passa por aqui, para o destino ficar registrado.
    private func irPara(_ alvo: Double) {
        LabLog.passo("buscar: \(String(format: "%.1f", tempoDoVLC)) s → \(String(format: "%.1f", alvo)) s (duração \(String(format: "%.0f", duration)) s)")
        player.time = VLCTime(int: Int32(alvo * 1000))
        alvoPendente = (alvo, CACurrentMediaTime(), 0)
    }

    /// A duração, só depois de o vídeo começar a tocar.
    ///
    /// Lida antes de o VLC abrir o arquivo, ela vem zero — e o VLCKit 4 até a
    /// 4.0.0a25 guardava esse zero para sempre: a barra não andava e a busca
    /// se recusava a sair do lugar. Antes de tocar não há o que dizer; e se
    /// ainda assim vier zero, a conta pelo tempo e pela fração já andada serve.
    var duration: Double {
        guard tocou else { return 0 }
        let ms = player.media?.length.intValue ?? 0
        if ms > 0 { return Double(ms) / 1000 }
        let fracao = player.position
        let tempo = tempoDoVLC
        return fracao > 0.0005 && tempo > 0 ? tempo / fracao : 0
    }

    var rate: Float {
        get { player.rate }
        set {
            LabLog.passo("velocidade: \(player.rate)× → \(newValue)×")
            player.rate = newValue
        }
    }

    /// O VLC trabalha com 0–200; acima de 100 é ganho além do original.
    var volume: Float {
        get { savedVolume }
        set {
            savedVolume = max(0, min(1, newValue))
            player.audio?.volume = Int32(savedVolume * 100)
        }
    }

    var isMuted: Bool {
        get { player.audio?.isMuted ?? false }
        set { player.audio?.isMuted = newValue }
    }

    /// Os avisos do VLC (tocando, pausado, o tempo andando) na fila principal.
    ///
    /// O VLC 3 já os entregava ali; o 4, por padrão, os entrega na linha
    /// interna dele. Cada aviso mexe na tela — o botão de play, a barra do
    /// tempo —, e mexer na tela fora da fila principal fecha o app. Era o que
    /// acontecia ao voltar da janela flutuante e pausar. O VLC lê esta
    /// escolha ao criar cada player, então ela vem antes do primeiro.
    static func prepararEventos() {
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()
    }

    override init() {
        super.init()
        player.delegate = self
        // O próprio motor é a "tela" do VLC: ele repassa a imagem à view e,
        // sendo também quem toca e pausa, é o que a janela flutuante comanda.
        player.drawable = self
        container.attach(player)
        aplicarTamanhoDaLegenda()

        let centro = NotificationCenter.default
        centro.addObserver(self, selector: #selector(foiParaSegundoPlano),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        centro.addObserver(self, selector: #selector(voltouDoSegundoPlano),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Tela apagada

    /// A imagem foi desligada ao sair da tela, e volta ao entrar.
    private var imagemDesligada = false

    /// Tela apagada (ou outro app na frente) com o filme tocando: o som segue
    /// — a sessão de áudio e os controles da tela bloqueada já cuidam disso —,
    /// mas a imagem para de ser decodificada. Decodificar vídeo para uma tela
    /// que ninguém vê só gastaria bateria. É o que o próprio VLC do iPhone faz.
    ///
    /// Com a janela flutuante a imagem continua sendo vista, e é o caso comum:
    /// o VLC 4 abre a janela sozinho quando se sai do app com o filme tocando.
    /// Só que o iOS avisa "foi para o segundo plano" **antes** de a janela
    /// terminar de abrir — desligar a imagem ali mataria a janela no nascer.
    /// Por isso a decisão espera um instante e olha de novo.
    @objc private func foiParaSegundoPlano() {
        guard player.isPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, UIApplication.shared.applicationState == .background,
                  self.player.isPlaying, !self.janelaAberta,
                  self.player.videoTracks.contains(where: \.isSelected) else { return }
            LabLog.passo("segundo plano sem janela flutuante: imagem desligada")
            self.player.deselectAllVideoTracks()
            self.imagemDesligada = true
        }
    }

    @objc private func voltouDoSegundoPlano() {
        guard imagemDesligada else { return }
        imagemDesligada = false
        // Se na tela bloqueada o filme trocou pelo "próximo", o novo já abriu
        // com imagem: religar por cima reiniciaria o decodificador à toa.
        guard !player.videoTracks.contains(where: \.isSelected), !player.videoTracks.isEmpty else { return }
        player.selectTrack(at: 0, type: .video)
        // Pausado na tela bloqueada, nenhum quadro novo viria até o play, e a
        // tela ficaria preta: buscar o ponto onde está faz o VLC desenhar um.
        if !player.isPlaying {
            player.time = player.time
        }
    }

    // MARK: - Carga

    func load(_ item: MediaItem) async throws {
        state = .loading
        // Outro vídeo: a escolha de legenda do anterior não vale para ele.
        if item.origin != origemDaLegenda {
            legendaDoUsuario = false
            origemDaLegenda = item.origin
        }
        pedidoDeFaixas = EscolhaDeFaixas.shared.consumir(item.origin.resumeKey)
        idsInternos = nil
        legendasDeFora = []

        // Abre o escopo ANTES de entregar o caminho ao VLC, e o mantém: ele lê
        // o arquivo durante todo o filme, não só na abertura.
        if case .file(let fileURL, let bookmark) = item.origin {
            access = ScopedAccess(url: fileURL, bookmark: bookmark)
            guard access?.path != nil else { throw PlaybackError.securityScopeDenied }
        } else {
            access = nil
        }

        guard let url = try await Self.resolveURL(for: item.origin) else {
            throw PlaybackError.unsupportedOrigin
        }

        // No VLC 4 a mídia pode não nascer (URL que ele não aceita).
        guard let media = VLCMedia(url: url) else { throw PlaybackError.unsupportedOrigin }
        Self.credenciais(para: item.origin).forEach(media.addOption)
        Self.configurarBuffer(media, origem: item.origin)
        tamanhoDoArquivo = item.fileSize
        bytesNaBusca = nil
        origemAtual = item.origin

        // Trocar de mídia para a anterior, e esse "parou" não é o fim do vídeo.
        tocou = false
        LabLog.passo("carregar: \(Self.tipo(item.origin)) · \(item.title)")
        player.media = media
        state = .ready
        LabLog.open("VLC pronto: \(item.title)")
    }

    /// Quanto o VLC guarda adiantado antes de precisar: a folga que absorve
    /// uma engasgada da rede sem a imagem parar. Maior engasga menos, mas
    /// atrasa a imagem depois de cada busca e a troca de velocidade.
    private static func configurarBuffer(_ media: VLCMedia, origem: MediaOrigin) {
        switch origem {
        case .smb, .remote, .webdav, .midia:
            // 0,7 s — perto do meio segundo do arquivo no aparelho.
            //
            // É quanto o VLC junta antes de mostrar imagem, no começo e depois
            // de cada busca, e no VLC 4 é também quanto de som fica entregue à
            // saída do iPhone. A velocidade nova só vale depois que esse som
            // toca: com 1,5 s (o número do VLC 3), segurar para acelerar
            // atrasava — e um toque curto nem acelerava — só na rede.
            //
            // O prefetch do VLC 3 não entra: no VLC 4 ele só é carregado quando
            // pedido pelo nome, e uma das opções saiu da versão.
            media.addOption(":network-caching=700")

        case .file:
            media.addOption(":file-caching=500")
        }
    }

    /// Monta a URL que o VLC entende.
    ///
    /// No caso do SMB, as credenciais vão embutidas — é como o VLC as recebe.
    /// Elas continuam vindo do Keychain e nunca são gravadas em disco assim.
    static func resolveURL(for origin: MediaOrigin) async throws -> URL? {
        switch origin {
        case .file(let url, _):
            return url

        case .remote(let url):
            return url

        case .smb(let referencia, let caminho):
            guard let servidor = SMBServerStore.shared.servers.first(where: { $0.id == referencia.serverID }) else {
                throw PlaybackError.loadFailed(String(localized: "servidor não encontrado"))
            }
            // Só endereço e caminho: as credenciais vão por opção do media.
            let partes = caminho.split(separator: "/").map { escape(String($0)) }.joined(separator: "/")
            let texto = "smb://\(servidor.host)/\(escape(referencia.share))/\(partes)"
            return URL(string: texto)

        case .webdav(let id, let caminho):
            guard let conta = ContasDeRede.shared.conta(id) else {
                throw PlaybackError.loadFailed(String(localized: "servidor não encontrado"))
            }
            return try await WebDAV(conta: conta, senha: ContasDeRede.shared.segredo(conta)).urlDeReproducao(caminho)

        case .midia(let id, let item):
            guard let conta = ContasDeRede.shared.conta(id) else {
                throw PlaybackError.loadFailed(String(localized: "servidor não encontrado"))
            }
            let servidor = ServidorDeMidia(conta: conta, token: ContasDeRede.shared.segredo(conta))
            // Canal de TV ao vivo: o servidor já abriu e mandou a lista HLS.
            if let canal = Conversoes.shared.canal(item) {
                return try await PonteHTTP.shared.endereco(paraLista: canal, cabecalhos: servidor.cabecalhoDoToken)
            }
            // A qualidade escolhida para a conta: abaixo do original, o
            // servidor converte e manda uma lista HLS (ver Qualidade).
            let kbps = Qualidade.da(conta.id)
            if kbps > 0 {
                let sessao = Conversoes.shared.comecar(item)
                guard let url = servidor.urlDaConversao(item, kbps: kbps, sessao: sessao,
                                                        audio: Conversoes.shared.audio(item)) else { return nil }
                return try await PonteHTTP.shared.endereco(paraLista: url, cabecalhos: servidor.cabecalhoDoToken)
            }
            Conversoes.shared.encerrar(item)
            // Pela ponte também: o VLC do iPhone não fala TLS 1.3 (ver PonteHTTP).
            guard let url = servidor.urlDoVideo(item) else { return nil }
            return try await PonteHTTP.shared.endereco(para: url, nome: "video")
        }
    }

    /// Credenciais do SMB, do jeito que o libsmb2 as recebe.
    ///
    /// Antes elas iam embutidas na URL — `smb://usuario:senha@servidor` —, que é
    /// o jeito óbvio e está errado: o VLC aceita a URL, avisa no log que senha
    /// em URI está obsoleta e **segue sem ela**. A conexão chega ao servidor
    /// como anônima.
    ///
    /// O sintoma aponta para todo lugar menos para a causa: no servidor não
    /// aparece falha de autenticação nenhuma, porque o usuário nunca foi
    /// enviado — o que faz parecer problema de rede ou de digitação. Foi
    /// descoberto no irmão Android e vale igual aqui, porque a biblioteca por
    /// baixo é a mesma.
    ///
    /// De quebra some uma classe inteira de defeito: senha com `@`, `/`, `:` ou
    /// acento não precisa mais sobreviver a uma codificação de URL.
    static func credenciais(para origem: MediaOrigin) -> [String] {
        guard case .smb(let referencia, _) = origem,
              let servidor = SMBServerStore.shared.servers.first(where: { $0.id == referencia.serverID }),
              !servidor.isGuest else { return [] }

        var opcoes = [":smb-user=\(servidor.username)"]
        if let senha = SMBServerStore.shared.password(for: servidor), !senha.isEmpty {
            opcoes.append(":smb-pwd=\(senha)")
        }
        // O grupo de trabalho padrão do Samba. Sem ele o libsmb2 manda domínio
        // vazio, e há servidor que recusa por isso.
        opcoes.append(":smb-domain=WORKGROUP")
        return opcoes
    }

    private static func escape(_ texto: String) -> String {
        texto.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? texto
    }

    // MARK: - Transporte

    func play() {
        player.play()
        if state != .playing { state = .playing }
    }

    func pause() {
        // `pause()` do VLC alterna; chamar com o vídeo já parado voltaria a
        // tocar, que é como se perde uma pausa.
        if player.isPlaying { player.pause() }
        state = .paused
    }

    func seek(to time: Double, precise: Bool) async {
        guard duration > 0 else { return }
        let alvo = max(0, min(time, duration))
        if chegaAoFim(alvo) { encerrarPelaBusca(); return }
        // Sem acender a roda: o VLC busca rápido, e o pisca-pisca do indicador
        // incomodava mais do que a espera que ele anunciava.
        irPara(alvo)
        marcarBusca(em: alvo)
        onTimeUpdate?(alvo)
    }

    // MARK: - Rolagem

    func beginScrub() {
        emRolagem = true
        terminouNaRolagem = false
        alvoDaRolagem = nil
    }

    // MARK: - Fim pela barra

    /// Folga antes do fim que já conta como "fim".
    ///
    /// Mandar o VLC ao último instante exato não é confiável: às vezes ele
    /// encerra, às vezes fica parado no último quadro sem nunca anunciar o fim,
    /// e a barra e os controles ficavam presos ali. Puxar a barra até o fim é
    /// pedir o mesmo que o vídeo acabar, então o player trata como fim de
    /// verdade, sem depender de o VLC chegar lá.
    private var folgaDoFim: Double { min(1.0, duration / 10) }

    private func chegaAoFim(_ alvo: Double) -> Bool {
        duration > 0 && alvo >= duration - folgaDoFim
    }

    /// Durante o arrasto o VLC não é levado à folga final: com o dedo parado ali
    /// ele terminaria o filme antes de o dedo ser solto, e o player passaria
    /// para o próximo vídeo no meio do gesto.
    private var limiteDaRolagem: Double { max(duration * 0.8, duration - folgaDoFim - 2) }

    private func encerrarPelaBusca() {
        alvoPendente = nil
        onTimeUpdate?(duration)
        state = .ended
    }

    /// Rolagem com ritmo controlado.
    ///
    /// O dedo gera dezenas de eventos por segundo; mandar cada um para o VLC
    /// faz ele abortar e reiniciar a busca sem parar, e a imagem trava em vez
    /// de acompanhar. Aplicando no máximo a cada 80 ms, cada busca tem tempo de
    /// mostrar o quadro antes da próxima — o movimento fica contínuo.
    func scrub(to time: Double) {
        guard duration > 0 else { return }
        let alvo = max(0, min(time, duration))
        pendingScrub = alvo
        alvoDaRolagem = alvo
        onTimeUpdate?(alvo)

        let agora = CACurrentMediaTime()
        guard agora - lastScrubApplied >= cadenciaDeRolagem else {
            agendarScrubPendente()
            return
        }
        aplicarScrub(alvo, em: agora)
    }

    private func aplicarScrub(_ alvo: Double, em instante: CFTimeInterval) {
        lastScrubApplied = instante
        pendingScrub = nil
        guard !terminouNaRolagem else { return }
        irPara(min(alvo, limiteDaRolagem))
    }

    /// Garante que o último ponto arrastado seja aplicado mesmo que o dedo
    /// pare — senão a imagem ficaria num ponto anterior ao que a barra mostra.
    private func agendarScrubPendente() {
        guard scrubWork == nil else { return }
        let trabalho = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrubWork = nil
            if let alvo = self.pendingScrub {
                self.aplicarScrub(alvo, em: CACurrentMediaTime())
            }
        }
        scrubWork = trabalho
        DispatchQueue.main.asyncAfter(deadline: .now() + cadenciaDeRolagem, execute: trabalho)
    }

    /// Intervalo mínimo entre buscas durante o arrasto.
    ///
    /// No arquivo local, 80 ms: o disco responde a tempo de mostrar o quadro
    /// antes da busca seguinte. No servidor não — cada busca descarta o buffer
    /// e pede um bloco novo pela rede, e com buscas a cada 80 ms nenhuma chega
    /// a terminar: o VLC aborta uma para começar a outra e a imagem congela até
    /// o dedo parar. A 300 ms cada uma tem chance de mostrar algo.
    private var cadenciaDeRolagem: CFTimeInterval {
        switch origemAtual {
        case .smb, .remote, .webdav, .midia: return 0.3
        default:            return 0.08
        }
    }

    /// Ao soltar o dedo, vai exatamente ao último ponto pedido.
    ///
    /// Sempre, e não só quando havia algo agendado: a busca que já tinha saído
    /// pode ter sido abortada pela seguinte, e sem repetir aqui o vídeo
    /// ficaria num ponto intermediário do caminho do dedo.
    func endScrub() {
        scrubWork?.cancel()
        scrubWork = nil
        pendingScrub = nil
        emRolagem = false
        let terminou = terminouNaRolagem
        terminouNaRolagem = false
        guard let alvo = alvoDaRolagem else {
            if terminou { encerrarPelaBusca() }
            return
        }
        alvoDaRolagem = nil
        lastScrubApplied = CACurrentMediaTime()
        if chegaAoFim(alvo) { encerrarPelaBusca(); return }
        // O VLC terminou durante o arrasto, mas o dedo voltou antes de soltar:
        // depois do fim ele não busca mais, então precisa voltar a tocar
        // primeiro. Se a busca se perder na abertura, `alvoPendente` repete.
        if terminou { player.play() }
        irPara(alvo)
        marcarBusca(em: alvo)
        onTimeUpdate?(alvo)
    }

    // MARK: - Faixas

    // No VLC 4 cada faixa é um objeto, e a lista não traz mais a entrada
    // "Desativado": o número da faixa aqui é a posição dela na lista.

    var audioTracks: [MediaTrack] { Self.faixas(player.audioTracks) }

    var subtitleTracks: [MediaTrack] { Self.faixas(player.textTracks) }

    var currentAudioTrack: Int32? {
        player.audioTracks.firstIndex(where: \.isSelected).map(Int32.init)
    }

    var currentSubtitleTrack: Int32? {
        player.textTracks.firstIndex(where: \.isSelected).map(Int32.init)
    }

    func selectAudioTrack(_ id: Int32) async {
        escolherAudio(id)
        await recomecarDoPonto()
    }

    private func escolherAudio(_ id: Int32) {
        guard id >= 0, Int(id) < player.audioTracks.count else { return }
        player.selectTrack(at: Int(id), type: .audio)
    }

    /// `nil` ou -1: sem legenda.
    private func escolherLegenda(_ id: Int32?) {
        if let id, id >= 0, Int(id) < player.textTracks.count {
            player.selectTrack(at: Int(id), type: .text)
        } else {
            player.deselectAllTextTracks()
        }
    }

    /// Descarta o que já estava no buffer e recomeça do ponto atual.
    ///
    /// Trocar a faixa de áudio troca o decodificador, mas **não** joga fora o
    /// que já foi lido: o VLC continua consumindo o buffer antigo, montado com
    /// a faixa anterior, e o áudio novo só aparece quando esse buffer acaba.
    /// Em rede isso são os cinco segundos de `network-caching` — a mesma folga
    /// que deixa a rolagem suave cobra o preço aqui.
    ///
    /// Uma busca de volta de um décimo de segundo força o descarte. O ponto é
    /// praticamente o mesmo, e no servidor ela sai de graça: está muito dentro
    /// do bloco que já está em memória, então não há ida à rede.
    ///
    /// Só em rede. No arquivo local o buffer é de meio segundo, a troca já é
    /// imediata, e a busca só acrescentaria um solavanco sem motivo.
    private func recomecarDoPonto() async {
        switch origemAtual {
        case .smb, .remote, .webdav, .midia:
            await seek(to: max(0, currentTime - 0.12), precise: false)
        default:
            break
        }
    }

    func selectSubtitleTrack(_ id: Int32?) async {
        legendaDoUsuario = true
        escolherLegenda(id)
    }

    /// Ao abrir, só a legenda **forçada** fica ligada — a que traduz a placa,
    /// a carta ou o idioma estrangeiro no meio do filme. A completa vem
    /// desligada: o VLC liga a que o arquivo marca como padrão, e quase sempre
    /// ela está no mesmo idioma do áudio, repetindo o que já se ouve.
    ///
    /// O VLCKit não diz se a faixa é forçada; o nome diz — é como os
    /// arquivos a marcam ("Forced", "Forçada", "Forzados"). Quem escolhe no
    /// menu manda até o vídeo trocar.
    fileprivate func aplicarRegraDaLegenda() {
        guard !legendaDoUsuario, pedidoDeFaixas?.legenda == nil else { return }
        let forcada = subtitleTracks.first { faixa in
            (faixa.title ?? "").range(of: Self.forcada, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let alvo = forcada?.id
        if currentSubtitleTrack != alvo { escolherLegenda(alvo) }
    }

    /// Aplica o que foi escolhido na página do servidor assim que a faixa
    /// pedida existe. As de dentro do arquivo aparecem ao abrir; a legenda de
    /// fora, só depois de baixada — por isso isto roda a cada faixa nova.
    fileprivate func aplicarPedidoDeFaixas() {
        guard var pedido = pedidoDeFaixas else { return }
        if let posicao = pedido.audio {
            let faixas = audioTracks
            if posicao < faixas.count {
                if currentAudioTrack != faixas[posicao].id {
                    escolherAudio(faixas[posicao].id)
                    if state == .playing { Task { await recomecarDoPonto() } }
                }
                pedido.audio = nil
            }
        }
        if let legenda = pedido.legenda {
            let internas = subtitleTracks.filter { idsInternos?.contains($0.id) ?? true }
            let deFora = subtitleTracks.filter { !(idsInternos?.contains($0.id) ?? true) }
            var alvo: Int32?
            switch legenda {
            case .desligada:
                alvo = -1
            case .interna(let posicao):
                if posicao < internas.count { alvo = internas[posicao].id }
            case .externa(let indice):
                if let ordem = legendasDeFora.firstIndex(where: { $0.contains("(\(indice)).") }),
                   ordem < deFora.count {
                    alvo = deFora[ordem].id
                }
            }
            if let alvo {
                legendaDoUsuario = true
                if (currentSubtitleTrack ?? -1) != alvo { escolherLegenda(alvo) }
                pedido.legenda = nil
            }
        }
        pedidoDeFaixas = pedido.audio == nil && pedido.legenda == nil ? nil : pedido
    }

    /// O tamanho do texto da legenda, na hora, com o filme tocando.
    ///
    /// No VLC 3 isso só era lido quando o motor nascia, e mudar o tamanho era
    /// refazer o reprodutor no mesmo ponto — o filme piscava e as legendas de
    /// fora voltavam a ser baixadas. O VLC 4 muda o texto já na tela.
    func aplicarTamanhoDaLegenda() {
        player.currentSubTitleFontScale = TamanhoDaLegenda.escala
    }

    /// "Forced", "Forçada(s)", "Forzado(s)", "Forcée(s)" — palavra inteira.
    private static let forcada = #"(^|[^\p{L}])(forced|for[çcz]ad[oa]s?|forcée?s?)([^\p{L}]|$)"#

    private static func faixas(_ lista: [VLCMediaPlayer.Track]) -> [MediaTrack] {
        lista.enumerated().map { indice, faixa in
            MediaTrack(id: Int32(indice), codec: "", language: nil, title: faixa.trackName)
        }
    }

    // MARK: - Captura

    func snapshot() -> UIImage? {
        // O VLC desenha por aceleração de hardware, então capturar a hierarquia
        // de views devolveria um retângulo preto. `drawHierarchy` é o caminho
        // que enxerga o conteúdo já composto na tela.
        let renderer = UIGraphicsImageRenderer(bounds: container.bounds)
        let imagem = renderer.image { _ in
            container.drawHierarchy(in: container.bounds, afterScreenUpdates: false)
        }
        return imagem.size.width > 0 ? imagem : nil
    }

    func makeRenderView() -> UIView { container }

    func teardown() {
        janela?.stopPictureInPicture()
        janela = nil
        player.stop()
        player.delegate = nil
        // O VLC guarda a "tela" com referência forte, e a tela é este motor.
        player.drawable = nil
        // Solta a permissão só depois de parar: fechar antes deixaria o VLC
        // lendo um arquivo que ele já não pode mais acessar.
        access = nil
        state = .idle
    }
}

// MARK: - Estado vindo do VLC

extension VLCEngine: VLCMediaPlayerDelegate {

    func mediaPlayerStateChanged(_ novo: VLCMediaPlayerState) {
        LabLog.passo("VLC estado: \(Self.nome(novo)) (tempo \(String(format: "%.1f", tempoDoVLC)) s)")
        // A janela flutuante mostra play ou pausa conforme o estado.
        janela?.invalidatePlaybackState()
        switch novo {
        case .opening:   state = .loading
        case .playing:
            tocou = true
            buffering = false
            // O objeto de áudio do VLC só existe depois que a saída sobe;
            // reaplicar aqui garante que o ganho interno fique em 100% e o
            // volume que vale seja o do aparelho.
            player.audio?.volume = Int32(savedVolume * 100)
            aplicarTamanhoDaLegenda()
            aplicarPedidoDeFaixas()
            aplicarRegraDaLegenda()
            state = .playing
        case .paused:    state = .paused
        // O VLC 4 não tem mais o estado "terminou": ao chegar ao fim ele
        // para. Parar depois de ter tocado, sem ninguém ter mandado, é o fim.
        case .stopped:
            if tocou {
                tocou = false
                if emRolagem { terminouNaRolagem = true } else { state = .ended }
            } else {
                state = .idle
            }
        case .error:     state = .failed(String(localized: "o VLC não conseguiu abrir este arquivo"))
        default:         break
        }
    }

    func mediaPlayerBufferingChanged(_ progresso: Float) {
        buffering = progresso < 1
    }

    func mediaPlayerLengthChanged(_ length: Int64) {
        janela?.invalidatePlaybackState()
    }

    /// As faixas chegam aos poucos (a legenda ao lado do arquivo, por
    /// último), e o VLC liga a padrão por conta própria: a regra vale de novo.
    func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        aplicarPedidoDeFaixas()
        if trackType == .text { aplicarRegraDaLegenda() }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        // Tempo andando é a prova de que não está carregando — mais confiável
        // que o estado que o VLC anuncia. Como só emite na transição, isto não
        // volta a fazer o transporte piscar.
        buffering = false

        if let pendente = alvoPendente {
            if abs(tempoDoVLC - pendente.tempo) < 3 {
                alvoPendente = nil
            } else {
                // Não chegou. Em rede a busca demora mais para assentar; passado
                // o prazo, pede de novo uma vez — busca abortada no meio de uma
                // rajada é o caso comum — e, se ainda assim não chegar, aceita
                // onde o VLC está, para a tela não mentir para sempre.
                let prazo: CFTimeInterval
                switch origemAtual {
                case .smb, .remote, .webdav, .midia: prazo = 2.5
                default:            prazo = 1.2
                }
                if CACurrentMediaTime() - pendente.desde > prazo {
                    if pendente.tentativas == 0 {
                        player.time = VLCTime(int: Int32(pendente.tempo * 1000))
                        alvoPendente = (pendente.tempo, CACurrentMediaTime(), 1)
                    } else {
                        alvoPendente = nil
                    }
                }
                if alvoPendente != nil { return }
            }
        }

        // Com o dedo na barra, quem manda na tela é o dedo. O tempo do VLC
        // pula de quadro-chave em quadro-chave e brigava com o destino
        // arrastado — a barra e o número tremiam entre os dois.
        guard !emRolagem else { return }
        onTimeUpdate?(tempoDoVLC)
    }
}

/// Superfície de desenho do VLC.
///
/// O enquadramento é do próprio VLC (`videoAspectRatio` / `scaleFactor`), e não
/// de uma layer nossa — por isso esta view é praticamente vazia.
final class VLCRenderView: UIView, VideoGravityAdjustable {

    private weak var player: VLCMediaPlayer?

    init(player: VLCMediaPlayer? = nil) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    func attach(_ player: VLCMediaPlayer) { self.player = player }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        guard let player else { return }
        switch gravity {
        case .resizeAspectFill:
            // Preencher cortando: o VLC faz isso ampliando a imagem.
            player.scaleFactor = 0
            player.videoAspectRatio = nil
            player.scaleFactor = 1.4
        case .resize:
            player.scaleFactor = 0
            player.videoAspectRatio = "16:9"
        default:
            player.scaleFactor = 0
            player.videoAspectRatio = nil
        }
    }
}

extension VLCEngine: MudaTamanhoDaLegenda {}

// MARK: - Janela flutuante

/// O VLC 4 desenha dentro de quem for o `drawable` e, quando esse alguém
/// também sabe tocar e pausar, monta sozinho a janela flutuante do iOS sobre
/// a mesma imagem — é como o app do VLC para iPhone faz. O motor faz os dois
/// papéis: repassa a imagem à view e responde aos botões da janela.
///
/// Sair do app com o filme tocando abre a janela sozinho (o VLC liga o
/// "começar automaticamente" do iOS); o botão abre e fecha à mão.
extension VLCEngine: VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling,
                     ComJanelaFlutuante {

    func addSubview(_ view: UIView!) {
        // A imagem volta da janela flutuante para cá; mexer na tela, só na
        // fila principal.
        naFilaPrincipal { [container] in
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
        }
    }

    func bounds() -> CGRect { container.bounds }

    func mediaController() -> VLCPictureInPictureMediaControlling! { self }

    func pictureInPictureReady() -> ((VLCPictureInPictureWindowControlling?) -> Void)! {
        { [weak self] janela in
            guard let self else { return }
            naFilaPrincipal {
                self.janela = janela
                janela?.stateChangeEventHandler = { [weak self] aberta in
                    naFilaPrincipal {
                        guard let self else { return }
                        LabLog.passo("janela flutuante: \(aberta ? "aberta" : "fechada")")
                        self.janelaAberta = aberta
                        self.onJanela?(aberta)
                    }
                }
                self.onJanelaPronta?(janela != nil)
            }
        }
    }

    func seek(by offset: Int64, completion: (() -> Void)!) {
        _ = player.jump(withOffset: Int32(offset), completion: completion)
    }

    func mediaLength() -> Int64 { Int64(player.media?.length.intValue ?? 0) }

    func mediaTime() -> Int64 { Int64(player.time.intValue) }

    func isMediaSeekable() -> Bool { player.isSeekable }

    func isMediaPlaying() -> Bool { player.isPlaying }

    func alternarJanela() {
        if janelaAberta { janela?.stopPictureInPicture() } else { janela?.startPictureInPicture() }
    }
}

/// Roda já, se estiver na fila principal; senão, manda para ela.
private func naFilaPrincipal(_ trabalho: @escaping () -> Void) {
    if Thread.isMainThread { trabalho() } else { DispatchQueue.main.async(execute: trabalho) }
}

extension VLCEngine: AceitaLegendaDeFora {
    func adicionarLegenda(_ arquivo: URL) {
        if idsInternos == nil { idsInternos = Set(subtitleTracks.map(\.id)) }
        legendasDeFora.append(arquivo.lastPathComponent)
        _ = player.addPlaybackSlave(arquivo, type: .subtitle, enforce: false)
    }
}

extension VLCEngine: AtrasaLegenda {
    var atrasoDaLegenda: Double {
        get { Double(player.currentVideoSubTitleDelay) / 1_000_000 }
        set { player.currentVideoSubTitleDelay = Int(newValue * 1_000_000) }
    }
}

extension VLCEngine {
    /// Para o registro de erros: de onde vem, sem endereço nem senha.
    fileprivate static func tipo(_ origem: MediaOrigin) -> String {
        switch origem {
        case .file:   return "arquivo do aparelho"
        case .smb:    return "SMB"
        case .webdav: return "WebDAV"
        case .midia:  return "Jellyfin/Emby"
        case .remote: return "endereço"
        }
    }

    fileprivate static func nome(_ estado: VLCMediaPlayerState) -> String {
        switch estado {
        case .nothingSpecial: return "nada"
        case .opening:        return "abrindo"
        case .playing:        return "tocando"
        case .paused:         return "pausado"
        case .stopped:        return "parado"
        case .stopping:       return "parando"
        case .error:          return "erro"
        @unknown default:     return "\(estado.rawValue)"
        }
    }
}

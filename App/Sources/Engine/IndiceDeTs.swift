import Foundation

/// Um arquivo remoto lido por trechos soltos.
protocol LeitorDeTrechos: AnyObject {
    func tamanho() async throws -> Int64
    /// Até `quantos` bytes a partir de `posicao`; menos só no fim do arquivo.
    func ler(_ posicao: Int64, _ quantos: Int) async throws -> [UInt8]
    func fechar() async
}

/// Duração e busca por tempo de uma gravação em MPEG-TS lida pela rede.
///
/// Gravação de live costuma sair em MPEG-TS, às vezes com nome `.mp4`. TS não
/// tem índice nem duração no cabeçalho: o VLC só os descobre lendo o fim do
/// arquivo e procurando o tempo por busca binária — e o VLC 3 só faz isso
/// quando a fonte é "rápida de pular", o que SMB e HTTP não são. A duração
/// ficava igual ao tempo já tocado, crescendo junto, e arrastar a barra não
/// levava a lugar nenhum.
///
/// Aqui o app faz o que o VLC deixou de fazer: lê o relógio (PCR) do começo e
/// do fim para a duração, e para ir a um instante acha por busca binária o
/// byte onde ele está; o VLC então pula para essa posição do arquivo, o que
/// ele faz em qualquer fonte. Pular pela proporção de bytes não serve: o fluxo
/// de uma live varia muito — numa de 2h41 o meio do arquivo estava 5 minutos
/// antes do meio do tempo.
///
/// O mesmo índice do irmão Android (`IndiceDeTs.kt`).
actor IndiceDeTs {
    nonisolated let duracao: Double
    private let leitor: LeitorDeTrechos
    private let tamanho: Int64
    private let pacote: Int
    private let deslocamento: Int
    private let pid: Int
    private let primeiro: Int64

    /// Pontos já medidos, em ordem de byte: (byte do pacote, segundos desde o começo).
    private var pontos: [(byte: Int64, tempo: Double)]

    private static let bloco = 256 * 1024
    private static let volta: Int64 = 1 << 33

    private init(leitor: LeitorDeTrechos, tamanho: Int64, pacote: Int, deslocamento: Int,
                 pid: Int, primeiro: Int64, duracao: Double) {
        self.leitor = leitor
        self.tamanho = tamanho
        self.pacote = pacote
        self.deslocamento = deslocamento
        self.pid = pid
        self.primeiro = primeiro
        self.duracao = duracao
        pontos = [(0, 0), (tamanho, duracao)]
    }

    /// O índice, se o arquivo for MPEG-TS; `nil` para qualquer outro formato
    /// (lê só 4 KB).
    static func abrir(_ leitor: LeitorDeTrechos) async throws -> IndiceDeTs? {
        // 4 KB dizem se é TS; só então vale ler mais.
        guard let (pacote, deslocamento) = formato(try await leitor.ler(0, 4096)) else { return nil }
        let inicio = try await leitor.ler(0, bloco)
        var pid = -1
        var primeiro: Int64 = -1
        var i = 0
        while i + pacote <= inicio.count && pid < 0 {
            if let p = pcrDoPacote(inicio, i + deslocamento, nil) {
                pid = pidDe(inicio, i + deslocamento)
                primeiro = p
            }
            i += pacote
        }
        guard pid >= 0 else { return nil }

        // O último PCR: blocos do fim para trás até achar um.
        let tamanho = try await leitor.tamanho()
        var ultimo: Int64 = -1
        var fim = tamanho
        while ultimo < 0 && fim > 0 && tamanho - fim < 16 * Int64(bloco) {
            var de = max(0, fim - Int64(bloco))
            de -= de % Int64(pacote)
            let trecho = try await leitor.ler(de, Int(fim - de))
            var j = 0
            while j + pacote <= trecho.count {
                if let p = pcrDoPacote(trecho, j + deslocamento, pid) { ultimo = p }
                j += pacote
            }
            fim = de
        }
        guard ultimo >= 0 else { return nil }
        let duracao = Double((ultimo - primeiro + volta) % volta) / 90_000
        guard duracao >= 1 else { return nil }
        return IndiceDeTs(leitor: leitor, tamanho: tamanho, pacote: pacote, deslocamento: deslocamento,
                          pid: pid, primeiro: primeiro, duracao: duracao)
    }

    /// A fração do arquivo (0…1) onde fica `segundos`. Mira um pouco antes,
    /// porque o VLC recomeça no quadro-chave seguinte ao byte pedido.
    func fracao(de segundos: Double) async throws -> Float {
        let alvo = min(max(segundos - 1, 0), duracao)
        var baixo = pontos.last(where: { $0.tempo <= alvo }) ?? pontos[0]
        var alto = pontos.first(where: { $0.tempo > alvo }) ?? pontos[pontos.count - 1]
        // Interpolação nos passos pares (acerta em poucos passos num fluxo
        // quase constante) e metade nos ímpares (garante que o vão encolha
        // mesmo quando o fluxo varia muito).
        for passo in 0..<64 {
            if alvo - baixo.tempo < 0.5 || alto.tempo - baixo.tempo < 1 { break }
            let vao = alto.byte - baixo.byte
            if vao < 4 * Int64(pacote) { break }
            let proporcao = passo % 2 == 0
                ? min(max((alvo - baixo.tempo) / (alto.tempo - baixo.tempo), 0.01), 0.99)
                : 0.5
            guard let medido = try await pcrApos(baixo.byte + Int64(Double(vao) * proporcao), ate: alto.byte)
            else { break }
            // Nenhum relógio entre as pontas: o ponto de baixo é o mais perto.
            if medido.byte >= alto.byte || medido.byte <= baixo.byte { break }
            guardar(medido)
            if medido.tempo <= alvo { baixo = medido } else { alto = medido }
        }
        return Float(Double(baixo.byte) / Double(tamanho))
    }

    func fechar() async { await leitor.fechar() }

    private func guardar(_ ponto: (byte: Int64, tempo: Double)) {
        let i = pontos.firstIndex(where: { $0.byte >= ponto.byte }) ?? pontos.count
        if i < pontos.count, pontos[i].byte == ponto.byte { return }
        pontos.insert(ponto, at: i)
    }

    /// O primeiro PCR do pid a partir de `de`, antes de `ate`.
    private func pcrApos(_ de: Int64, ate: Int64) async throws -> (byte: Int64, tempo: Double)? {
        var pos = de - de % Int64(pacote)
        // O PCR vem a cada 100 ms no máximo: 64 KB bastam até ~5 Mb/s; acima
        // disso o bloco dobra até achar.
        var quanto = 64 * 1024
        while pos < ate {
            let trecho = try await leitor.ler(pos, quanto)
            quanto = min(quanto * 2, Self.bloco * 4)
            if trecho.count < pacote { return nil }
            var i = 0
            while i + pacote <= trecho.count {
                if let pcr = Self.pcrDoPacote(trecho, i + deslocamento, pid) {
                    return (pos + Int64(i), Double((pcr - primeiro + Self.volta) % Self.volta) / 90_000)
                }
                i += pacote
            }
            pos += Int64(i)
        }
        return nil
    }

    /// Tamanho do pacote e onde o byte de sincronia fica: TS (188) ou M2TS (192, +4).
    private static func formato(_ b: [UInt8]) -> (Int, Int)? {
        for (pacote, desl) in [(188, 0), (192, 4)] {
            guard b.count >= desl + pacote * 5 else { continue }
            if (0..<5).allSatisfy({ b[desl + $0 * pacote] == 0x47 }) { return (pacote, desl) }
        }
        return nil
    }

    private static func pidDe(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i + 1] & 0x1f) << 8) | Int(b[i + 2])
    }

    /// A base de 33 bits do PCR do pacote em `i`, se houver (e se for do `pid`).
    private static func pcrDoPacote(_ b: [UInt8], _ i: Int, _ pid: Int?) -> Int64? {
        guard i + 12 <= b.count, b[i] == 0x47 else { return nil }
        if let pid, pidDe(b, i) != pid { return nil }
        let campo = (b[i + 3] >> 4) & 3
        guard campo == 2 || campo == 3 else { return nil }
        guard b[i + 4] >= 7, b[i + 5] & 0x10 != 0 else { return nil }
        func u(_ k: Int) -> Int64 { Int64(b[i + 6 + k]) }
        return (u(0) << 25) | (u(1) << 17) | (u(2) << 9) | (u(3) << 1) | (u(4) >> 7)
    }
}

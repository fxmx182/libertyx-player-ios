import UIKit
import CryptoKit
import AVFoundation

/// Gera e guarda as miniaturas dos vídeos.
///
/// Usa o `FrameExtractor` — o mesmo decodificador de quadro exato do motor
/// próprio. Ele decodifica um quadro do meio do início do vídeo, e não o
/// primeiro: abertura costuma ser tela preta ou logotipo.
///
/// Cache em disco não é otimização, é requisito: no SMB cada miniatura custa
/// leitura pela rede, e regerar a lista toda a cada abertura do app seria
/// inaceitável.
@MainActor
final class ThumbnailStore: ObservableObject {

    static let shared = ThumbnailStore()

    /// Ligado enquanto um vídeo está aberto.
    ///
    /// Decodificar com FFmpeg ao mesmo tempo que a reprodução acontece já
    /// derrubou o app uma vez — dois leitores disputando o mesmo arquivo. Uma
    /// miniatura pode esperar; a reprodução, não.
    static var isSuspended = false

    /// Instante do quadro: cedo o bastante para não custar busca longa em
    /// arquivo de rede, e tarde o bastante para passar da tela preta inicial.
    private static let momento: Double = 12

    private let memoria = NSCache<NSString, UIImage>()
    /// Duração descoberta ao gerar a miniatura — o arquivo já estava aberto.
    private var duracoes: [String: Double] = UserDefaults.standard
        .dictionary(forKey: "labplayer.duracoes") as? [String: Double] ?? [:]
    private var conexoes: [UUID: SMBConnection] = [:]
    private var emCurso: Set<String> = []

    private lazy var pasta: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let destino = base.appendingPathComponent("miniaturas", isDirectory: true)
        try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        return destino
    }()

    private init() {
        memoria.countLimit = 300
    }

    // MARK: - Acesso

    /// Resposta imediata, sem gerar nada — para a lista desenhar sem esperar.
    func cached(_ item: MediaItem) -> UIImage? {
        let chave = Self.chave(for: item)
        if let imagem = memoria.object(forKey: chave as NSString) { return imagem }
        guard let dados = try? Data(contentsOf: arquivo(chave)),
              let imagem = UIImage(data: dados) else { return nil }
        memoria.setObject(imagem, forKey: chave as NSString)
        return imagem
    }

    /// Duração conhecida, se a miniatura já foi gerada alguma vez.
    func duration(_ item: MediaItem) -> Double? {
        let valor = duracoes[Self.chave(for: item)]
        return (valor ?? 0) > 0 ? valor : nil
    }

    func load(_ item: MediaItem) async -> UIImage? {
        if let pronta = cached(item) { return pronta }

        let chave = Self.chave(for: item)
        // Duas linhas da lista pedindo o mesmo arquivo não devem gerar duas
        // vezes — no SMB isso dobraria o tráfego à toa.
        guard !emCurso.contains(chave), !Self.isSuspended else { return nil }
        emCurso.insert(chave)
        defer { emCurso.remove(chave) }

        guard let previa = await gerar(item) else { return nil }
        let imagem = previa.0
        if previa.1 > 0 {
            duracoes[chave] = previa.1
            UserDefaults.standard.set(duracoes, forKey: "labplayer.duracoes")
        }
        memoria.setObject(imagem, forKey: chave as NSString)
        if let dados = imagem.jpegData(compressionQuality: 0.7) {
            try? dados.write(to: arquivo(chave), options: .atomic)
        }
        return imagem
    }

    // MARK: - Geração

    private func gerar(_ item: MediaItem) async -> (UIImage, Double)? {
        switch item.origin {
        case .file(let url, let bookmark):
            // AVFoundation primeiro: é o gerador de miniatura da própria Apple,
            // muito mais confiável nos MP4 e MOV gravados pelo celular — que
            // são a maioria. O caminho FFmpeg fica para o que ela recusa.
            if let porApple = await gerarComAVFoundation(url: url, bookmark: bookmark) {
                return porApple
            }

            let origem = item.origin
            let previa = try? await FFmpegRunner.run {
                try FileAccess.withAccess(origem) { caminho in
                    try FrameExtractor.preview(path: caminho, at: Self.momento,
                                               maxWidth: FrameExtractor.listWidth)
                }
            }
            guard let previa = previa ?? nil else {
                LabLog.problem("miniatura falhou: \(item.title)")
                return nil
            }
            return (UIImage(cgImage: previa.image), previa.duration)

        case .smb(let referencia, let caminho):
            guard let conexao = conexao(para: referencia) else { return nil }
            guard let previa = try? await conexao.thumbnail(share: referencia.share, path: caminho,
                                                            at: Self.momento,
                                                            maxWidth: FrameExtractor.listWidth) else {
                return nil
            }
            return (UIImage(cgImage: previa.image), previa.duration)

        case .remote:
            return nil
        }
    }

    /// Miniatura pelo gerador da Apple.
    ///
    /// O escopo de segurança fica aberto durante toda a geração — ela é
    /// assíncrona, e fechar antes faria a leitura falhar no meio.
    private func gerarComAVFoundation(url: URL, bookmark: Data?) async -> (UIImage, Double)? {
        let guarda = ScopedAccess(url: url, bookmark: bookmark)
        guard guarda.path != nil else { return nil }

        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }

        let duracao = (try? await asset.load(.duration).seconds) ?? 0
        let gerador = AVAssetImageGenerator(asset: asset)
        // Respeita a rotação gravada pelo celular; sem isso vídeo em pé sai
        // deitado na miniatura.
        gerador.appliesPreferredTrackTransform = true
        gerador.maximumSize = CGSize(width: 320, height: 320)

        // 10% da duração, com teto de 12 s: passa da abertura escura sem cair
        // depois do fim num vídeo curto.
        let instante = duracao > 0 ? min(Self.momento, duracao * 0.1) : 0
        let alvo = CMTime(seconds: max(0, instante), preferredTimescale: 600)

        guard let cg = try? await gerador.image(at: alvo).image else { return nil }
        return withExtendedLifetime(guarda) { (UIImage(cgImage: cg), duracao) }
    }

    /// Uma conexão por servidor, reaproveitada: abrir sessão SMB a cada
    /// miniatura custaria mais que gerar a imagem.
    private func conexao(para referencia: SMBShareRef) -> SMBConnection? {
        if let viva = conexoes[referencia.serverID] { return viva }
        guard let servidor = SMBServerStore.shared.servers.first(where: { $0.id == referencia.serverID }) else {
            return nil
        }
        let nova = SMBConnection(server: servidor, password: SMBServerStore.shared.password(for: servidor))
        conexoes[referencia.serverID] = nova
        return nova
    }

    // MARK: - Chaves

    /// Identidade estável do arquivo, não do caminho: pendrive remontado muda
    /// de caminho e o servidor pode ser alcançado por endereços diferentes.
    private static func chave(for item: MediaItem) -> String {
        let bruto = "\(item.origin.resumeKey)|\(item.fileSize ?? 0)"
        let resumo = SHA256.hash(data: Data(bruto.utf8))
        return resumo.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func arquivo(_ chave: String) -> URL {
        pasta.appendingPathComponent("\(chave).jpg")
    }
}

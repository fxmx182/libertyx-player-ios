import Foundation

/// De onde um vídeo vem.
///
/// Essa é a abstração central do projeto. O motor de playback nunca sabe se os
/// bytes vieram de um pendrive USB, de um share SMB do homelab ou de uma URL —
/// ele só pede blocos. Quando o motor FFmpeg entrar, cada caso vira um
/// `AVIOContext` com callbacks de read/seek, e nada acima disso muda.
enum MediaOrigin: Equatable, Hashable {
    /// Arquivo no sandbox do app, no iCloud, ou num volume externo (USB).
    ///
    /// `bookmark`, quando presente, é da **pasta** que concede acesso — não do
    /// arquivo. É assim que o iOS funciona: quem autoriza é a árvore escolhida
    /// no seletor, e cada arquivo dentro dela só é legível enquanto o escopo
    /// dessa pasta estiver ativo. Carregar o bookmark junto permite ao player
    /// abrir o próprio escopo em vez de depender de a tela que o abriu
    /// continuar viva.
    case file(url: URL, bookmark: Data?)

    /// Compartilhamento SMB do homelab.
    case smb(share: SMBShareRef, path: String)

    /// HTTP(S) direto.
    case remote(url: URL)
}

struct SMBShareRef: Equatable, Hashable, Codable {
    /// Aponta para o servidor salvo. É por aqui que o motor recupera endereço
    /// e credenciais na hora de tocar — a senha vive no Keychain, nunca aqui.
    var serverID: UUID
    var host: String
    var share: String
}

/// Um item reproduzível, já resolvido para exibição.
struct MediaItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var origin: MediaOrigin
    var fileSize: Int64?
    var modifiedAt: Date?
    /// Transmissão contínua sem fim — canal de TV.
    ///
    /// O Jellyfin entrega canal como MPEG-TS puro sobre HTTP, que o AVPlayer
    /// não sabe ler: ele só entende HLS. Marcar aqui evita dez segundos de
    /// tela preta até o vigia perceber e trocar de motor.
    var isLiveStream: Bool = false

    init(id: UUID = UUID(), title: String, origin: MediaOrigin,
         fileSize: Int64? = nil, modifiedAt: Date? = nil,
         isLiveStream: Bool = false) {
        self.id = id
        self.title = title
        self.origin = origin
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.isLiveStream = isLiveStream
    }

    /// Extensões que consideramos vídeo ao varrer uma pasta.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts",
        "mts", "mpg", "mpeg", "vob", "3gp", "ogv", "rmvb", "asf", "divx", "f4v"
    ]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}

/// Abre o escopo de segurança necessário para ler um arquivo, roda o trabalho
/// e fecha em seguida.
///
/// Existe para não repetir a dança de bookmark em cada lugar que toca disco —
/// e porque esquecer de abrir o escopo produz um erro que aponta para o lugar
/// errado: o iOS responde "não consegui ler" de um jeito que o FFmpeg e o
/// AVFoundation traduzem como "formato inválido".
enum FileAccess {

    static func withAccess<T>(_ origin: MediaOrigin, _ body: (String) throws -> T) rethrows -> T? {
        guard case .file(let url, let bookmark) = origin else { return nil }

        var scoped: URL?
        if let bookmark {
            var stale = false
            if let pasta = try? URL(resolvingBookmarkData: bookmark,
                                    options: [],
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &stale),
               pasta.startAccessingSecurityScopedResource() {
                scoped = pasta
            }
        }
        if scoped == nil, url.startAccessingSecurityScopedResource() {
            scoped = url
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }

        return try body(url.path)
    }
}

extension MediaOrigin {
    /// Nome curto para exibir na lista.
    var displayName: String {
        switch self {
        case .file(let url, _):  return url.lastPathComponent
        case .smb(_, let path):  return (path as NSString).lastPathComponent
        case .remote(let url):   return url.lastPathComponent
        }
    }

    /// Identidade estável para retomar de onde parou. Precisa sobreviver a
    /// remontagens do pendrive (o caminho do sandbox muda), por isso usamos o
    /// nome do arquivo em vez da URL completa nos casos de arquivo.
    var resumeKey: String {
        switch self {
        case .file(let url, _):
            return "file:\(url.lastPathComponent)"
        case .smb(let share, let path):
            return "smb:\(share.host)/\(share.share)\(path)"
        case .remote(let url):
            return "url:\(url.absoluteString)"
        }
    }
}

import Foundation

/// Um conjunto de vídeos que vivem na mesma pasta.
struct VideoGroup: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var items: [MediaItem]
}

/// Varre tudo que o app pode ler e agrupa por pasta.
///
/// Limite que vale entender: o iOS **não** permite varrer o aparelho inteiro.
/// Cada app enxerga só a própria pasta e as árvores que o usuário autorizou
/// explicitamente no seletor de arquivos. Não há como contornar isso — então
/// a estratégia é varrer fundo o que temos permissão de ver, em vez de pedir
/// ao usuário para navegar pasta por pasta toda vez.
@MainActor
final class MediaLibrary: ObservableObject {

    @Published private(set) var groups: [VideoGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?

    /// Profundidade máxima. Séries costumam ser Série/Temporada/arquivos;
    /// cinco níveis cobrem folgado, e evitam travar numa árvore patológica.
    private let maxDepth = 5
    private let maxFiles = 3000

    func refresh(bookmarks: BookmarkStore) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; lastScan = Date() }

        // As raízes precisam ser resolvidas na thread principal (o store é
        // @MainActor); a varredura em si vai para fora dela.
        var raizes: [(url: URL, bookmark: Data?, rotulo: String)] = []

        let documentos = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documentos {
            raizes.append((documentos, nil, "No LabPlayer"))
        }

        var escopos: [URL] = []
        for pasta in bookmarks.folders {
            guard let resolvida = bookmarks.resolve(pasta) else { continue }
            escopos.append(resolvida)
            raizes.append((resolvida, pasta.bookmark, pasta.name))
        }
        defer { escopos.forEach { $0.stopAccessingSecurityScopedResource() } }

        let profundidade = maxDepth
        let teto = maxFiles
        let encontrados = await Task.detached(priority: .userInitiated) {
            Self.scan(roots: raizes, maxDepth: profundidade, maxFiles: teto)
        }.value

        groups = encontrados
    }

    // MARK: - Varredura

    nonisolated private static func scan(roots: [(url: URL, bookmark: Data?, rotulo: String)],
                                         maxDepth: Int,
                                         maxFiles: Int) -> [VideoGroup] {
        var porPasta: [String: VideoGroup] = [:]
        var total = 0

        for raiz in roots {
            var fila: [(URL, Int)] = [(raiz.url, 0)]

            while let (diretorio, nivel) = fila.popLast(), total < maxFiles {
                guard nivel <= maxDepth else { continue }

                let chaves: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                guard let entradas = try? FileManager.default.contentsOfDirectory(
                    at: diretorio,
                    includingPropertiesForKeys: chaves,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for url in entradas {
                    let valores = try? url.resourceValues(forKeys: Set(chaves))

                    if valores?.isDirectory == true {
                        fila.append((url, nivel + 1))
                        continue
                    }
                    guard MediaItem.isVideo(url) else { continue }
                    total += 1

                    let pasta = url.deletingLastPathComponent()
                    let chave = pasta.path
                    // A pasta raiz aparece com o apelido que o usuário deu; as
                    // subpastas, com o próprio nome.
                    let nome = pasta.path == raiz.url.path ? raiz.rotulo : pasta.lastPathComponent

                    let item = MediaItem(
                        title: url.lastPathComponent,
                        origin: .file(url: url, bookmark: raiz.bookmark),
                        fileSize: valores?.fileSize.map(Int64.init),
                        modifiedAt: valores?.contentModificationDate
                    )

                    porPasta[chave, default: VideoGroup(name: nome, path: chave, items: [])]
                        .items.append(item)
                }
            }
        }

        return porPasta.values
            .map { grupo in
                var ordenado = grupo
                ordenado.items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return ordenado
            }
            // Pastas em ordem natural, para "Temporada 2" vir antes de "Temporada 10".
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

import SwiftUI

@main
struct LabPlayerApp: App {
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var smbServers = SMBServerStore.shared
    /// O guia aparece enquanto isto for falso: na primeira abertura, e de novo
    /// quando a Visualização pede para rever.
    @AppStorage(Guia.chave) private var guiaVisto = false

    init() {
        // Antes da primeira tela: sem isto o app não aparece no Arquivos, e o
        // usuário não tem para onde mandar os vídeos.
        DocumentsSetup.run()
        Self.aplicarLetraNaNavegacao()
    }

    /// A Manrope também nos títulos das barras de navegação.
    ///
    /// As telas em SwiftUI recebem a letra pelo ambiente, mas a barra de cima é
    /// do sistema e não enxerga ambiente: sem isto, "Servidores" e o nome da
    /// pasta de rede sairiam na letra do sistema, no meio de um app inteiro na
    /// Manrope.
    private static func aplicarLetraNaNavegacao() {
        let aparencia = UINavigationBarAppearance()
        aparencia.configureWithTransparentBackground()
        aparencia.titleTextAttributes = [.font: LabFont.ui(17, .bold),
                                         .foregroundColor: UIColor.white]
        aparencia.largeTitleTextAttributes = [.font: LabFont.ui(32, .heavy),
                                              .foregroundColor: UIColor.white]
        let barra = UINavigationBar.appearance()
        barra.standardAppearance = aparencia
        barra.scrollEdgeAppearance = aparencia
        barra.compactAppearance = aparencia
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(bookmarks)
                .environmentObject(smbServers)
                .preferredColorScheme(.dark)
                // Ciano em vez do azul de todo mundo, e um fundo um pouco acima
                // do preto para as superfícies de vidro terem de onde emergir.
                .tint(LabTheme.accent)
                // A letra do app para todo texto que não pedir outra.
                .font(LabFont.swiftUI(16, .medium))
                .background(LabTheme.background.ignoresSafeArea())
                .fullScreenCover(isPresented: Binding(get: { !guiaVisto },
                                                      set: { if !$0 { guiaVisto = true } })) {
                    GuiaDeBoasVindas { guiaVisto = true }
                        .tint(LabTheme.accent)
                        .font(LabFont.swiftUI(16, .medium))
                }
        }
    }
}

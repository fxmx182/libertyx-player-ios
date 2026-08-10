import SwiftUI

@main
struct LabPlayerApp: App {
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var smbServers = SMBServerStore.shared

    init() {
        // Antes da primeira tela: sem isto o app não aparece no Arquivos, e o
        // usuário não tem para onde mandar os vídeos.
        DocumentsSetup.run()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(bookmarks)
                .environmentObject(smbServers)
                .preferredColorScheme(.dark)
        }
    }
}

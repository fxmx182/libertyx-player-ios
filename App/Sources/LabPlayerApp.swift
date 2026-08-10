import SwiftUI

@main
struct LabPlayerApp: App {
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var smbServers = SMBServerStore.shared

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(bookmarks)
                .environmentObject(smbServers)
                .preferredColorScheme(.dark)
        }
    }
}

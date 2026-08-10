import Foundation

/// Identidade do build, lida do Info.plist.
///
/// Existe por um motivo prático: sem ver o commit na tela, é impossível
/// distinguir "a mudança não funcionou" de "instalei o .ipa antigo" — e as
/// duas coisas pedem investigações completamente diferentes.
enum AppBuild {

    static var version: String {
        info("CFBundleShortVersionString") ?? "?"
    }

    /// Commit de origem, carimbado pelo CI. Vale "local" quando compilado à mão.
    static var commit: String {
        info("LabPlayerBuild") ?? "?"
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}

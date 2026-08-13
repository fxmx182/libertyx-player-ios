import SwiftUI
import WebKit

/// O Jellyfin dentro do app, pela interface web dele.
///
/// É o que o app oficial de celular faz, e a razão de funcionar é uma só: o
/// `<video>` de uma página no iOS é tocado pela AVFoundation, com a janela
/// flutuante que ela oferece de graça. Não é um motor novo — é o reprodutor da
/// Apple, chegando por outro caminho.
///
/// O preço está assumido: aqui dentro os gestos, a barra e as ferramentas são
/// os do Jellyfin, não os nossos. Fora daqui — celular, pendrive, SMB — nada
/// muda, e quem toca continua sendo o VLC.
struct JellyfinWebScreen: View {

    let server: JellyfinServer

    @Environment(\.dismiss) private var dismiss
    @State private var carregando = true

    var body: some View {
        JellyfinWebView(server: server, carregando: $carregando)
            .overlay(alignment: .center) {
                if carregando { ProgressView() }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fechar") { dismiss() }
                }
            }
    }
}

struct JellyfinWebView: UIViewRepresentable {

    let server: JellyfinServer
    @Binding var carregando: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuracao = WKWebViewConfiguration()

        // As três linhas que fazem o vídeo se comportar como num app:
        // toca embutido em vez de abrir em tela cheia do sistema, aceita a
        // janela flutuante, e começa sem exigir um toque a mais.
        configuracao.allowsInlineMediaPlayback = true
        configuracao.allowsPictureInPictureMediaPlayback = true
        configuracao.mediaTypesRequiringUserActionForPlayback = []

        // Guarda sessão entre aberturas: o login feito uma vez continua valendo
        // no dia seguinte.
        configuracao.websiteDataStore = .default()

        if let entrada = Self.scriptDeEntrada(for: server) {
            configuracao.userContentController.addUserScript(entrada)
        }

        let web = WKWebView(frame: .zero, configuration: configuracao)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black

        web.load(URLRequest(url: server.baseURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(carregando: $carregando) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let carregando: Binding<Bool>

        init(carregando: Binding<Bool>) { self.carregando = carregando }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            carregando.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            carregando.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            carregando.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            carregando.wrappedValue = false
        }

        /// O servidor de casa costuma usar certificado próprio; recusar aqui
        /// deixaria a tela em branco sem explicação.
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let confianca = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: confianca))
        }
    }

    /// Entrega ao site o acesso que já conseguimos, para não pedir a senha de
    /// novo.
    ///
    /// É o mesmo lugar onde a própria interface web guarda a sessão. Se o
    /// formato mudar numa versão futura do Jellyfin, o efeito é só a tela de
    /// login aparecer — nada quebra.
    private static func scriptDeEntrada(for server: JellyfinServer) -> WKUserScript? {
        guard let token = JellyfinStore.shared.token(for: server),
              let systemID = server.systemID else { return nil }

        let credenciais: [String: Any] = [
            "Servers": [[
                "ManualAddress": server.baseURL.absoluteString,
                "Id": systemID,
                "AccessToken": token,
                "UserId": server.userID,
                "Name": server.name,
                "DateLastAccessed": Int(Date().timeIntervalSince1970 * 1000),
                "LastConnectionMode": 1,
            ]],
        ]

        guard let dados = try? JSONSerialization.data(withJSONObject: credenciais),
              let json = String(data: dados, encoding: .utf8) else { return nil }

        let fonte = """
        (function () {
            try {
                localStorage.setItem('jellyfin_credentials', \(json.javaScriptLiteral));
            } catch (e) {}
        })();
        """

        return WKUserScript(source: fonte, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

private extension String {
    /// O JSON entra no script como texto, então precisa virar literal.
    var javaScriptLiteral: String {
        let escapado = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
        return "'\(escapado)'"
    }
}

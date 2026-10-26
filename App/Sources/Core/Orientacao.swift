import UIKit

/// Quem pode girar: o player, sim; a biblioteca, não.
///
/// A biblioteca gira junto com o aparelho só se o app inteiro aceitar
/// paisagem — e aceitava, porque o player precisa. O efeito era sair de um
/// vídeo visto deitado e cair numa biblioteca deitada, com duas capas por tela
/// e o polegar procurando onde rolar. Agora a máscara muda com o player: ele
/// libera a paisagem ao abrir e, ao fechar, devolve o app em pé.
///
/// No iPad nada disto vale: lá o app gira inteiro, como todo app de iPad, e o
/// sistema nem obedece a uma trava enquanto houver multitarefa. Na tela de
/// dentro do iPhone Duo também não — ela ignora orientação.
enum Orientacao {

    /// O que o app aceita agora, lido pelo `AppDelegate`.
    static private(set) var mascara: UIInterfaceOrientationMask = .portrait

    static var paraOAparelho: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : mascara
    }

    /// O player abriu (`true`) ou fechou (`false`).
    @MainActor
    static func player(_ aberto: Bool, cena: UIWindowScene?) {
        mascara = aberto ? .allButUpsideDown : .portrait
        guard let cena else { return }

        // Cada controlador da pilha relê o que aceita. Sem isto o sistema só
        // percebe a mudança na próxima vez que o aparelho girar.
        var atual = cena.keyWindow?.rootViewController
        while let controlador = atual {
            controlador.setNeedsUpdateOfSupportedInterfaceOrientations()
            atual = controlador.presentedViewController
        }
        // Ao fechar, de volta em pé na hora — e não só quando a pessoa
        // endireitar o aparelho.
        if !aberto && UIDevice.current.userInterfaceIdiom != .pad {
            cena.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }
}

/// Só existe para responder à pergunta de orientação do sistema.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientacao.paraOAparelho
    }
}

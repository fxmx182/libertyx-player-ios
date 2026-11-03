import Foundation

extension Error {
    /// A leitura foi cancelada, e não falhou: a tela recarregou ou saiu no
    /// meio dela. Tratado como erro, aparecia por um instante uma mensagem de
    /// "cancelado" ao entrar no Jellyfin, até a leitura seguinte chegar.
    var foiCancelado: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled || Task.isCancelled
    }
}

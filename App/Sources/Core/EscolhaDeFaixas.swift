import Foundation

/// O áudio e a legenda escolhidos na página do vídeo, antes de tocar — como
/// os seletores do app do Jellyfin.
///
/// A página conhece as faixas pelo que o servidor leu do arquivo; o VLC, pela
/// ordem em que as encontra. As duas listas seguem a ordem do arquivo, então a
/// escolha viaja como posição: "o segundo áudio", "a primeira legenda de
/// dentro". A legenda de fora (o `.srt` ao lado) viaja pelo número que o
/// servidor dá a ela, que vai no nome do arquivo baixado (ver
/// `ServidorDeMidia.legendasExternas`).
///
/// Vale uma vez: o player consome a escolha ao abrir aquele vídeo.
@MainActor
final class EscolhaDeFaixas {

    static let shared = EscolhaDeFaixas()

    enum Legenda: Equatable {
        /// Desligada de vez, sem nem a forçada.
        case desligada
        case interna(posicao: Int)
        case externa(indice: Int)
    }

    struct Pedido {
        var audio: Int?
        /// `nil`: a regra de sempre (só a forçada).
        var legenda: Legenda?
    }

    private var pedidos: [String: Pedido] = [:]

    func pedir(_ pedido: Pedido, para chave: String) {
        if pedido.audio == nil && pedido.legenda == nil {
            pedidos[chave] = nil
        } else {
            pedidos[chave] = pedido
        }
    }

    func consumir(_ chave: String) -> Pedido? {
        defer { pedidos[chave] = nil }
        return pedidos[chave]
    }
}

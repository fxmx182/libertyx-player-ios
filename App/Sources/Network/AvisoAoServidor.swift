import Foundation

/// Conta ao Jellyfin ou ao Emby o que o player está tocando.
///
/// É o que põe o filme pela metade no "Continuar assistindo" do servidor e
/// marca o episódio como visto no app dele, na TV e no navegador. Para os
/// outros vídeos do app, não faz nada.
///
/// Os avisos saem um de cada vez e na ordem: um "parou" que chegasse antes do
/// "começou" deixaria o servidor achando que o filme ainda está tocando.
@MainActor
final class AvisoAoServidor {

    private struct Sessao {
        let servidor: ServidorDeMidia
        let item: String
        let id = UUID().uuidString
    }

    private static let intervalo: TimeInterval = 10

    private var sessao: Sessao?
    private var ultimoAviso = Date.distantPast
    private var pausado = false
    /// O aviso anterior: o próximo só sai depois dele.
    private var fila: Task<Void, Never>?

    func comecou(_ item: MediaItem, em segundos: Double) {
        parou(em: segundos)
        guard case .midia(let contaID, let itemID) = item.origin,
              let conta = ContasDeRede.shared.conta(contaID) else { return }
        let nova = Sessao(servidor: ServidorDeMidia(conta: conta, token: ContasDeRede.shared.segredo(conta)),
                          item: itemID)
        sessao = nova
        pausado = false
        ultimoAviso = Date()
        avisar(nova, nil, segundos)
    }

    /// Chamado a cada atualização de tempo, mas só avisa a cada dez segundos
    /// — ou na hora, quando pausa ou volta a tocar.
    func andou(_ segundos: Double, pausado: Bool) {
        guard let sessao else { return }
        let agora = Date()
        if pausado == self.pausado, agora.timeIntervalSince(ultimoAviso) < Self.intervalo { return }
        self.pausado = pausado
        ultimoAviso = agora
        avisar(sessao, "Progress", segundos)
    }

    /// Pode ser chamado mais de uma vez: só o primeiro chega ao servidor.
    func parou(em segundos: Double) {
        guard let atual = sessao else { return }
        sessao = nil
        avisar(atual, "Stopped", segundos)
    }

    private func avisar(_ sessao: Sessao, _ evento: String?, _ segundos: Double) {
        let pausadoAgora = pausado
        let anterior = fila
        fila = Task {
            await anterior?.value
            // Sem rede, o aviso se perde, e o vídeo segue tocando: a marca do
            // aparelho continua valendo, e o próximo aviso corrige o servidor.
            try? await sessao.servidor.informar(evento, item: sessao.item, segundos: segundos,
                                                pausado: pausadoAgora, sessao: sessao.id)
        }
    }
}

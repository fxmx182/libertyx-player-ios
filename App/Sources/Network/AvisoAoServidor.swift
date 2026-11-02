import Foundation

/// Conta ao Jellyfin ou ao Emby o que o player está tocando.
///
/// É o que põe o filme pela metade no "Continuar assistindo" do servidor e
/// marca o episódio como visto no app dele, na TV e no navegador. Para os
/// outros vídeos do app, não faz nada.
///
/// Os avisos saem um de cada vez e na ordem: um "parou" que chegasse antes do
/// "começou" deixaria o servidor achando que o filme ainda está tocando. A
/// fila é uma só para o app inteiro: a tela do servidor espera por ela
/// (`emDia`) antes de pedir o "Continuar".
@MainActor
final class AvisoAoServidor {

    private struct Sessao {
        let contaID: String
        let servidor: ServidorDeMidia
        let item: String
        let id = UUID().uuidString
    }

    private static let intervalo: TimeInterval = 10

    private var sessao: Sessao?
    private var ultimoAviso = Date.distantPast
    private var pausado = false
    /// O último aviso posto na fila: o próximo só sai depois dele.
    private static var fila: Task<Void, Never>?

    /// Espera os avisos a caminho do servidor — no máximo uns segundos, para
    /// a tela não travar sem rede.
    static func emDia() async {
        guard let fila else { return }
        await withTaskGroup(of: Void.self) { grupo in
            grupo.addTask { await fila.value }
            grupo.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            await grupo.next()
            grupo.cancelAll()
        }
    }

    func comecou(_ item: MediaItem, em segundos: Double) {
        parou(em: segundos)
        guard case .midia(let contaID, let itemID) = item.origin,
              let conta = ContasDeRede.shared.conta(contaID) else { return }
        let nova = Sessao(contaID: contaID, servidor: ServidorDeMidia(conta: conta, token: ContasDeRede.shared.segredo(conta)),
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
    ///
    /// `visto`: assistido até o fim. Depois que o servidor marca o episódio
    /// como visto, o "A seguir" dele já aponta o próximo — e é esse que entra
    /// no histórico, no lugar do que terminou.
    func parou(em segundos: Double, visto: Bool = false) {
        guard let atual = sessao else { return }
        sessao = nil
        avisar(atual, "Stopped", segundos)
        guard visto else { return }
        enfileirar {
            guard let proximo = try? await atual.servidor.proximoEpisodio(atual.item) else { return }
            let terminado = MediaOrigin.midia(conta: atual.contaID, item: atual.item).resumeKey
            Historico.shared.terminou(chave: terminado, proximo: atual.servidor.paraTocar(proximo))
        }
    }

    private func avisar(_ sessao: Sessao, _ evento: String?, _ segundos: Double) {
        let pausadoAgora = pausado
        enfileirar {
            // Sem rede, o aviso se perde, e o vídeo segue tocando: a marca do
            // aparelho continua valendo, e o próximo aviso corrige o servidor.
            try? await sessao.servidor.informar(evento, item: sessao.item, segundos: segundos,
                                                pausado: pausadoAgora, sessao: sessao.id)
        }
    }

    private func enfileirar(_ trabalho: @escaping @MainActor () async -> Void) {
        let anterior = Self.fila
        Self.fila = Task {
            await anterior?.value
            await trabalho()
        }
    }
}

import Foundation

/// A qualidade de um Jellyfin ou Emby: o arquivo original, como sempre, ou
/// uma versão mais leve que o próprio servidor converte na hora — para ver
/// fora de casa com a internet fraca.
///
/// É escolha de cada conta: em casa, pela rede local, o original é melhor em
/// tudo. A conversão custa processador ao servidor (o do usuário não tem
/// aceleração de vídeo), então ela só acontece quando alguém pede.
enum Qualidade {

    /// Em kbit/s; zero é o original.
    static let opcoes = [0, 20_000, 10_000, 6_000, 4_000, 2_000, 1_000]

    static func nome(_ kbps: Int) -> String {
        kbps == 0 ? String(localized: "Original") : "\(kbps / 1000) Mbps"
    }

    static func da(_ conta: UUID) -> Int {
        UserDefaults.standard.integer(forKey: chave(conta))
    }

    static func definir(_ kbps: Int, para conta: UUID) {
        UserDefaults.standard.set(kbps, forKey: chave(conta))
    }

    private static func chave(_ conta: UUID) -> String { "libertyx.qualidade.\(conta.uuidString)" }
}

/// As conversões em andamento: o servidor as reconhece pelo número da sessão,
/// que tem de ser o mesmo no endereço do vídeo e nos avisos de reprodução —
/// é o "parou" com esse número que manda o servidor desligar a conversão.
final class Conversoes: @unchecked Sendable {

    static let shared = Conversoes()

    private let trava = NSLock()
    private var sessoes: [String: String] = [:]
    private var audios: [String: Int] = [:]
    /// Canais de TV ao vivo já abertos no servidor: o endereço HLS que ele
    /// devolveu e a transmissão a fechar no fim.
    private var aoVivo: [String: URL] = [:]
    private var transmissoes: [String: String] = [:]

    func registrarCanal(_ item: String, url: URL, sessao: String, transmissao: String?) {
        trava.lock(); defer { trava.unlock() }
        aoVivo[item] = url
        sessoes[item] = sessao
        transmissoes[item] = transmissao
    }

    func canal(_ item: String) -> URL? {
        trava.lock(); defer { trava.unlock() }
        return aoVivo[item]
    }

    func transmissao(_ item: String) -> String? {
        trava.lock(); defer { trava.unlock() }
        return transmissoes[item]
    }

    /// Uma sessão nova para o item; a anterior, se havia, já acabou.
    func comecar(_ item: String) -> String {
        trava.lock(); defer { trava.unlock() }
        let nova = UUID().uuidString
        sessoes[item] = nova
        return nova
    }

    func sessao(_ item: String) -> String? {
        trava.lock(); defer { trava.unlock() }
        return sessoes[item]
    }

    func encerrar(_ item: String) {
        trava.lock(); defer { trava.unlock() }
        sessoes[item] = nil
        aoVivo[item] = nil
        transmissoes[item] = nil
    }

    /// Na conversão vai uma faixa de áudio só: a escolhida na página, pelo
    /// número que o servidor dá a ela.
    func pedirAudio(_ indice: Int?, para item: String) {
        trava.lock(); defer { trava.unlock() }
        audios[item] = indice
    }

    func audio(_ item: String) -> Int? {
        trava.lock(); defer { trava.unlock() }
        return audios[item]
    }
}

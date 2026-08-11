import Foundation
import Network

/// Procura servidores SMB na rede local.
///
/// Duas técnicas somadas, porque cada uma sozinha deixa buraco:
///
/// - **Bonjour** (`_smb._tcp`) acha quem se anuncia, e traz o nome legível da
///   máquina. Mas um Samba em Linux sem Avahi instalado não aparece.
/// - **Varredura da sub-rede na porta 445** acha qualquer coisa que aceite
///   conexão SMB, anunciando-se ou não. Em troca, só sabe o endereço.
///
/// Juntas cobrem o caso comum (NAS e Windows, que se anunciam) e o caso do
/// servidor caseiro em Linux, que costuma não se anunciar.
@MainActor
final class SMBDiscovery: ObservableObject {

    struct Found: Identifiable, Hashable {
        var id: String { host }
        var host: String
        /// Nome da máquina quando o Bonjour informa; senão, o próprio endereço.
        var name: String
        var viaBonjour: Bool
    }

    @Published private(set) var results: [Found] = []
    @Published private(set) var isSearching = false

    private var browser: NWBrowser?
    private var scanTask: Task<Void, Never>?

    /// Prazo por endereço na varredura. Curto de propósito: numa rede local,
    /// quem responde responde em milissegundos; esperar mais só faz a busca
    /// inteira demorar.
    private let timeout: TimeInterval = 1.2

    func start() {
        guard !isSearching else { return }
        isSearching = true
        results = []
        startBonjour()
        startSubnetScan()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        scanTask?.cancel()
        scanTask = nil
        isSearching = false
    }

    // MARK: - Bonjour

    private func startBonjour() {
        let parametros = NWParameters()
        parametros.includePeerToPeer = false

        let novo = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: parametros)
        novo.browseResultsChangedHandler = { [weak self] encontrados, _ in
            Task { @MainActor in
                for resultado in encontrados {
                    guard case .service(let nome, _, _, _) = resultado.endpoint else { continue }
                    // `.local` é como o mDNS resolve o nome anunciado — é isso
                    // que o cliente SMB vai usar para conectar.
                    self?.adicionar(Found(host: "\(nome).local", name: nome, viaBonjour: true))
                }
            }
        }
        novo.start(queue: .global(qos: .userInitiated))
        browser = novo
    }

    // MARK: - Varredura da sub-rede

    private func startSubnetScan() {
        guard let base = Self.prefixoDaRede() else {
            isSearching = false
            return
        }

        scanTask = Task { [weak self] in
            guard let self else { return }

            // 24 por vez: rápido o bastante para varrer 254 endereços em
            // segundos, e leve o bastante para não afogar o Wi-Fi.
            await withTaskGroup(of: String?.self) { grupo in
                var proximo = 1
                let limite = 24

                func enfileirar() {
                    guard proximo <= 254 else { return }
                    let endereco = "\(base).\(proximo)"
                    proximo += 1
                    grupo.addTask { await Self.responde(endereco, timeout: self.timeout) ? endereco : nil }
                }

                for _ in 0..<limite { enfileirar() }

                while let achado = await grupo.next() {
                    if let achado {
                        await MainActor.run {
                            self.adicionar(Found(host: achado, name: achado, viaBonjour: false))
                        }
                    }
                    enfileirar()
                }
            }

            await MainActor.run { self.isSearching = false }
        }
    }

    /// Uma conexão TCP que completa na porta 445 é um servidor SMB — não
    /// precisamos autenticar para saber que ele existe.
    private static func responde(_ host: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let conexao = NWConnection(host: NWEndpoint.Host(host), port: 445, using: .tcp)
            let respondeu = Respondeu()

            conexao.stateUpdateHandler = { estado in
                switch estado {
                case .ready:
                    if respondeu.marcar() { conexao.cancel(); continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if respondeu.marcar() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            conexao.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if respondeu.marcar() { conexao.cancel(); continuation.resume(returning: false) }
            }
        }
    }

    /// Trava para a continuação nunca ser retomada duas vezes — retomar duas
    /// vezes derruba o app, e aqui há três caminhos concorrendo: sucesso,
    /// falha e prazo esgotado.
    private final class Respondeu {
        private let lock = NSLock()
        private var usado = false
        func marcar() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if usado { return false }
            usado = true
            return true
        }
    }

    // MARK: - Auxiliares

    private func adicionar(_ novo: Found) {
        // O Bonjour tem prioridade: traz nome legível, e a varredura acharia o
        // mesmo servidor de novo, só que identificado pelo endereço.
        if let indice = results.firstIndex(where: { $0.host == novo.host }) {
            if novo.viaBonjour { results[indice] = novo }
            return
        }
        results.append(novo)
        results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Os três primeiros octetos do IP do aparelho na rede sem fio.
    private static func prefixoDaRede() -> String? {
        var ponteiro: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ponteiro) == 0, let inicio = ponteiro else { return nil }
        defer { freeifaddrs(ponteiro) }

        var atual: UnsafeMutablePointer<ifaddrs>? = inicio
        while let interface = atual {
            defer { atual = interface.pointee.ifa_next }

            let nome = String(cString: interface.pointee.ifa_name)
            // en0 é o Wi-Fi no iPhone; as demais são celular, VPN ou laço.
            guard nome == "en0",
                  interface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }

            var endereco = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.pointee.ifa_addr,
                        socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                        &endereco, socklen_t(endereco.count),
                        nil, 0, NI_NUMERICHOST)

            let ip = String(cString: endereco)
            let partes = ip.split(separator: ".")
            guard partes.count == 4 else { continue }
            return partes.prefix(3).joined(separator: ".")
        }
        return nil
    }
}

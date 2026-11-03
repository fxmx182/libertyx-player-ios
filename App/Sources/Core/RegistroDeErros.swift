import Foundation
import MetricKit
import UIKit
import VLCKit

/// O registro que a pessoa copia nos Ajustes e cola na conversa de suporte.
///
/// Sem Mac não há depurador, e o TestFlight só manda o relatório de
/// travamento quando alguém aceita compartilhar — o que quase nunca acontece.
/// Aqui fica, num arquivo do próprio app:
///
/// - o que o player fez: abrir, buscar, mudar a velocidade, os estados;
/// - os avisos e erros do próprio VLC;
/// - o relatório de travamento que o iOS entrega ao app (MetricKit) na
///   abertura seguinte, com a pilha de chamadas do momento em que fechou;
/// - quando a sessão anterior terminou de repente, sem passar pelo fundo —
///   que é como aparece um fechamento por falta de memória.
///
/// Só o fim do arquivo é guardado: o que interessa é o que veio logo antes
/// do problema.
final class RegistroDeErros: NSObject, @unchecked Sendable {

    static let shared = RegistroDeErros()

    private let fila = DispatchQueue(label: "libertyx.registro")
    private let arquivo: URL
    private let formato: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd/MM HH:mm:ss.SSS"
        return f
    }()

    /// Acima disto o arquivo é cortado e fica só a metade mais nova.
    private static let teto = 512 * 1024
    private static let sessaoAberta = "registro.sessaoAberta"

    /// Exigido pelo `VLCLogging`: só avisos e erros — o resto é ruído.
    @objc var level: VLCLogLevel = .warning

    /// O último aviso do VLC e quantas vezes ele já se repetiu seguido — o VLC
    /// manda o mesmo aviso centenas de vezes, e uma linha com a conta basta.
    private var ultimoDoVLC: String?
    private var repeticoes = 0

    private override init() {
        let pasta = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        arquivo = pasta.appendingPathComponent("registro-de-erros.txt")
        super.init()
    }

    /// Na abertura do app, antes do primeiro player: o VLC lê os registradores
    /// quando a biblioteca nasce.
    func iniciar() {
        aparar()
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.sessaoAberta) {
            anotar("⚠️ A sessão anterior terminou de repente, com o app na tela (travamento ou falta de memória).")
        }
        defaults.set(true, forKey: Self.sessaoAberta)
        anotar("── App aberto · LibertyX Player \(AppBuild.version) · \(AppBuild.commit) · iOS \(UIDevice.current.systemVersion) · \(Self.modelo())")

        let centro = NotificationCenter.default
        centro.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(false, forKey: Self.sessaoAberta)
        }
        centro.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: Self.sessaoAberta)
        }

        NSSetUncaughtExceptionHandler { excecao in
            RegistroDeErros.shared.anotarJa(
                "💥 Exceção: \(excecao.name.rawValue) — \(excecao.reason ?? "")\n"
                + excecao.callStackSymbols.joined(separator: "\n"))
        }

        VLCLibrary.shared().loggers = [self]

        MXMetricManager.shared.add(self)
        receber(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    // MARK: - Escrever

    /// Uma linha, com a hora na frente. Não espera a gravação.
    func anotar(_ texto: String) {
        let agora = Date()
        fila.async { self.gravar("\(self.formato.string(from: agora)) \(texto)\n") }
    }

    /// Para o momento em que o app está caindo: grava antes de voltar.
    private func anotarJa(_ texto: String) {
        let linha = "\(formato.string(from: Date())) \(texto)\n"
        fila.sync { gravar(linha) }
    }

    private func gravar(_ linha: String) {
        let dados = Data(linha.utf8)
        if let alca = try? FileHandle(forWritingTo: arquivo) {
            alca.seekToEndOfFile()
            alca.write(dados)
            try? alca.close()
        } else {
            try? dados.write(to: arquivo)
        }
    }

    /// Mantém só a metade mais nova quando o arquivo passa do teto.
    private func aparar() {
        fila.sync {
            guard let dados = try? Data(contentsOf: arquivo), dados.count > Self.teto else { return }
            var resto = dados.suffix(Self.teto / 2)
            // Começa numa linha inteira.
            if let quebra = resto.firstIndex(of: UInt8(ascii: "\n")) { resto = resto[(quebra + 1)...] }
            try? Data(resto).write(to: arquivo)
        }
    }

    // MARK: - Ler

    /// O registro inteiro, do mais antigo ao mais novo.
    func texto() -> String {
        fila.sync { (try? String(contentsOf: arquivo, encoding: .utf8)) ?? "" }
    }

    func limpar() {
        fila.sync { try? Data().write(to: arquivo) }
        anotar("── Registro limpo · LibertyX Player \(AppBuild.version) · \(AppBuild.commit)")
    }

    private static func modelo() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// MARK: - Avisos do VLC

extension RegistroDeErros: VLCLogging {
    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let tipo = level == .error ? "VLC erro" : "VLC aviso"
        let modulo = context.map { " [\($0.module)]" } ?? ""
        let texto = "\(tipo)\(modulo): \(message)"
        let agora = Date()
        fila.async {
            if texto == self.ultimoDoVLC {
                self.repeticoes += 1
                return
            }
            if self.repeticoes > 0 {
                self.gravar("\(self.formato.string(from: agora)) (o aviso acima se repetiu mais \(self.repeticoes)×)\n")
            }
            self.ultimoDoVLC = texto
            self.repeticoes = 0
            self.gravar("\(self.formato.string(from: agora)) \(texto)\n")
        }
    }
}

// MARK: - Relatórios de travamento do iOS

extension RegistroDeErros: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        receber(payloads)
    }

    private func receber(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for travamento in payload.crashDiagnostics ?? [] {
                let json = String(decoding: travamento.jsonRepresentation(), as: UTF8.self)
                anotar("💥 Travamento (relatório do iOS, \(formato.string(from: payload.timeStampEnd))):\n\(json)")
            }
            for travada in payload.hangDiagnostics ?? [] {
                let json = String(decoding: travada.jsonRepresentation(), as: UTF8.self)
                anotar("🧊 Tela travada (relatório do iOS):\n\(json)")
            }
        }
    }
}

import CryptoKit
import Foundation
import Security
import SwiftUI

/// O LibertyX Pro no iPhone: o mesmo do Android, com a mesma chave.
///
/// O app é grátis e completo como player. O Pro libera quatro coisas ([Recurso]); nos sete
/// primeiros dias elas vêm liberadas, para experimentar antes de pagar. Terminado o teste nada
/// some: bloqueia só o que é Pro.
///
/// **A compra é a chave LibertyX**, vendida com Bitcoin ou USDT pelo bot da loja no Telegram:
/// o app não está na App Store (é instalado pelo Sideloadly), então não há StoreKit. A chave é
/// conferida aqui, sem internet ([Chave]) — a mesma que vale no Android e na TV.
///
/// O início do teste e a chave ficam no **Keychain**, que sobrevive a apagar e reinstalar o app
/// (o que o Sideloadly faz a cada renovação da assinatura gratuita): reinstalar não recomeça o
/// teste nem perde a compra.
@MainActor
final class Pro: ObservableObject {

    static let shared = Pro()

    /// O que o Pro libera. A ordem é a da tela de compra.
    enum Recurso: String, CaseIterable, Identifiable {
        case rede, segundoPlano, dormir, captura
        var id: String { rawValue }
    }

    enum Estado: Equatable {
        case comprado
        case teste(diasRestantes: Int)
        case expirado
    }

    static let diasDeTeste = 7

    @Published private(set) var estado: Estado = .expirado

    /// Liberado agora, seja pela chave, seja pelo teste.
    var ativo: Bool { estado != .expirado }

    private init() {
        if Keychain.ler(Chaves.inicio) == nil {
            Keychain.gravar(Chaves.inicio, String(Date().timeIntervalSince1970))
        }
        recalcular()
    }

    func recalcular() {
        if let texto = Keychain.ler(Chaves.chave), case .valida = Chave.conferir(texto) {
            estado = .comprado
            return
        }
        let inicio = Keychain.ler(Chaves.inicio).flatMap(Double.init) ?? Date().timeIntervalSince1970
        // Relógio atrasado não vira dia negativo nem teste maior.
        let passados = Int(max(0, Date().timeIntervalSince1970 - inicio) / 86_400)
        let restam = Self.diasDeTeste - passados
        estado = restam > 0 ? .teste(diasRestantes: restam) : .expirado
    }

    /// Ativa o Pro com a chave do Telegram. Guarda a chave inteira, não um "ativado": a cada
    /// abertura ela é conferida de novo.
    @discardableResult
    func ativar(_ texto: String) -> Chave.Resultado {
        let r = Chave.conferir(texto)
        if case .valida(_, let normalizada) = r {
            Keychain.gravar(Chaves.chave, normalizada)
            recalcular()
        }
        return r
    }

    /// O número da licença ativada (para mostrar), ou nil sem chave.
    var licenca: String? {
        guard let texto = Keychain.ler(Chaves.chave), case .valida(let id, _) = Chave.conferir(texto) else { return nil }
        return id
    }

    private enum Chaves {
        static let inicio = "pro.inicioDoTeste"
        static let chave = "pro.chave"
    }
}

/// A chave LibertyX: "LXP1-" + base32 Crockford de 12 bytes de dados e 64 de assinatura ECDSA
/// P-256 (r‖s). Os dados: versão (1), produto (1 Partition, 2 Player, 3 Folder, 9 pacote), dias
/// desde 2026-01-01 e o número da licença. Mesmo formato e mesma chave pública do Partition e do
/// Android — o app só tem a pública e confere sozinho.
enum Chave {

    /// O produto deste app; o pacote (9) também vale.
    static let produto: UInt8 = 2
    private static let pacote: UInt8 = 9

    private static let prefixo = "LXP1"
    private static let alfabeto = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ") // Crockford: sem I, L, O, U
    // A pública em SubjectPublicKeyInfo (DER), em hexadecimal.
    private static let publica =
        "3059301306072a8648ce3d020106082a8648ce3d030107034200041a9bd4b8" +
        "1a7c8fce09fff6a52ed05fadc56b3856dfd038433887339dd045c02b1a3884" +
        "7aa8129f5d6a5336e5a805d5c8597cda3e6a53eb443cd135e050246c47"

    enum Erro { case formato, invalida, outroApp, versao }

    enum Resultado: Equatable {
        /// `id`: o número da licença em hexadecimal, como no registro do bot.
        case valida(id: String, texto: String)
        case recusada(Erro)
    }

    static func conferir(_ texto: String) -> Resultado {
        let s = normalizar(texto)
        guard s.hasPrefix(prefixo), let bruto = decodificar(String(s.dropFirst(prefixo.count))), bruto.count == 76 else {
            return .recusada(.formato)
        }
        let dados = bruto.prefix(12)
        let assinatura = bruto.suffix(64)
        guard let chave = try? P256.Signing.PublicKey(derRepresentation: hex(publica)),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: assinatura),
              chave.isValidSignature(sig, for: dados) else {
            return .recusada(.invalida)
        }
        let d = Array(dados)
        guard d[0] == 1 else { return .recusada(.versao) }
        if [1, 2, 3].contains(d[1]) && d[1] != produto { return .recusada(.outroApp) }
        guard d[1] == produto || d[1] == pacote else { return .recusada(.versao) }
        let id = d[4..<12].map { String(format: "%02X", $0) }.joined()
        return .valida(id: id, texto: s)
    }

    /// Maiúsculas, sem traços nem espaços, e O→0, I/L→1 (o Crockford não usa essas letras); o
    /// prefixo tem um L de verdade, então a troca é desfeita só nele.
    private static func normalizar(_ t: String) -> String {
        var s = ""
        for c in t.uppercased() {
            switch c {
            case "-", " ", "\t", "\r", "\n": continue
            case "O": s.append("0")
            case "I", "L": s.append("1")
            default: s.append(c)
            }
        }
        return s.hasPrefix("1XP1") ? prefixo + s.dropFirst(4) : s
    }

    private static func decodificar(_ s: String) -> Data? {
        var saida = Data()
        var acc = 0, bits = 0
        for c in s {
            guard let v = alfabeto.firstIndex(of: c) else { return nil }
            acc = (acc << 5) | v
            bits += 5
            if bits >= 8 {
                saida.append(UInt8((acc >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            acc &= (1 << bits) - 1
        }
        return saida
    }

    private static func hex(_ s: String) -> Data {
        var d = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
}

/// Um par chave/valor no Keychain do aparelho (sobrevive a reinstalar o app).
private enum Keychain {
    private static let servico = "com.mauricio.labplayer.pro"

    static func ler(_ conta: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: servico,
                                kSecAttrAccount as String: conta, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func gravar(_ conta: String, _ valor: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: servico,
                                kSecAttrAccount as String: conta]
        SecItemDelete(q as CFDictionary)
        var novo = q
        novo[kSecValueData as String] = Data(valor.utf8)
        novo[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(novo as CFDictionary, nil)
    }
}

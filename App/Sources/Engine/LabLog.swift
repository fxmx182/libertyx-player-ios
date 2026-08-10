import Foundation
import os

/// Registro do motor, legível pelo log do sistema.
///
/// Existe porque o aparelho é o único ambiente de teste real deste projeto: sem
/// macOS, não há depurador. Quando algo trava, o log é o que diz em qual etapa
/// parou — abrir, decodificar, sincronizar — em vez de deixar isso para
/// dedução.
enum LabLog {

    private static let engine = Logger(subsystem: "com.mauricio.labplayer", category: "engine")

    static func open(_ message: String) {
        engine.notice("[abrir] \(message, privacy: .public)")
    }

    static func loop(_ message: String) {
        engine.notice("[laço] \(message, privacy: .public)")
    }

    static func problem(_ message: String) {
        engine.error("[erro] \(message, privacy: .public)")
    }
}

import SwiftUI

/// O registro de erros, para copiar e colar na conversa de suporte (ver
/// `RegistroDeErros`). O mais novo fica embaixo, como num chat; a tela já abre
/// lá, que é onde está o que acabou de acontecer.
struct RegistroDeErrosView: View {
    @State private var texto = ""
    @State private var copiado = false

    /// O que vai para a área de transferência: o fim do registro. Colar meio
    /// megabyte numa conversa não ajuda ninguém; o que importa é o que veio
    /// logo antes do problema.
    private static let tetoDaCopia = 60_000

    var body: some View {
        ScrollViewReader { rolagem in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Se algo deu errado, toque em Copiar e cole a mensagem na conversa de suporte. As senhas não aparecem aqui.")
                        .font(LabFont.swiftUI(13, .medium))
                        .foregroundStyle(LabTheme.muted)
                    Text(verbatim: texto.isEmpty ? String(localized: "Nada registrado ainda.") : texto)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LabTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .labCard(radius: 12)
                    Color.clear.frame(height: 1).id("fim")
                }
                .padding(16)
            }
            .onAppear {
                texto = RegistroDeErros.shared.texto()
                DispatchQueue.main.async { rolagem.scrollTo("fim", anchor: .bottom) }
            }
        }
        .navigationTitle("Registro de erros")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copiado ? String(localized: "Copiado") : String(localized: "Copiar")) {
                    UIPasteboard.general.string = String(texto.suffix(Self.tetoDaCopia))
                    copiado = true
                }
                .disabled(texto.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Limpar", role: .destructive) {
                    RegistroDeErros.shared.limpar()
                    texto = ""
                    copiado = false
                }
            }
        }
    }
}

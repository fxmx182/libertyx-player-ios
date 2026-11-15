import SwiftUI

/// O registro de erros, para copiar e colar na conversa de suporte (ver
/// `RegistroDeErros`). O mais novo fica embaixo, como num chat; a tela já abre
/// lá, que é onde está o que acabou de acontecer.
struct RegistroDeErrosView: View {
    @State private var texto = ""
    /// As linhas mostradas: só as do fim (ver `tetoDeLinhas`).
    @State private var linhas: [String] = []

    /// Quantas linhas a tela mostra. O resto continua no registro e vai junto
    /// na cópia; na tela, o que importa é o que veio por último.
    private static let tetoDeLinhas = 3000
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
                    // Linha a linha e preguiçoso: o registro chega a 512 KB, e
                    // num Text só o iPhone levava segundos montando o texto com
                    // a tela travada — fechar o app nessa hora virava falha
                    // (0x8BADF00D, build 80). Só as linhas visíveis são montadas.
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if linhas.isEmpty {
                            Text("Nada registrado ainda.")
                        }
                        ForEach(linhas.indices, id: \.self) { i in
                            Text(verbatim: linhas[i])
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LabTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .labCard(radius: 12)
                    Color.clear.frame(height: 1).id("fim")
                }
                .padding(16)
            }
            .onAppear {
                texto = RegistroDeErros.shared.texto()
                linhas = Array(texto.split(separator: "\n", omittingEmptySubsequences: false)
                    .suffix(Self.tetoDeLinhas).map(String.init))
                if linhas.last?.isEmpty == true { linhas.removeLast() }
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
                    linhas = []
                    copiado = false
                }
            }
        }
    }
}

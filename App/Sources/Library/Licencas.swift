import SwiftUI

/// O que vai dentro do app e sob que licença.
///
/// A que obriga é a do VLC e a do FFmpeg (LGPL): quem distribui o app precisa
/// dizer que eles estão lá, entregar o texto da licença e apontar onde está o
/// código-fonte. As outras (MIT, OFL) pedem o aviso e o texto, e é o que esta
/// tela dá. A mesma do Android, com as peças do iPhone.
struct LicencasView: View {

    private struct Componente: Identifiable {
        let nome: String
        let autor: String
        let licenca: String
        let arquivo: String
        let fonte: String
        var id: String { nome }
    }

    private let componentes = [
        Componente(nome: "VLCKit 3.6", autor: "VideoLAN", licenca: "LGPL 2.1+",
                   arquivo: "LGPL-2.1", fonte: "https://code.videolan.org/videolan/VLCKit"),
        Componente(nome: "FFmpeg 7.1", autor: "FFmpeg", licenca: "LGPL 2.1+",
                   arquivo: "LGPL-2.1", fonte: "https://ffmpeg.org"),
        Componente(nome: "SMBClient", autor: "Kishikawa Katsumi", licenca: "MIT",
                   arquivo: "MIT", fonte: "https://github.com/kishikawakatsumi/SMBClient"),
        Componente(nome: "Manrope", autor: "The Manrope Project Authors", licenca: "SIL OFL 1.1",
                   arquivo: "OFL-1.1", fonte: "https://github.com/googlefonts/manrope"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("O LibertyX é feito sobre estes projetos de código aberto. Toque num deles para ler a licença.")
                    .font(LabFont.swiftUI(13, .medium))
                    .foregroundStyle(LabTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)

                ForEach(componentes) { c in
                    NavigationLink {
                        TextoDaLicenca(arquivo: c.arquivo)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: c.nome)
                                .font(LabFont.swiftUI(15, .bold))
                                .foregroundStyle(LabTheme.text)
                            Text(verbatim: "\(c.autor) · \(c.licenca)")
                                .font(LabFont.swiftUI(12, .semibold))
                                .foregroundStyle(LabTheme.accent)
                            Text(verbatim: c.fonte)
                                .font(LabFont.swiftUI(12, .medium))
                                .foregroundStyle(LabTheme.faint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .labCard(radius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("Licenças de código aberto")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TextoDaLicenca: View {
    let arquivo: String

    var body: some View {
        ScrollView {
            Text(verbatim: texto)
                .font(.system(size: 13))
                .foregroundStyle(LabTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .textSelection(.enabled)
        }
        .navigationTitle(Text(verbatim: arquivo))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Os textos vêm quebrados em 80 colunas, para terminal. Num celular isso
    /// vira linha longa, linha curta, linha longa: aqui cada parágrafo volta a
    /// ser um só e flui na largura.
    private var texto: String {
        guard let url = Bundle.main.url(forResource: arquivo, withExtension: "txt"),
              let bruto = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        // Linha em branco (inclusive a que só tem espaços) separa parágrafos;
        // as demais se juntam à anterior.
        var paragrafos: [String] = []
        var atual: [String] = []
        for linha in bruto.components(separatedBy: .newlines) {
            let limpa = linha.trimmingCharacters(in: .whitespaces)
            if limpa.isEmpty {
                if !atual.isEmpty { paragrafos.append(atual.joined(separator: " ")) }
                atual = []
            } else {
                atual.append(limpa)
            }
        }
        if !atual.isEmpty { paragrafos.append(atual.joined(separator: " ")) }
        return paragrafos.joined(separator: "\n\n")
    }
}

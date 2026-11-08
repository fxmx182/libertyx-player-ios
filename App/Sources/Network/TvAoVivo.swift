import SwiftUI

/// Abre um canal e entrega o item do player. O servidor precisa abrir a
/// transmissão antes (ver `ServidorDeMidia.abrirCanal`); o endereço fica em
/// `Conversoes`, onde o motor o procura.
@MainActor
func prepararCanal(_ servidor: ServidorDeMidia, _ canal: ServidorDeMidia.Canal) async throws -> MediaItem {
    let aberto = try await servidor.abrirCanal(canal.id)
    Conversoes.shared.registrarCanal(canal.id, url: aberto.url, sessao: aberto.sessao, transmissao: aberto.transmissao)
    let item = MediaItem(title: canal.nome, origin: .midia(conta: servidor.conta.id, item: canal.id))
    // Ao vivo não tem "onde parou": nunca pergunta, sempre entra no agora.
    EscolhaDeFaixas.shared.pedirInicio(.doComeco, para: item.origin.resumeKey)
    return item
}

/// O logotipo do canal inteiro, sobre o cartão escuro — logotipo de emissora
/// é largo e transparente, e cortado para preencher perderia o nome.
struct LogoDoCanal: View {
    let servidor: ServidorDeMidia
    let canal: ServidorDeMidia.Canal

    @State private var imagem: UIImage?

    var body: some View {
        LinearGradient(colors: [Color(red: 0.137, green: 0.133, blue: 0.157),
                                Color(red: 0.086, green: 0.086, blue: 0.102)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if let imagem {
                    Image(uiImage: imagem).resizable().scaledToFit().padding(12)
                } else {
                    Text(verbatim: canal.numero ?? String(canal.nome.prefix(3)))
                        .font(LabFont.swiftUI(18, .heavy))
                        .foregroundStyle(LabTheme.faint)
                }
            }
            .task(id: canal.id) {
                if case .imagem(let baixada) = await servidor.baixarImagem(canal.id, tipos: ["Primary"], largura: 320) {
                    imagem = baixada
                }
            }
    }
}

/// O cartão da faixa: o logotipo, o canal e o que está passando.
struct CartaoDeCanal: View {
    var escala = Escala()
    let servidor: ServidorDeMidia
    let canal: ServidorDeMidia.Canal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogoDoCanal(servidor: servidor, canal: canal)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) { BarraDeProgresso(progresso: canal.programa?.andamento()) }
                .overlay(alignment: .topLeading) { SeloAoVivo().padding(6) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(LabTheme.glassBorder, lineWidth: 0.5))
            Text(verbatim: [canal.numero, canal.nome].compactMap { $0 }.joined(separator: " · "))
                .font(LabFont.swiftUI(13, .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .padding(.top, 8)
            Text(verbatim: canal.programa?.nome ?? " ")
                .font(LabFont.swiftUI(11, .medium))
                .foregroundStyle(LabTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 200 * escala.fator)
        .contentShape(Rectangle())
    }
}

/// "AO VIVO" em vermelho, como em toda TV.
struct SeloAoVivo: View {
    var body: some View {
        Text("AO VIVO")
            .font(LabFont.swiftUI(9.5, .heavy))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(LabTheme.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Todos os canais, com o programa de agora, o horário e quanto já passou.
struct TvAoVivoView: View {
    let servidor: ServidorDeMidia

    @State private var canais: [ServidorDeMidia.Canal] = []
    @State private var carregando = true
    @State private var falha: String?
    @State private var tocando: MediaItem?
    @State private var abrindo: String?

    var body: some View {
        List {
            ForEach(canais) { canal in
                Button { tocar(canal) } label: { linha(canal) }
                    .buttonStyle(.plain)
                    .linhaDeVidro()
            }
        }
        .listStyle(.plain)
        .fundoDaRede()
        .overlay {
            if carregando && canais.isEmpty {
                ProgressView("Lendo…")
            } else if !carregando && canais.isEmpty {
                ContentUnavailableView("Nenhum canal", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .navigationTitle(String(localized: "TV ao vivo"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await carregar() }
        .refreshable { await carregar() }
        .fullScreenCover(item: $tocando) { item in
            PlayerScreen(item: item, playlist: [item]).ignoresSafeArea()
        }
        .alert("Não conectou", isPresented: Binding(get: { falha != nil }, set: { if !$0 { falha = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(falha ?? "")
        }
    }

    private func linha(_ canal: ServidorDeMidia.Canal) -> some View {
        HStack(spacing: 14) {
            LogoDoCanal(servidor: servidor, canal: canal)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: [canal.numero, canal.nome].compactMap { $0 }.joined(separator: " · "))
                    .font(LabFont.swiftUI(14, .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                if let programa = canal.programa {
                    Text(verbatim: programa.nome)
                        .font(LabFont.swiftUI(12.5, .medium))
                        .foregroundStyle(LabTheme.muted)
                        .lineLimit(1)
                    if let inicio = programa.inicio, let fim = programa.fim {
                        HStack(spacing: 8) {
                            Text(verbatim: inicio.formatted(date: .omitted, time: .shortened) + " – "
                                 + fim.formatted(date: .omitted, time: .shortened))
                                .font(LabFont.swiftUI(11, .medium))
                                .foregroundStyle(LabTheme.faint)
                            BarraDeProgresso(progresso: programa.andamento())
                                .frame(maxWidth: 90)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if abrindo == canal.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func tocar(_ canal: ServidorDeMidia.Canal) {
        guard abrindo == nil else { return }
        abrindo = canal.id
        Task { @MainActor in
            defer { abrindo = nil }
            do {
                tocando = try await prepararCanal(servidor, canal)
            } catch where error.foiCancelado {
                return
            } catch {
                falha = error.localizedDescription
            }
        }
    }

    private func carregar() async {
        do {
            canais = try await servidor.canais()
            falha = nil
        } catch where error.foiCancelado {
            return
        } catch {
            if canais.isEmpty { falha = error.localizedDescription }
        }
        carregando = false
    }
}

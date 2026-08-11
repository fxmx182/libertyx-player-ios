import SwiftUI

enum LibraryLayout: String, CaseIterable {
    case list, grid

    var label: String { self == .list ? "Lista" : "Grade" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

enum LibrarySort: String, CaseIterable {
    case title, date, size, duration

    var label: String {
        switch self {
        case .title:    return "Título"
        case .date:     return "Data"
        case .size:     return "Tamanho"
        case .duration: return "Duração"
        }
    }

    var symbol: String {
        switch self {
        case .title:    return "textformat.abc"
        case .date:     return "calendar"
        case .size:     return "externaldrive"
        case .duration: return "clock"
        }
    }
}

/// Como a biblioteca é exibida. Preferência do usuário, guardada entre sessões
/// — trocar de modo a cada abertura do app seria pior que não ter a opção.
@MainActor
final class LibraryOptions: ObservableObject {

    static let shared = LibraryOptions()

    @Published var layout: LibraryLayout { didSet { salvar() } }
    @Published var sort: LibrarySort { didSet { salvar() } }
    @Published var ascending: Bool { didSet { salvar() } }

    private init() {
        let padroes = UserDefaults.standard
        layout = LibraryLayout(rawValue: padroes.string(forKey: "labplayer.layout") ?? "") ?? .grid
        sort = LibrarySort(rawValue: padroes.string(forKey: "labplayer.sort") ?? "") ?? .title
        // Título e tamanho fazem sentido do menor para o maior; data e duração,
        // do mais recente e mais longo. Mas a escolha é do usuário, e fica.
        ascending = padroes.object(forKey: "labplayer.ascending") as? Bool ?? true
    }

    private func salvar() {
        let padroes = UserDefaults.standard
        padroes.set(layout.rawValue, forKey: "labplayer.layout")
        padroes.set(sort.rawValue, forKey: "labplayer.sort")
        padroes.set(ascending, forKey: "labplayer.ascending")
    }

    func sorted(_ itens: [MediaItem]) -> [MediaItem] {
        let ordenados = itens.sorted { esquerda, direita in
            switch sort {
            case .title:
                // Ordem natural: "Ep 2" antes de "Ep 10".
                return esquerda.title.localizedStandardCompare(direita.title) == .orderedAscending
            case .date:
                return (esquerda.modifiedAt ?? .distantPast) < (direita.modifiedAt ?? .distantPast)
            case .size:
                return (esquerda.fileSize ?? 0) < (direita.fileSize ?? 0)
            case .duration:
                // Sem miniatura gerada ainda não há duração conhecida; esses
                // ficam juntos no fim em vez de embaralhar a lista.
                let a = ThumbnailStore.shared.duration(esquerda) ?? .greatestFiniteMagnitude
                let b = ThumbnailStore.shared.duration(direita) ?? .greatestFiniteMagnitude
                return a < b
            }
        }
        return ascending ? ordenados : ordenados.reversed()
    }
}

/// Folha de opções, no espírito da do MX Player.
struct LibraryOptionsSheet: View {

    @ObservedObject var options: LibraryOptions
    @Environment(\.dismiss) private var dismiss

    private let colunas = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    secao("Layout") {
                        LazyVGrid(columns: colunas, spacing: 12) {
                            ForEach(LibraryLayout.allCases, id: \.self) { opcao in
                                botao(opcao.label, symbol: opcao.symbol,
                                      ativo: options.layout == opcao) {
                                    options.layout = opcao
                                }
                            }
                        }
                    }

                    secao("Ordenar") {
                        LazyVGrid(columns: colunas, spacing: 12) {
                            ForEach(LibrarySort.allCases, id: \.self) { opcao in
                                botao(opcao.label, symbol: opcao.symbol,
                                      ativo: options.sort == opcao) {
                                    options.sort = opcao
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            direcao("Crescente", symbol: "arrow.up", ativo: options.ascending) {
                                options.ascending = true
                            }
                            direcao("Decrescente", symbol: "arrow.down", ativo: !options.ascending) {
                                options.ascending = false
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Visualização")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Concluído") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func secao<Conteudo: View>(_ titulo: String,
                                       @ViewBuilder content: () -> Conteudo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titulo).font(.headline)
            content()
        }
    }

    private func botao(_ titulo: String, symbol: String,
                       ativo: Bool, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(titulo).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(ativo ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(ativo ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func direcao(_ titulo: String, symbol: String,
                         ativo: Bool, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Label(titulo, systemImage: symbol)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(ativo ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(ativo ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

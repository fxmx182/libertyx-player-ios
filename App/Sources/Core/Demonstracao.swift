import Foundation

/// Um filme para quem ainda não tem nenhum.
///
/// Quem acaba de instalar — e o revisor da loja — encontra o app sem pasta
/// alguma e o servidor de casa ainda por conectar: sem isto, o player não
/// teria o que mostrar. Sintel é filme aberto da Blender (CC-BY), em MKV com
/// áudio AC-3 e legendas em dez idiomas, o que exercita de uma vez o que o app
/// sabe fazer. Toca direto do servidor da Blender, sem copiar nada.
enum Demonstracao {

    static let item = MediaItem(
        title: "Sintel",
        origin: .remote(url: URL(string: "https://download.blender.org/demo/movies/Sintel.2010.1080p.mkv")!),
        duration: 888)

    static let credito = "Blender Foundation · CC-BY"
}

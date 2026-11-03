// swift-tools-version:5.9
import PackageDescription

// O MobileVLCKit 3.7.5 — o mesmo libVLC 3.7.5 do app Android, versão estável.
//
// Houve aqui o VLCKit 4 (4.0.0a25), pela janela flutuante, e ele foi a causa
// do app fechar ao buscar e retomar pela rede: a VideoLAN só o publica como
// prévia, compilada com as verificações de depuração do VLC ligadas, e uma
// delas que falhe derruba o app inteiro. O 4 volta quando sair estável.
//
// O arquivo da VideoLAN é grande demais para o repositório: o CI o baixa e
// confere a soma antes de compilar (Scripts/baixar-vlckit.sh).
let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "VLCKit", targets: ["MobileVLCKit"])],
    targets: [
        .binaryTarget(name: "MobileVLCKit", path: "MobileVLCKit.xcframework"),
    ]
)

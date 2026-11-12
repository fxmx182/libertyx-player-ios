// swift-tools-version:5.9
import PackageDescription

// O VLCKit 4, compilado por nós (Scripts/compilar-vlckit4.sh): é a versão que
// traz a janela flutuante (PiP), e a única do VLC que faz isso no iPhone.
//
// Houve aqui o VLCKit 4 da VideoLAN (4.0.0a25) em 03/11/2026, e ele fechava o
// app ao buscar e retomar pela rede: a VideoLAN só publica o 4 como prévia,
// compilada sem `-r`, com as verificações de depuração do núcleo do VLC
// ligadas, e uma delas que falhe derruba o app inteiro. O app voltou ao
// MobileVLCKit 3.7.5 até haver isto: o mesmo código, compilado em Release.
//
// O xcframework é grande demais para o repositório: o CI o baixa do release
// vlckit4-<tag> e confere a soma antes de compilar (Scripts/baixar-vlckit.sh).
let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "VLCKit", targets: ["VLCKit"])],
    targets: [
        .binaryTarget(name: "VLCKit", path: "VLCKit.xcframework"),
    ]
)

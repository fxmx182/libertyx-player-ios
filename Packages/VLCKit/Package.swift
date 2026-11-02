// swift-tools-version:5.9
import PackageDescription

// O VLCKit 4, o mesmo que o app do VLC para iPhone usa — é a versão que traz
// a janela flutuante (PiP). A VideoLAN ainda o publica como "unstable" e só
// pelo CocoaPods; este pacote aponta para o mesmo arquivo que o podspec
// (VLCKit 4.0.0a25) e confere a soma dele.
let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "VLCKit", targets: ["VLCKit"])],
    targets: [
        .binaryTarget(
            name: "VLCKit",
            url: "https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip",
            checksum: "f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb"
        ),
    ]
)

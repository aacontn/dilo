// swift-tools-version: 6.2
import PackageDescription

// Todo lo que es de Dilo vive acá, fuera del árbol que viene de Talkify, para
// que `git merge upstream/main` siga siendo barato y para poder correr
// `swift test` sin abrir Xcode. Un módulo por tema; la app los enlaza.
let package = Package(
  name: "DiloCore",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DiloText", targets: ["DiloText"])
  ],
  targets: [
    .target(name: "DiloText"),
    .testTarget(name: "DiloTextTests", dependencies: ["DiloText"]),
  ]
)

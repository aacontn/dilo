// swift-tools-version: 6.2
import PackageDescription

// Todo lo que es de Dilo vive acá, fuera del árbol que viene de Talkify, para
// que `git merge upstream/main` siga siendo barato y para poder correr
// `swift test` sin abrir Xcode. Un módulo por tema; la app los enlaza.
let package = Package(
  name: "DiloCore",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DiloText", targets: ["DiloText"]),
    .library(name: "DiloEngines", targets: ["DiloEngines"]),
  ],
  dependencies: [
    // Parakeet TDT v3 (int8) en Core ML. Apache 2.0. Se fija por versión
    // exacta: el paquete trae modelos que se bajan en runtime y una API que
    // todavía se mueve semana a semana.
    //
    // `traits: []` apaga `NemoTextProcessing`, un staticlib de Rust
    // (~8 MB por slice) que sólo sirve a los frontends de TTS. Dilo no hace
    // TTS con FluidAudio y el `.app` tiene que pesar menos de 20 MB (spec §3).
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      exact: "0.15.8",
      traits: []
    )
  ],
  targets: [
    .target(name: "DiloText"),
    .target(
      name: "DiloEngines",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
    ),
    .testTarget(name: "DiloTextTests", dependencies: ["DiloText"]),
    .testTarget(name: "DiloEnginesTests", dependencies: ["DiloEngines"]),
  ]
)

// swift-tools-version: 6.2
import PackageDescription

// El banco de voces de «Leer en voz alta»: sintetiza las mismas frases con
// cada motor y cada voz, mide carga, primer audio, factor de tiempo real y
// RAM, y transcribe de vuelta con Parakeet para el WER. Es taller: la app no
// lo enlaza, y por eso tiene su propio paquete en vez de un target en
// `DiloCore` (`scripts/taller-voces.sh` lo compila con DerivedData en SSD2).
let package = Package(
  name: "taller-voces",
  platforms: [.macOS(.v26)],
  dependencies: [
    // Con `TTS`, que en el banco hace falta entero: PocketTTS y Supertonic.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: ["TTS"]),
    // La normalización y el troceo son los de la app, no una copia.
    .package(path: "../../DiloCore"),
  ],
  targets: [
    .executableTarget(
      name: "taller-voces",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "DiloText", package: "DiloCore"),
        .product(name: "DiloEngines", package: "DiloCore"),
      ]
    )
  ]
)

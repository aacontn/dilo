// swift-tools-version: 6.2
import PackageDescription

// Todo lo que es de Dilo vive acá, fuera del árbol que viene de origen, para
// que `git merge upstream/main` siga siendo barato y para poder correr
// `swift test` sin abrir Xcode. Un módulo por tema; la app los enlaza.
//
// `DiloModes` viaja dentro del producto `DiloText` en vez de tener el suyo:
// un producto nuevo obliga a tocar `packageProductDependencies` de los dos
// targets en `project.pbxproj`, y ese archivo está congelado mientras hay
// varias ramas abiertas en paralelo (un conflicto ahí es un merge a mano).
// El módulo, su carpeta y sus tests sí son propios; lo único compartido es la
// línea del producto. Cuando alguien vuelva a abrir el `.pbxproj` —Tarea 8—
// se separa en `.library(name: "DiloModes", targets: ["DiloModes"])`.
// `DiloConsumo` —los datos que la muesca muestra a sus costados— viaja igual
// y por lo mismo.
let package = Package(
  name: "DiloCore",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DiloText", targets: ["DiloText", "DiloModes", "DiloConsumo"]),
    .library(name: "DiloCapabilities", targets: ["DiloCapabilities"]),
    .library(name: "DiloEngines", targets: ["DiloEngines"]),
    .library(name: "DiloMetrics", targets: ["DiloMetrics"]),
    // La herramienta que mide los números del spec §3 contra un `.app` ya
    // compilado. Es de taller, no de producto: `scripts/metrics.sh` la
    // construye y la corre, y la app no la enlaza.
    .executable(name: "dilo-metrics", targets: ["dilo-metrics"]),
  ],
  dependencies: [
    // Parakeet TDT v3 (int8) en Core ML. Apache 2.0. Se fija por versión
    // exacta: el paquete trae modelos que se bajan en runtime y una API que
    // todavía se mueve semana a semana.
    //
    // `traits: []` apaga `NemoTextProcessing`, un staticlib de Rust
    // (~8 MB por slice) que sólo sirve a los frontends de TTS. Dilo no hace
    // TTS con FluidAudio y el `.app` tiene que pesar menos de 25 MB (spec §3).
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      exact: "0.15.8",
      traits: []
    )
  ],
  targets: [
    .target(name: "DiloText"),
    .target(name: "DiloModes"),
    .target(name: "DiloConsumo"),
    .target(name: "DiloCapabilities"),
    .target(
      name: "DiloEngines",
      dependencies: [
        // La regla de cómo se pegan dos trozos de dictado vive una sola vez,
        // en `DiloText.Union`, y la usan los motores y la app.
        "DiloText",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ]
    ),
    .target(name: "DiloMetrics"),
    .executableTarget(name: "dilo-metrics", dependencies: ["DiloMetrics"]),
    .testTarget(name: "DiloTextTests", dependencies: ["DiloText"]),
    .testTarget(name: "DiloModesTests", dependencies: ["DiloModes"]),
    .testTarget(name: "DiloConsumoTests", dependencies: ["DiloConsumo"]),
    .testTarget(name: "DiloCapabilitiesTests", dependencies: ["DiloCapabilities"]),
    .testTarget(name: "DiloEnginesTests", dependencies: ["DiloEngines", "DiloText"]),
    .testTarget(name: "DiloMetricsTests", dependencies: ["DiloMetrics"]),
  ]
)

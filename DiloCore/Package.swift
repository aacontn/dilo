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
// y por lo mismo, y también `DiloAgentes` —el servidor MCP y el CLI que el
// mismo binario de la app atiende con `--mcp` o como `dilo`— y `DiloPlataforma`
// —el URL scheme, los agentes que avisan por su *hook* y lo que llega de
// Atajos— (fase 5, 2026-10-15).
let package = Package(
  name: "DiloCore",
  platforms: [.macOS(.v26)],
  products: [
    .library(
      name: "DiloText",
      targets: ["DiloText", "DiloModes", "DiloConsumo", "DiloAgentes", "DiloPlataforma", "DiloReuniones"]
    ),
    .library(name: "DiloCapabilities", targets: ["DiloCapabilities"]),
    .library(name: "DiloEngines", targets: ["DiloEngines", "DiloHablantes"]),
    .library(name: "DiloMetrics", targets: ["DiloMetrics"]),
    // La herramienta que mide los números del spec §3 contra un `.app` ya
    // compilado. Es de taller, no de producto: `scripts/metrics.sh` la
    // construye y la corre, y la app no la enlaza.
    .executable(name: "dilo-metrics", targets: ["dilo-metrics"]),
    // El banco que compara Parakeet v3, Ultra y Nemotron sobre dictados
    // reales: tiempo por archivo y WER contra un `.txt` al lado. También de
    // taller: `scripts/comparar-motores.sh` lo construye y la app no lo enlaza.
    .executable(name: "dilo-comparar-motores", targets: ["dilo-comparar-motores"]),
    .executable(name: "dilo-banco-reuniones", targets: ["dilo-banco-reuniones"]),
  ],
  dependencies: [
    // Parakeet TDT v3 y Ultra (int8) en Core ML. Apache 2.0. Se fija por
    // versión exacta: el paquete trae modelos que se bajan en runtime y una
    // API que todavía se mueve semana a semana.
    //
    // Desde la 0.18 los traits eligen qué subsistemas se compilan. Apagado:
    // `NemoTextProcessing`, un staticlib de Rust (~8 MB por slice) que no cabe
    // en los 25 MB del `.app` (spec §3) —los números hablados ya los resuelve
    // `DiloText`—. Cada subsistema entra con la función que lo usa:
    // `Diarizer` con Reuniones (Nemotron 3, Sortformer, LS-EEND, VBx);
    // `TTS`, todavía no.
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      exact: "0.18.0",
      traits: ["Diarizer"]
    )
  ],
  targets: [
    .target(name: "DiloText"),
    .target(name: "DiloModes"),
    .target(name: "DiloConsumo"),
    // `DiloAgentes` lee las reuniones del disco para el MCP y el CLI; lo que
    // lee es puro y no arrastra FluidAudio. Desde el 2026-10-30 también es el
    // lado cliente: el cliente MCP por stdio y el destino `.dilo` de la
    // **Conversación**, que habla con Claude con herramientas y por eso usa el
    // contrato y el cliente de `DiloModes`.
    .target(name: "DiloAgentes", dependencies: ["DiloReuniones", "DiloModes"]),
    .target(name: "DiloPlataforma"),
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
    // Reuniones, lo puro: el modelo de datos, el guion, los relojes, quién
    // habló, el eco, la búsqueda, el disco y la retención. Sin FluidAudio, para
    // que el MCP y el CLI lo lean y `swift test` lo pruebe en segundos.
    .target(name: "DiloReuniones"),
    // Quién habló, con FluidAudio: Nemotron 3, Sortformer, LS-EEND, VBx y los
    // embeddings de voz detrás de un contrato propio. Viaja en el producto
    // `DiloEngines` por la misma razón que `DiloModes` viaja en `DiloText`.
    .target(
      name: "DiloHablantes",
      dependencies: ["DiloReuniones", .product(name: "FluidAudio", package: "FluidAudio")]
    ),
    // El banco de la Fase 0: mide los diarizadores sobre reuniones de verdad.
    // Taller, como `dilo-metrics`: la app no lo enlaza.
    .executableTarget(
      name: "dilo-banco-reuniones",
      dependencies: ["DiloReuniones", "DiloHablantes", "DiloEngines"]
    ),
    .target(name: "DiloMetrics"),
    .executableTarget(name: "dilo-metrics", dependencies: ["DiloMetrics"]),
    .executableTarget(
      name: "dilo-comparar-motores",
      dependencies: [
        "DiloEngines",
        "DiloMetrics",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ]
    ),
    .testTarget(name: "DiloTextTests", dependencies: ["DiloText"]),
    .testTarget(name: "DiloModesTests", dependencies: ["DiloModes"]),
    .testTarget(name: "DiloConsumoTests", dependencies: ["DiloConsumo"]),
    .testTarget(name: "DiloAgentesTests", dependencies: ["DiloAgentes", "DiloReuniones", "DiloModes"]),
    .testTarget(name: "DiloPlataformaTests", dependencies: ["DiloPlataforma"]),
    .testTarget(name: "DiloCapabilitiesTests", dependencies: ["DiloCapabilities"]),
    .testTarget(name: "DiloEnginesTests", dependencies: ["DiloEngines", "DiloText"]),
    .testTarget(name: "DiloMetricsTests", dependencies: ["DiloMetrics"]),
    .testTarget(name: "DiloReunionesTests", dependencies: ["DiloReuniones"]),
  ]
)

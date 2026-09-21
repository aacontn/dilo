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
    .library(name: "DiloMetrics", targets: ["DiloMetrics"]),
    // La herramienta que mide los números del spec §3 contra un `.app` ya
    // compilado. Es de taller, no de producto: `scripts/metrics.sh` la
    // construye y la corre, y la app no la enlaza.
    .executable(name: "dilo-metrics", targets: ["dilo-metrics"]),
  ],
  targets: [
    .target(name: "DiloText"),
    .target(name: "DiloMetrics"),
    .executableTarget(name: "dilo-metrics", dependencies: ["DiloMetrics"]),
    .testTarget(name: "DiloTextTests", dependencies: ["DiloText"]),
    .testTarget(name: "DiloMetricsTests", dependencies: ["DiloMetrics"]),
  ]
)

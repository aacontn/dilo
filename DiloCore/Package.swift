// swift-tools-version: 6.2
import PackageDescription

// Todo lo que es de Dilo vive acá, fuera del árbol que viene de Talkify, para
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
let package = Package(
  name: "DiloCore",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DiloText", targets: ["DiloText", "DiloModes"]),
    .library(name: "DiloCapabilities", targets: ["DiloCapabilities"]),
  ],
  targets: [
    .target(name: "DiloText"),
    .target(name: "DiloModes"),
    .target(name: "DiloCapabilities"),
    .testTarget(name: "DiloTextTests", dependencies: ["DiloText"]),
    .testTarget(name: "DiloModesTests", dependencies: ["DiloModes"]),
    .testTarget(name: "DiloCapabilitiesTests", dependencies: ["DiloCapabilities"]),
  ]
)

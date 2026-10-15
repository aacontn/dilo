import AppKit
import SwiftUI

/// Dibuja el panel de la barra en PNG, sin abrir una ventana.
///
/// Usa el modelo y la vista de verdad (`PanelDeLaBarra`,
/// `VistaDelPanelDeLaBarra`); lo de mentira es lo de alrededor —la barra de
/// menús, la página, el escritorio— y la sombra, que en la app pone la
/// ventana. Se corre con `scripts/render-panel-de-la-barra.sh`.
@main
enum RenderDelPanelDeLaBarra {
  static let ancho: CGFloat = 560
  static let altoDeLaBarra: CGFloat = 24

  @MainActor
  static func main() throws {
    // Sin ícono en el Dock, sin ventanas y sin activarse: AppKit sólo entra
    // para que SwiftUI tenga tipografías y apariencia con qué rasterizar.
    NSApplication.shared.setActivationPolicy(.prohibited)

    let argumentos = CommandLine.arguments.dropFirst()
    let destino = URL(filePath: argumentos.first ?? "/Volumes/SSD2/scratch/dilo-mac/barra")
    let raiz = URL(filePath: argumentos.dropFirst().first ?? FileManager.default.currentDirectoryPath)
    try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

    let marca = NSImage(contentsOf: raiz.appending(path: "Dilo/Assets.xcassets/MenuBarIcon.imageset/menubar-32.png"))
    marca?.size = CGSize(width: 16, height: 16)
    marca?.isTemplate = true

    let ahora = Date()
    let escenas: [(String, PanelDeLaBarra.Entrada, PanelDeLaBarra.Accion.Copia?)] = [
      ("completo", completo(ahora), nil),
      ("dictando", dictando(ahora), nil),
      ("copiado", sencillo(ahora), .entregado),
      ("recien-instalado", recienInstalado(ahora), nil),
    ]
    for (nombre, entrada, copiado) in escenas {
      for claro in [true, false] {
        try escribir(
          lamina(entrada: entrada, copiado: copiado, marca: marca, claro: claro),
          en: destino.appending(path: "\(nombre)-\(claro ? "claro" : "oscuro").png")
        )
      }
    }
    // Grafito: blanco y gris, color sólo para lo que salió bien o mal.
    PaletaActiva.compartida.elegir(.grafito)
    try escribir(
      lamina(entrada: completo(ahora), copiado: nil, marca: marca, claro: false),
      en: destino.appending(path: "completo-grafito-oscuro.png")
    )
    PaletaActiva.compartida.elegir(.glaciar)
    print("Listo: \(destino.path)")
  }

  /// Todo lo que el panel puede llegar a decir a la vez.
  static func completo(_ ahora: Date) -> PanelDeLaBarra.Entrada {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.atajoDeDictar = "fn"
    entrada.atajoDeLeer = "⌥ ⎋"
    entrada.ultimo = PanelDeLaBarra.Ultimo(
      entregado: "Hola Marta, confirmo la reunión del martes a las 10 en la oficina.",
      original: "eh hola marta confirmo la reunión del martes a las diez en la oficina",
      propuesta: "Estimada Marta: le confirmo nuestra reunión del martes.",
      modo: "Correo",
      cuando: ahora.addingTimeInterval(-130)
    )
    entrada.tomaGuardada = "0:12"
    entrada.modos = [
      .init(id: "correo", nombre: "Correo"),
      .init(id: "resumen", nombre: "Resumen"),
      .init(id: "slack", nombre: "Slack"),
    ]
    entrada.modoElegido = "correo"
    entrada.ahora = ahora
    return entrada
  }

  static func dictando(_ ahora: Date) -> PanelDeLaBarra.Entrada {
    var entrada = sencillo(ahora)
    entrada.dictando = true
    return entrada
  }

  /// Lo de todos los días: un dictado sin modo y nada más.
  static func sencillo(_ ahora: Date) -> PanelDeLaBarra.Entrada {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.atajoDeDictar = "fn"
    entrada.atajoDeLeer = "⌥ ⎋"
    entrada.ultimo = PanelDeLaBarra.Ultimo(
      entregado: "Revisar el deploy de la landing antes del viernes.",
      original: "Revisar el deploy de la landing antes del viernes.",
      cuando: ahora.addingTimeInterval(-40)
    )
    entrada.modos = [.init(id: "correo", nombre: "Correo"), .init(id: "resumen", nombre: "Resumen")]
    entrada.ahora = ahora
    return entrada
  }

  /// Recién instalado: nada dictado, sin modos, transcribiendo un archivo.
  static func recienInstalado(_ ahora: Date) -> PanelDeLaBarra.Entrada {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.atajoDeDictar = "fn"
    entrada.atajoDeLeer = "⌥ ⎋"
    entrada.progresoDeArchivo = 0.4
    entrada.ahora = ahora
    return entrada
  }

  /// El panel colgando de una barra de menús simulada, sobre una página
  /// clara o un escritorio oscuro.
  @MainActor
  static func lamina(
    entrada: PanelDeLaBarra.Entrada,
    copiado: PanelDeLaBarra.Accion.Copia?,
    marca: NSImage?,
    claro: Bool
  ) -> some View {
    let tinta: Color = claro ? .black : .white
    let icono = CGRect(x: ancho - 120, y: 0, width: 24, height: altoDeLaBarra)
    return VStack(alignment: .leading, spacing: 0) {
      // La barra: un par de menús a la izquierda y el ícono resaltado.
      HStack(spacing: 18) {
        Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
        Text(verbatim: "Safari").font(.system(size: 13, weight: .bold))
        Text(verbatim: "Archivo").font(.system(size: 13))
        Text(verbatim: "Edición").font(.system(size: 13))
        Spacer()
      }
      .foregroundStyle(tinta.opacity(0.85))
      .padding(.horizontal, 14)
      .frame(height: altoDeLaBarra)
      .frame(maxWidth: .infinity)
      .background(claro ? Color.white.opacity(0.7) : Color.black.opacity(0.35))
      .overlay(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(tinta.opacity(0.14))
          .frame(width: 30, height: 20)
          .overlay {
            if let marca {
              Image(nsImage: marca).renderingMode(.template).foregroundStyle(tinta.opacity(0.85))
            }
          }
          .offset(x: icono.midX - 15, y: 2)
      }
      // El panel, con el borde derecho a `aireDelIcono` del centro del ícono
      // y `separacion` bajo la barra: lo que calcula `PanelDeLaBarra.marco`.
      VistaDelPanelDeLaBarra(
        contenido: PanelDeLaBarra.contenido(entrada),
        copiado: copiado,
        marca: marca,
        material: .imitacion
      )
      .fixedSize(horizontal: false, vertical: true)
      .shadow(color: .black.opacity(claro ? 0.22 : 0.5), radius: 18, y: 8)
      .padding(.top, PanelDeLaBarra.separacion)
      .padding(.leading, icono.midX + PanelDeLaBarra.aireDelIcono - VistaDelPanelDeLaBarra.ancho)
      .padding(.bottom, 40)
    }
    .frame(width: ancho, alignment: .topLeading)
    .background(fondo(claro: claro))
  }

  /// Una página con renglones grises, o un escritorio oscuro con un poco de
  /// color, para ver el vidrio imitado contra los dos.
  @MainActor
  static func fondo(claro: Bool) -> some View {
    ZStack(alignment: .topLeading) {
      if claro {
        Color.white
        VStack(alignment: .leading, spacing: 12) {
          ForEach(0..<18, id: \.self) { i in
            RoundedRectangle(cornerRadius: 3)
              .fill(Color.black.opacity(i % 5 == 0 ? 0.55 : 0.12))
              .frame(width: CGFloat([420, 380, 460, 300, 410][i % 5]), height: i % 5 == 0 ? 12 : 8)
          }
        }
        .padding(.top, 48)
        .padding(.leading, 28)
      } else {
        LinearGradient(
          colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.16, green: 0.08, blue: 0.2)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        Circle()
          .fill(Color(red: 0.2, green: 0.35, blue: 0.7).opacity(0.5))
          .frame(width: 320)
          .blur(radius: 60)
          .offset(x: 260, y: 160)
      }
    }
  }

  @MainActor
  static func escribir(_ vista: some View, en url: URL) throws {
    let renderer = ImageRenderer(content: vista)
    renderer.scale = 2
    guard let imagen = renderer.nsImage,
      let tiff = imagen.tiffRepresentation,
      let mapa = NSBitmapImageRep(data: tiff),
      let png = mapa.representation(using: .png, properties: [:])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
    print(url.lastPathComponent)
  }
}

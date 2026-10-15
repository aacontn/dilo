import AppKit
import SwiftUI

/// Las láminas del makeover: cada paleta de `PaletaDeDilo` en una columna,
/// estado por estado, y el ícono de la barra de menús con cada una.
///
/// Mismo principio que el resto de `render-muesca.swift`: la geometría y la
/// paleta son las de la app, compiladas junto con este archivo; el contenido
/// es de mentira con las medidas de las vistas de verdad. El vidrio no sale
/// en PNG —`ImageRenderer` no dibuja `glassEffect`—, así que la fila del
/// panel con vidrio usa `FondoDeLaMuesca` con `material: .imitacion` y lo
/// dice en su rótulo; el de verdad se mira con `scripts/muesca.sh mostrar
/// hover-vidrio`.
extension RenderDeLaMuesca {
  static let paletasDeLaLamina: [PaletaDeDilo] = PaletaDeDilo.Nombre.allCases.map(\.paleta)
  static let anchoDeCelda: CGFloat = 470
  static let anchoDelRotulo: CGFloat = 170
  static let seccionesDeLaLamina = SeccionesDelPanel(recientes: 2, modos: true)

  /// Una frase por paleta, la que va en la cabecera de su columna.
  static func frase(de paleta: PaletaDeDilo) -> String {
    switch paleta.nombre {
    case .glaciar: "De fábrica. Fría: azul de Apple a celeste. Acuse en menta pálida."
    case .grafito: "Elegible en Apariencia → Color. Blanco y grafito, como Droppy y el sistema."
    }
  }

  @MainActor
  static func escribirLasPaletas(en carpeta: URL) throws {
    let original = paleta
    defer { paleta = original }

    let reposo = HUDNotchGeometry.reposoSize(for: pantalla)
    let radio = HUDNotchGeometry.radioEnReposo(for: pantalla)
    let dos = Segmentos(izquierdo: .retenido, derecho: .toma, conPalabra: [.izquierda, .derecha])
    // El panel de la lámina —dos recientes y los modos— es más alto que la
    // ventana de fábrica: la celda lo aloja entero, con su sombra.
    let altoDelPanel = max(
      HUDNotchGeometry.windowSize(for: pantalla).height,
      HUDNotchGeometry.altoDelPanelDeHover(for: pantalla, secciones: seccionesDeLaLamina)
    ) + 28

    let filas: [(String, CGFloat, () -> AnyView)] = [
      ("Reposo", 44, {
        AnyView(enLaVentana(tamaño: reposo, radio: radio, encuadre: .reposo) { marcaDeReposo(alto: reposo.height) })
      }),
      ("Dictando", 50, { AnyView(dictando) }),
      ("Procesando", 50, { AnyView(lineaDeEstado("Procesando…", color: .white.opacity(0.9))) }),
      ("Acuse", 50, { AnyView(acuse) }),
      ("Error", 50, {
        AnyView(lineaDeEstado("No pude pegarlo: quedó en el portapapeles", color: paleta.error.color))
      }),
      ("Micrófono muerto", 50, { AnyView(dictandoSinMicrofono) }),
      ("Segmentos · reposo", 44, {
        AnyView(enLaVentana(tamaño: reposo, radio: radio, encuadre: .reposo, segmentos: dos) {
          marcaDeReposo(alto: reposo.height)
        })
      }),
      ("Segmentos · dictando", 50, { AnyView(dictandoConSegmentos(Segmentos(izquierdo: .retenido, derecho: .toma))) }),
      ("Panel del hover · negro", altoDelPanel, { AnyView(panelDelHover(vidrio: false)) }),
      ("Panel del hover · vidrio (imitación: el real se ve con el arnés)", altoDelPanel, {
        AnyView(panelDelHover(vidrio: true))
      }),
    ]

    // Una vista por paleta y fila, rasterizadas cada una con su paleta
    // puesta: la lámina se arma con imágenes, no con vistas, porque la
    // paleta es un estático y SwiftUI dibujaría todo con la última.
    var celdas: [[(claro: NSImage, oscuro: NSImage)]] = []
    var muestrarios: [NSImage] = []
    for p in paletasDeLaLamina {
      paleta = p
      muestrarios.append(try imagen(muestrario(de: p).frame(width: anchoDeCelda * 2, height: 92, alignment: .topLeading)))
      celdas.append(try filas.map { fila in
        (
          claro: try imagen(celda(claro: true, alto: fila.1) { fila.2() }),
          oscuro: try imagen(celda(claro: false, alto: fila.1) { fila.2() })
        )
      })
    }

    let lamina = VStack(alignment: .leading, spacing: 0) {
      Text("Dilo · Glaciar de fábrica y Grafito (2026-10-14) — en cada columna, barra clara | barra oscura")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.bottom, 10)
      HStack(alignment: .top, spacing: 0) {
        Color.clear.frame(width: anchoDelRotulo, height: 1)
        ForEach(Array(paletasDeLaLamina.enumerated()), id: \.offset) { i, p in
          VStack(alignment: .leading, spacing: 4) {
            Text(p.nombre.titulo)
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(.white)
            Text(frase(de: p))
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.7))
            Image(nsImage: muestrarios[i])
          }
          .frame(width: anchoDeCelda * 2, alignment: .leading)
          .padding(.trailing, 14)
        }
      }
      ForEach(Array(filas.enumerated()), id: \.offset) { f, fila in
        HStack(alignment: .top, spacing: 0) {
          Text(fila.0)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: anchoDelRotulo - 10, alignment: .leading)
            .padding(.leading, 0)
            .padding(.top, 6)
            .frame(width: anchoDelRotulo, alignment: .leading)
          ForEach(Array(paletasDeLaLamina.enumerated()), id: \.offset) { i, _ in
            HStack(spacing: 0) {
              Image(nsImage: celdas[i][f].claro)
              Image(nsImage: celdas[i][f].oscuro)
            }
            .overlay(Rectangle().stroke(Color(white: 0.28), lineWidth: 1))
            .padding(.trailing, 14)
          }
        }
        .padding(.top, 6)
      }
    }
    .padding(16)
    .background(Color(white: 0.07))
    try escribir(lamina, en: carpeta, como: "paletas", escala: 2)
    try escribirLaBarraDeMenus(en: carpeta)
    print("Láminas en \(carpeta.path())")
  }

  /// Rasteriza a 2× y devuelve la imagen con su tamaño en puntos.
  @MainActor
  static func imagen(_ vista: some View) throws -> NSImage {
    let renderer = ImageRenderer(content: vista)
    renderer.scale = 2
    guard let cg = renderer.cgImage else { throw NoSePudoRasterizar(nombre: "celda") }
    return NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
  }

  /// La barra de menús y el escritorio, del ancho de una celda, con la
  /// ventana anfitriona colgando arriba al centro y recortada a la celda.
  static func celda(claro: Bool, alto: CGFloat, @ViewBuilder forma: () -> some View) -> some View {
    ZStack(alignment: .top) {
      VStack(spacing: 0) {
        (claro ? Color(white: 0.93) : Color(white: 0.12))
          .frame(height: HUDNotchGeometry.altoDeLaBarra(for: pantalla))
        LinearGradient(
          colors: claro
            ? [Color(red: 0.62, green: 0.72, blue: 0.86), Color(red: 0.42, green: 0.52, blue: 0.68)]
            : [Color(red: 0.16, green: 0.20, blue: 0.32), Color(red: 0.07, green: 0.09, blue: 0.16)],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      forma()
    }
    .frame(width: anchoDeCelda, height: alto, alignment: .top)
    .clipped()
  }

  /// Los tokens de la paleta en círculos con su nombre.
  static func muestrario(de p: PaletaDeDilo) -> some View {
    let tokens: [(String, Tono)] = [
      ("acento", p.acento), ("onda", p.ondaBase), ("punta", p.ondaPunta), ("punto", p.puntoDeReposo),
      ("cursor", p.cursor), ("acuse", p.acuse), ("error", p.error), ("segmento", p.segmento),
      ("mic. muerto", p.microfonoMuerto), ("Ajustes", p.acentoDeAjustes), ("barra", p.acentoDeLaBarra),
    ]
    return HStack(alignment: .top, spacing: 10) {
      ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
        VStack(spacing: 3) {
          Circle()
            .fill(token.1.color)
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            .frame(width: 22, height: 22)
          Text(token.0)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
          Text(hex(token.1))
            .font(.system(size: 8, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 66)
      }
    }
    .padding(.vertical, 6)
  }

  static func hex(_ t: Tono) -> String {
    let n = { (v: Double) in Int((v * 255).rounded()) }
    let base = String(format: "#%02X%02X%02X", n(t.rojo), n(t.verde), n(t.azul))
    return t.alfa < 1 ? "\(base) \(Int((t.alfa * 100).rounded()))%" : base
  }

  /// Una línea recta de la muesca dictando-tamaño: lo que dice un estado que
  /// no es dictar (`HUDLineaSobria.texto`, rama recta).
  static func lineaDeEstado(_ texto: String, color: Color) -> some View {
    enLaVentana(tamaño: tamañoAbierto, radio: radioDictando) {
      lineaSobria {
        Text(texto)
          .font(.system(size: 11, weight: .regular))
          .foregroundStyle(color)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// Dictando con el micrófono muerto: la onda quieta en el color de
  /// `microfonoMuerto`, sin halo y sin cursor (`HUDOndaDeBrasas.relleno`).
  static var dictandoSinMicrofono: some View {
    enLaVentana(tamaño: tamañoAbierto, radio: radioDictando) {
      lineaSobria {
        HStack(alignment: .center, spacing: 2) {
          ForEach(0..<5, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .fill(paleta.microfonoMuerto.color.opacity(0.55))
              .frame(width: 3, height: 4)
          }
        }
        .frame(width: 23, height: 13)
        Text("…el martes a las diez")
          .font(.system(size: 11, weight: .regular).italic())
          .foregroundStyle(.white.opacity(0.9))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// El panel del hover con dos recientes y la fila de modos, negro entero
  /// o con la franja de vidrio en imitación. Mide lo que mide en la app
  /// (`HUDNotchGeometry.altoDelPanelDeHover`) y dibuja las piezas de verdad
  /// (`PiezasDelPanel.swift`, `contenidoDelPanel`).
  static func panelDelHover(vidrio: Bool) -> some View {
    let secciones = seccionesDeLaLamina
    let tamaño = CGSize(
      width: metricas.contentWidth,
      height: HUDNotchGeometry.altoDelPanelDeHover(for: pantalla, secciones: secciones)
    )
    let cabecera = HUDNotchGeometry.alturaDeCabecera(for: pantalla)
    // Con vidrio o en negro, la forma abierta de Droppy (`FormaAbierta`).
    let radio = PanelDeVidrio.radio(para: tamaño, cabecera: cabecera)
    let silueta = SiluetaDeLaMuesca(
      estilo: .muesca,
      radioDeHombro: FormaAbierta.hombro(para: tamaño, en: pantalla, radioInferior: radio),
      radioInferior: radio
    )
    let ventana = CGSize(
      width: HUDNotchGeometry.windowSize(for: pantalla).width,
      height: max(HUDNotchGeometry.windowSize(for: pantalla).height, tamaño.height + 20)
    )
    return ZStack(alignment: .top) {
      marcoDeLaVentana
      contenidoDelPanel(recientes: secciones.recientes)
        .frame(width: tamaño.width, height: tamaño.height, alignment: .top)
        .background {
          FondoDeLaMuesca(silueta: silueta, alturaDeCabecera: cabecera, abierto: vidrio, material: .imitacion())
            .shadow(
              color: .black.opacity(0.25),
              radius: HUDMetrics.standard.shadowRadius,
              y: HUDMetrics.standard.shadowOffsetY
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(width: ventana.width, height: ventana.height)
  }

  /// El ícono de la barra con cada paleta. En reposo es plantilla —lo
  /// pinta el sistema, igual con todas— y sólo lleva color mientras
  /// transcribe un archivo: el dibujo de `StatusItemController.progressIcon`,
  /// repetido acá porque esa clase arrastra la app entera.
  @MainActor
  static func escribirLaBarraDeMenus(en carpeta: URL) throws {
    let raiz = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let ruta = raiz.appending(path: "Dilo/Assets.xcassets/MenuBarIcon.imageset/menubar-32.png")
    guard let png = NSImage(contentsOf: ruta) else { throw NoSePudoRasterizar(nombre: "MenuBarIcon") }
    png.size = CGSize(width: 16, height: 16)

    func iconos(claro: Bool, acento: NSColor) -> some View {
      let reposo = NSImage(size: png.size, flipped: false) { rect in
        png.draw(in: rect)
        (claro ? NSColor.black : NSColor.white).withAlphaComponent(0.85).set()
        rect.fill(using: .sourceAtop)
        return true
      }
      return HStack(spacing: 18) {
        Image(nsImage: reposo)
        Image(nsImage: progreso(png, 0.4, acento))
        Image(nsImage: progreso(png, 1, acento))
      }
      .frame(width: 150, height: 24)
      .background(claro ? Color(white: 0.93) : Color(white: 0.12))
    }

    var filas: [(String, NSImage)] = []
    for p in paletasDeLaLamina {
      paleta = p
      let vista = HStack(spacing: 12) {
        iconos(claro: true, acento: p.acentoDeLaBarra.nsColor)
        iconos(claro: false, acento: p.acentoDeLaBarra.nsColor)
      }
      filas.append((p.nombre.titulo, try imagen(vista)))
    }
    let lamina = VStack(alignment: .leading, spacing: 8) {
      Text("Barra de menús · reposo (plantilla), transcribiendo al 40 % y al 100 %")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
      ForEach(Array(filas.enumerated()), id: \.offset) { _, fila in
        HStack(spacing: 12) {
          Text(fila.0)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 70, alignment: .leading)
          Image(nsImage: fila.1)
        }
      }
    }
    .padding(14)
    .background(Color(white: 0.07))
    try escribir(lamina, en: carpeta, como: "barra-de-menus", escala: 4)
  }

  static func progreso(_ plantilla: NSImage, _ fraccion: Double, _ acento: NSColor) -> NSImage {
    NSImage(size: plantilla.size, flipped: false) { rect in
      plantilla.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.32)
      acento.set()
      rect.fill(using: .sourceAtop)
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * fraccion)).setClip()
      plantilla.draw(in: rect)
      acento.set()
      rect.fill(using: .sourceAtop)
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
  }
}

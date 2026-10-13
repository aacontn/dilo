import AppKit
import SwiftUI

/// Tres maneras de dibujar una píldora de los asientos, para decidir mirando:
///
/// - **A, la de hoy**: píldora negra separada (`HUDPildora`, la vista real).
/// - **B, vidrio**: la misma píldora separada, de vidrio. **Es una
///   aproximación**: ni `ImageRenderer` ni `NSHostingView.cacheDisplay` dibujan
///   el Liquid Glass de macOS 26 (`glassEffect`, `NSGlassEffectView`) fuera de
///   pantalla —el vidrio necesita el compositor del sistema y sale vacío—, así
///   que se imita con un tinte, un borde de luz y una sombra. El de verdad se
///   ve en la app con la escena `pildora-vidrio` del arnés.
/// - **C, notch alargado**: el contenido de la píldora pasa a ser parte de la
///   misma silueta negra (`SiluetaDeLaMuesca`), que se estira hacia ese lado
///   con las alas en los extremos nuevos. C2 es lo mismo con sólo el ícono.
///
/// Compila con la geometría y las vistas de verdad, como `render-muesca.sh`.
/// No abre ventanas ni toca el escritorio. Se corre con
/// `scripts/render-variantes-pildora.sh`.
@main
enum VariantesDeLaPildora {
  static let mango = Color(red: 1.0, green: 0.62, blue: 0.106)
  static let rojo = Color(red: 1.0, green: 0.361, blue: 0.361)

  static let pantalla = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    estiloSinNotch: .notchSimulado
  )

  enum Variante: String, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
    case c2 = "C2"

    var titulo: String {
      switch self {
      case .a: "A · píldora negra separada (la de hoy)"
      case .b: "B · píldora de vidrio separada (aproximación)"
      case .c: "C · notch alargado, ícono y palabra"
      case .c2: "C2 · notch alargado, sólo el ícono"
      }
    }
  }

  enum Caso: String, CaseIterable {
    case una = "reposo-reintentar"
    case dos = "reposo-dos"
    case dictando = "dictando-dos"

    var titulo: String {
      switch self {
      case .una: "Reposo · «Reintentar» a la derecha"
      case .dos: "Reposo · «No se pegó» y «Reintentar»"
      case .dictando: "Dictando · con las dos"
      }
    }

    var izquierda: ContenidoDePildora? { self == .una ? nil : .retenido }
    var derecha: ContenidoDePildora? { .toma }
  }

  static let ancho: CGFloat = 720
  static let alto: CGFloat = 64

  @MainActor
  static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let destino = URL(filePath: CommandLine.arguments.dropFirst().first
      ?? "/Volumes/SSD2/scratch/ingenieria-inversa/notch-png/variantes")
    try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

    for variante in Variante.allCases {
      for caso in Caso.allCases {
        for claro in [true, false] {
          try escribir(
            lienzo(claro: claro) { forma(variante, caso, claro: claro) },
            en: destino,
            como: "\(variante.rawValue)-\(caso.rawValue)-\(claro ? "claro" : "oscuro")"
          )
        }
      }
      print("\(variante.rawValue): \(medidas(variante))")
    }
    try escribir(lamina, en: destino, como: "variantes-comparadas", escala: 2)
    print("PNG en \(destino.path())")
  }

  // La forma de cada variante

  static var reposo: CGSize { HUDNotchGeometry.reposoSize(for: pantalla) }
  static var dictando: CGSize { HUDNotchGeometry.tamañoDictando(for: pantalla) }
  static var radio: CGFloat { HUDNotchGeometry.radioEnReposo(for: pantalla) }
  static var hombro: CGFloat { HUDNotchGeometry.filletSize(for: pantalla) }

  @ViewBuilder
  static func forma(_ variante: Variante, _ caso: Caso, claro: Bool) -> some View {
    let cuerpo = caso == .dictando ? dictando : reposo
    switch variante {
    case .a, .b:
      silueta(ancho: cuerpo.width, alto: cuerpo.height) { centro(caso) }
        .overlay {
          if variante == .a {
            HUDPildorasAlCostado(
              izquierda: caso.izquierda, derecha: caso.derecha,
              screen: pantalla, acento: mango, alTocar: { _ in }
            )
          } else {
            pildorasDeVidrio(caso, claro: claro)
          }
        }
    case .c, .c2:
      alargada(caso, conTexto: variante == .c)
    }
  }

  /// La silueta de la app, en una pieza, con su contenido adentro.
  static func silueta(ancho: CGFloat, alto: CGFloat, @ViewBuilder contenido: () -> some View) -> some View {
    contenido()
      .frame(width: ancho, height: alto)
      .background {
        SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: hombro, radioInferior: radio).fill(Color.black)
      }
  }

  @ViewBuilder
  static func centro(_ caso: Caso) -> some View {
    if caso == .dictando {
      HStack(spacing: 6) {
        ondaCompacta
        Text("…el martes a las diez")
          .font(.system(size: 11, weight: .regular).italic())
          .foregroundStyle(.white.opacity(0.9))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        cursor
      }
      .padding(.horizontal, 10)
    } else {
      marcaDeReposo
    }
  }

  // B: vidrio aproximado

  static func pildorasDeVidrio(_ caso: Caso, claro: Bool) -> some View {
    let alcance = HUDNotchGeometry.alcanceDePildoras(for: pantalla)
    return Color.clear
      .overlay(alignment: .topLeading) {
        if let izquierda = caso.izquierda {
          vidrio(izquierda, claro: claro).offset(x: -alcance, y: HUDNotchGeometry.margenDePildora)
        }
      }
      .overlay(alignment: .topTrailing) {
        if let derecha = caso.derecha {
          vidrio(derecha, claro: claro).offset(x: alcance, y: HUDNotchGeometry.margenDePildora)
        }
      }
  }

  /// Lo que el vidrio regular hace sobre una barra lisa: casi el color de la
  /// barra, un borde de luz arriba, una sombra corta, y el texto con el
  /// contraste que da la vibración (oscuro sobre claro, claro sobre oscuro).
  static func vidrio(_ contenido: ContenidoDePildora, claro: Bool) -> some View {
    let forma = RoundedRectangle(cornerRadius: HUDNotchGeometry.altoDePildora(for: pantalla) / 2, style: .continuous)
    let tinta: Color = contenido.destacada ? mango : (claro ? .black.opacity(0.8) : .white.opacity(0.9))
    return HStack(spacing: 4) {
      Image(systemName: contenido.simbolo).font(.system(size: 9, weight: .semibold))
      Text(contenido.texto).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
    }
    .foregroundStyle(tinta)
    .frame(width: HUDNotchGeometry.anchoDePildora, height: HUDNotchGeometry.altoDePildora(for: pantalla))
    .background {
      forma
        .fill(claro ? Color.white.opacity(0.55) : Color.white.opacity(0.10))
        .overlay {
          forma.strokeBorder(
            LinearGradient(
              colors: [.white.opacity(claro ? 0.95 : 0.45), .white.opacity(claro ? 0.25 : 0.06)],
              startPoint: .top, endPoint: .bottom
            ),
            lineWidth: 0.8
          )
        }
        .shadow(color: .black.opacity(claro ? 0.18 : 0.5), radius: 2.5, y: 1)
    }
  }

  // C: la misma silueta, estirada

  /// Cuánto se estira la silueta hacia un lado para llevar esta píldora:
  /// aire, el ícono y, con texto, la palabra medida en su letra.
  static func estiramiento(_ contenido: ContenidoDePildora?, conTexto: Bool) -> CGFloat {
    guard let contenido else { return 0 }
    let icono: CGFloat = 12
    guard conTexto else { return 8 + icono + 6 }
    let texto = (contenido.texto as NSString).size(
      withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
    ).width.rounded(.up)
    return 8 + icono + 4 + texto + 10
  }

  static func alargada(_ caso: Caso, conTexto: Bool) -> some View {
    let cuerpo = caso == .dictando ? dictando : reposo
    let izq = estiramiento(caso.izquierda, conTexto: conTexto)
    let der = estiramiento(caso.derecha, conTexto: conTexto)
    return HStack(spacing: 0) {
      lado(caso.izquierda, ancho: izq, conTexto: conTexto, haciaAfuera: .leading)
      centro(caso).frame(width: cuerpo.width)
      lado(caso.derecha, ancho: der, conTexto: conTexto, haciaAfuera: .trailing)
    }
    .frame(width: cuerpo.width + izq + der, height: cuerpo.height)
    .background {
      SiluetaDeLaMuesca(estilo: .muesca, radioDeHombro: hombro, radioInferior: radio).fill(Color.black)
    }
    // El centro de la muesca no se mueve: lo que crece, crece hacia su lado.
    .offset(x: (der - izq) / 2)
  }

  @ViewBuilder
  static func lado(_ contenido: ContenidoDePildora?, ancho: CGFloat, conTexto: Bool, haciaAfuera: HorizontalEdge)
    -> some View
  {
    if let contenido {
      HStack(spacing: 4) {
        Image(systemName: contenido.simbolo).font(.system(size: 9, weight: .semibold))
        if conTexto {
          Text(contenido.texto).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
        }
      }
      .foregroundStyle(contenido.destacada ? mango : Color.white.opacity(0.85))
      .frame(width: ancho, alignment: haciaAfuera == .leading ? .trailing : .leading)
      .padding(haciaAfuera == .leading ? .trailing : .leading, 0)
    }
  }

  /// Los anchos que cada variante ocupa en la barra, para la lámina.
  static func medidas(_ variante: Variante) -> String {
    switch variante {
    case .a, .b:
      let alcance = HUDNotchGeometry.alcanceDePildoras(for: pantalla)
      return "silueta 160 + \(Int(alcance)) por lado con píldora → \(Int(160 + 2 * alcance)) pt de barra con dos"
    case .c, .c2:
      let conTexto = variante == .c
      let izq = estiramiento(.retenido, conTexto: conTexto)
      let der = estiramiento(.toma, conTexto: conTexto)
      return "silueta 160 → \(Int(160 + der)) con una, \(Int(160 + izq + der)) con dos (+\(Int(izq)) izq, +\(Int(der)) der), más 9 de cada ala"
    }
  }

  // El lienzo y la lámina

  static func lienzo(claro: Bool, @ViewBuilder forma: () -> some View) -> some View {
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
    .frame(width: ancho, height: alto, alignment: .top)
    .clipped()
  }

  static var lamina: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Color.clear.frame(width: 190, height: 30)
        ForEach(Variante.allCases, id: \.self) { variante in
          Text(variante.titulo)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: ancho * recorte, height: 30)
        }
      }
      ForEach(Caso.allCases, id: \.self) { caso in
        ForEach([true, false], id: \.self) { claro in
          HStack(spacing: 0) {
            Text("\(caso.titulo)\n\(claro ? "barra clara" : "barra oscura")")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.85))
              .frame(width: 190, alignment: .leading)
              .padding(.leading, 8)
            ForEach(Variante.allCases, id: \.self) { variante in
              lienzo(claro: claro) { forma(variante, caso, claro: claro) }
                .frame(width: ancho * recorte, height: alto)
                .clipped()
                .overlay(Rectangle().stroke(Color(white: 0.3), lineWidth: 1))
            }
          }
        }
      }
      HStack(spacing: 0) {
        Color.clear.frame(width: 190)
        ForEach(Variante.allCases, id: \.self) { variante in
          Text(medidas(variante))
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: ancho * recorte - 12, alignment: .leading)
            .padding(6)
        }
      }
    }
    .padding(10)
    .background(Color(white: 0.08))
  }

  /// De cada lienzo de 720 la lámina muestra el centro: es donde está todo.
  static let recorte: CGFloat = 0.62

  // Lo que no es la forma: copiado de `render-muesca.swift`, que tiene su
  // propio `@main` y no se puede compilar junto.

  static var marcaDeReposo: some View {
    Circle()
      .fill(mango.opacity(0.9))
      .frame(width: 3, height: 3)
      .padding(.bottom, 5)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
  }

  static let niveles: [Double] = [0.18, 0.46, 0.72, 0.95, 0.61]

  static var ondaCompacta: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(Array(niveles.enumerated()), id: \.offset) { _, v in
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(LinearGradient(colors: [mango, rojo], startPoint: .bottom, endPoint: .top))
          .frame(width: 3, height: min(max(4, (6 + pow(v, 0.7) * 11) * 11 / 16), 11))
          .shadow(color: rojo.opacity(0.5), radius: 3)
      }
    }
    .frame(width: 23, height: 13)
  }

  static var cursor: some View {
    RoundedRectangle(cornerRadius: 1, style: .continuous)
      .fill(mango)
      .frame(width: 2 * 11 / 15, height: 11)
  }

  @MainActor
  static func escribir(_ vista: some View, en carpeta: URL, como nombre: String, escala: CGFloat = 2) throws {
    let renderer = ImageRenderer(content: vista)
    renderer.scale = escala
    guard
      let imagen = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: imagen).representation(using: .png, properties: [:])
    else { throw NoSePudoRasterizar(nombre: nombre) }
    try png.write(to: carpeta.appending(path: "\(nombre).png"))
  }

  struct NoSePudoRasterizar: Error { let nombre: String }
}

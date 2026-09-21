import AppKit
import SwiftUI

/// Dibuja la muesca en PNG, sin abrir una ventana.
///
/// Existe porque la forma del notch se aprueba mirándola, y la única máquina
/// donde se puede mirar de verdad —el Mac mini de Alfonso, con dos 1080p sin
/// carcasa— es la misma donde un agente no puede tocar la GUI. `ImageRenderer`
/// rasteriza fuera de pantalla: no hay ventana, no hay foco robado, no hay
/// captura de pantalla.
///
/// Compila con la **geometría de verdad** (`HUDNotchGeometry`,
/// `NotchFilletShape`), no con una copia: si la silueta cambia en la app,
/// cambia acá. Lo que sí es de mentira es el contenido —la onda, el texto
/// parcial, el chip—, porque arrastrar la vista de dictado entera traería la
/// app completa y estos PNG son para aprobar la **forma**.
///
/// Se corre con `scripts/render-muesca.sh`.
@main
enum RenderDeLaMuesca {
  /// Mango, el acento de Dilo. Repetido acá a propósito: traer `DiloBrand`
  /// arrastraría el sistema de diseño de Ajustes y con él media app.
  static let mango = Color(red: 1.0, green: 0.62, blue: 0.106)

  /// Uno de los dos 1080p del Mac mini: sin carcasa, con el ajuste de fábrica.
  /// El alto de la barra es lo que reporta una pantalla así; la app lo mide
  /// con `frame.maxY - visibleFrame.maxY` y nunca lo supone.
  static let pantalla = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    estiloSinNotch: .notchSimulado
  )

  @MainActor
  static func main() throws {
    // Sin ícono en el Dock, sin ventanas y sin activarse: AppKit sólo entra
    // para que SwiftUI tenga tipografías y apariencia con qué rasterizar.
    NSApplication.shared.setActivationPolicy(.prohibited)

    let destino = URL(filePath: CommandLine.arguments.dropFirst().first
      ?? "/Volumes/SSD2/scratch/dilo-mac/muesca")
    try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

    let reposo = HUDNotchGeometry.reposoSize(for: pantalla)
    let fillet = HUDNotchGeometry.filletSize(for: pantalla)
    let radio = HUDNotchGeometry.radioEnReposo(for: pantalla)

    try escribir(lienzo(claro: true) { silueta(tamaño: reposo, radio: radio) { marcaDeReposo } },
                 en: destino, como: "reposo-claro")
    try escribir(lienzo(claro: false) { silueta(tamaño: reposo, radio: radio) { marcaDeReposo } },
                 en: destino, como: "reposo-oscuro")
    try escribir(lienzo(claro: true) { hoverExpandido }, en: destino, como: "hover-expandido")
    try escribir(lienzo(claro: false) { dictando }, en: destino, como: "dictando")
    try escribir(lienzo(claro: false) { resultado }, en: destino, como: "resultado")
    try escribir(comparacion, en: destino, como: "comparacion")
    // La curva cóncava se juzga de cerca: a tamaño real son nueve puntos.
    try escribir(
      ZStack(alignment: .top) {
        VStack(spacing: 0) {
          Color(white: 0.93).frame(height: HUDNotchGeometry.altoDeLaBarra(for: pantalla))
          Color(red: 0.62, green: 0.72, blue: 0.86)
        }
        silueta(tamaño: reposo, radio: radio) { marcaDeReposo }
      }
      .frame(width: 220, height: 60, alignment: .top),
      en: destino,
      como: "detalle",
      escala: 8
    )

    let abierta = tamañoAbierto
    print("""
      muesca en reposo: \(Int(reposo.width))×\(Int(reposo.height)) pt \
      (barra \(Int(HUDNotchGeometry.altoDeLaBarra(for: pantalla))) pt), \
      fillet \(Int(fillet)) pt, radio inferior \(Int(radio)) pt
      muesca abierta:   \(Int(abierta.width))×\(Int(abierta.height)) pt
      PNG en \(destino.path())
      """)
  }

  // MARK: La silueta

  /// La misma composición que `HUDSurface`: el cuerpo negro con las esquinas
  /// de arriba rectas —nace del borde— y las dos curvas cóncavas al costado.
  static func silueta(
    tamaño: CGSize,
    radio: CGFloat,
    @ViewBuilder contenido: () -> some View
  ) -> some View {
    let fillet = HUDNotchGeometry.filletSize(for: pantalla)
    return contenido()
      .frame(width: tamaño.width, height: tamaño.height, alignment: .top)
      .background {
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: radio,
          bottomTrailingRadius: radio,
          topTrailingRadius: 0,
          style: .continuous
        )
        .fill(Color.black)
        .shadow(color: .black.opacity(0.35), radius: 11, y: 4)
      }
      .overlay(alignment: .topLeading) { ala(.leading, fillet) }
      .overlay(alignment: .topTrailing) { ala(.trailing, fillet) }
  }

  @ViewBuilder
  static func ala(_ lado: HorizontalEdge, _ fillet: CGFloat) -> some View {
    if fillet > 0 {
      Color.black
        .frame(width: fillet, height: fillet)
        .clipShape(NotchFilletShape(side: lado))
        .offset(x: lado == .leading ? -fillet : fillet)
    }
  }

  /// El punto mango abajo al centro, lo único que la muesca dice en reposo.
  static var marcaDeReposo: some View {
    VStack {
      Spacer(minLength: 0)
      Circle().fill(mango.opacity(0.9)).frame(width: 3, height: 3)
    }
    .padding(.bottom, 5)
  }

  // MARK: Los estados abiertos

  static var metricas: HUDMetrics { .standard }

  static var tamañoAbierto: CGSize {
    HUDNotchGeometry.contentSize(
      for: pantalla,
      metrics: metricas,
      visualBandHeight: metricas.waveBandHeight,
      includesTextBand: true,
      shapingBandHeight: metricas.shapingBandHeight
    )
  }

  static var dictando: some View {
    silueta(tamaño: tamañoAbierto, radio: metricas.bottomCornerRadius) {
      VStack(spacing: 0) {
        // La cabecera **es** la silueta en reposo: la forma crece desde donde
        // descansaba.
        Color.clear.frame(height: HUDNotchGeometry.alturaDeCabecera(for: pantalla))
        onda.frame(height: metricas.waveBandHeight)
        Text("esto es lo que estás dictando")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.white)
          .frame(height: metricas.textBandHeight)
        Text("Correo")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(mango)
          .frame(height: metricas.shapingBandHeight)
      }
    }
  }

  /// Lo que el hover abre después del retardo: la misma muesca, un poco más
  /// grande, con lo último que se dictó. Crece hacia abajo desde la silueta,
  /// nunca hacia arriba.
  static var hoverExpandido: some View {
    let reposo = HUDNotchGeometry.reposoSize(for: pantalla)
    let contexto = "Listo · «quedamos el martes a las diez»"
    let tamaño = CGSize(width: 320, height: reposo.height + 22)
    return silueta(tamaño: tamaño, radio: HUDNotchGeometry.radioEnReposo(for: pantalla)) {
      VStack {
        Spacer(minLength: 0)
        Text(contexto)
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.78))
          .lineLimit(1)
          .padding(.horizontal, 12)
      }
      .padding(.bottom, 6)
    }
  }

  static var resultado: some View {
    let tamaño = HUDNotchGeometry.contentSize(
      for: pantalla,
      metrics: metricas,
      visualBandHeight: 0,
      includesTextBand: true,
      shapingBandHeight: 0
    )
    return silueta(tamaño: tamaño, radio: metricas.bottomCornerRadius) {
      VStack(spacing: 0) {
        Color.clear.frame(height: HUDNotchGeometry.alturaDeCabecera(for: pantalla))
        Text("Listo")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.white)
          .frame(height: metricas.textBandHeight)
      }
    }
  }

  /// Una onda de mentira: barras quietas con una envolvente de sílabas. Acá
  /// sólo tiene que ocupar su banda para que la silueta se vea completa.
  static var onda: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<48, id: \.self) { i in
        let t = Double(i) / 47
        let alto = 6 + 34 * abs(sin(t * 9)) * (0.35 + 0.65 * sin(t * .pi))
        Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: alto)
      }
    }
  }

  // MARK: El lienzo

  /// Dos franjas: la barra de menús, del alto que esta pantalla reporta, y el
  /// escritorio debajo. Es lo mínimo para juzgar si la muesca se funde con el
  /// borde o se apoya encima.
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
    .frame(width: 720, height: 240, alignment: .top)
  }

  /// El antes y el después, lado a lado sobre la misma barra: el rectángulo
  /// de 185×32 con esquinas de 8 y sin curvas, y la muesca de hoy.
  static var comparacion: some View {
    HStack(spacing: 0) {
      panelDeComparacion(titulo: "Antes · 185×32, sin curvas") {
        VStack {
          Spacer(minLength: 0)
          Capsule().fill(mango.opacity(0.85)).frame(width: 18, height: 3)
          Spacer(minLength: 0)
        }
        .frame(width: 185, height: 32)
        .background {
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 8,
            bottomTrailingRadius: 8,
            topTrailingRadius: 0,
            style: .continuous
          )
          .fill(Color.black)
        }
      }
      panelDeComparacion(titulo: "Después · muesca del alto de la barra") {
        silueta(
          tamaño: HUDNotchGeometry.reposoSize(for: pantalla),
          radio: HUDNotchGeometry.radioEnReposo(for: pantalla)
        ) { marcaDeReposo }
      }
    }
    .frame(width: 720, height: 200, alignment: .top)
  }

  static func panelDeComparacion(
    titulo: String,
    @ViewBuilder forma: () -> some View
  ) -> some View {
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        VStack(spacing: 0) {
          Color(white: 0.93).frame(height: HUDNotchGeometry.altoDeLaBarra(for: pantalla))
          LinearGradient(
            colors: [Color(red: 0.62, green: 0.72, blue: 0.86), Color(red: 0.42, green: 0.52, blue: 0.68)],
            startPoint: .top,
            endPoint: .bottom
          )
        }
        forma()
      }
      Text(titulo)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1))
    }
    .frame(width: 360, height: 200)
  }

  // MARK: Rasterizar

  @MainActor
  static func escribir(
    _ vista: some View,
    en carpeta: URL,
    como nombre: String,
    escala: CGFloat = 2
  ) throws {
    let renderer = ImageRenderer(content: vista)
    renderer.scale = escala
    guard
      let imagen = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: imagen).representation(using: .png, properties: [:])
    else {
      throw NoSePudoRasterizar(nombre: nombre)
    }
    try png.write(to: carpeta.appending(path: "\(nombre).png"))
  }

  struct NoSePudoRasterizar: Error { let nombre: String }
}

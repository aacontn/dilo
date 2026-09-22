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
/// **Cada estado se dibuja dentro de una ventana simulada del tamaño real**,
/// con la misma cadena de layout de `HUDSurface`, y el marco punteado del PNG
/// es esa ventana. Antes cada forma se rasterizaba suelta con su
/// `frame(width:height:)`: los PNG salían impecables mientras la app estiraba
/// la muesca al alto de la ventana anfitriona —160×24 se veía como 160×196 en
/// un 1080p externo— y el render dejaba de ser evidencia justo del error que
/// había que ver.
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

    let enReposo = enLaVentana(tamaño: reposo, radio: radio, encuadre: .reposo) {
      marcaDeReposo(alto: reposo.height)
    }
    try escribir(lienzo(claro: true) { enReposo }, en: destino, como: "reposo-claro")
    try escribir(lienzo(claro: false) { enReposo }, en: destino, como: "reposo-oscuro")
    try escribir(lienzo(claro: true) { hoverExpandido }, en: destino, como: "hover-expandido")
    try escribir(lienzo(claro: false) { dictando }, en: destino, como: "dictando")
    try escribir(lienzo(claro: false) { resultado }, en: destino, como: "resultado")
    try escribir(comparacion, en: destino, como: "comparacion")
    for (i, avance) in [0.0, 1.0 / 3, 2.0 / 3, 1.0].enumerated() {
      try escribir(
        lienzo(claro: false) { apertura(avance) },
        en: destino,
        como: "apertura-\(i + 1)"
      )
      print(
        "apertura-\(i + 1): \(Int((avance * 100).rounded())) % de la forma "
          + "a los \(Int((cuandoLlega(a: avance) * 460).rounded())) ms de 460"
      )
    }
    // La curva cóncava se juzga de cerca: a tamaño real son nueve puntos.
    try escribir(
      ZStack(alignment: .top) {
        VStack(spacing: 0) {
          Color(white: 0.93).frame(height: HUDNotchGeometry.altoDeLaBarra(for: pantalla))
          Color(red: 0.62, green: 0.72, blue: 0.86)
        }
        silueta(tamaño: reposo, radio: radio, sombra: false) {
          marcaDeReposo(alto: reposo.height)
        }
      }
      .frame(width: 220, height: 60, alignment: .top),
      en: destino,
      como: "detalle",
      escala: 8
    )

    let abierta = tamañoAbierto
    let ventana = HUDNotchGeometry.windowSize(for: pantalla)
    let ventanaEnReposo = HUDNotchGeometry.windowSize(for: pantalla, encuadre: .reposo)
    print("""
      muesca en reposo: \(Int(reposo.width))×\(Int(reposo.height)) pt \
      (barra \(Int(HUDNotchGeometry.altoDeLaBarra(for: pantalla))) pt), \
      fillet \(Int(fillet)) pt, radio inferior \(Int(radio)) pt
      muesca abierta:   \(Int(abierta.width))×\(Int(abierta.height)) pt
      ventana en reposo:\(Int(ventanaEnReposo.width))×\(Int(ventanaEnReposo.height)) pt
      ventana abierta:  \(Int(ventana.width))×\(Int(ventana.height)) pt
      """)

    // Lo que el PNG no dice solo: cuánto negro hay de verdad adentro de la
    // ventana, que es lo que `MuescaTests` afirma contra la vista real.
    medir("reposo", enReposo)
    medir("hover", hoverExpandido)
    medir("dictando", dictando)
    medir("resultado", resultado)
    print("PNG en \(destino.path())")
  }

  // MARK: La silueta

  /// La misma composición **y la misma cadena de layout** que `HUDSurface`:
  /// el ancho fijo, el `fixedSize` que impide que un hijo goloso se quede con
  /// el alto ofrecido, el alto como mínimo —la banda de texto puede crecer— y
  /// recién ahí el fondo negro. Copiar `frame(width:height:)` en su lugar es
  /// lo que hacía que estos PNG no pudieran fallar nunca.
  ///
  /// `sombra: false` es el reposo, y no es un gusto del render: la muesca
  /// quieta es hardware y el hardware no tiñe lo que tiene debajo
  /// (`HUDSurface.proyectaSombra`). Con la sombra puesta, estos PNG mostraban
  /// un halo bajo la barra de menús que la app también dibujaba, y dejaban de
  /// ser evidencia de nada.
  static func silueta(
    tamaño: CGSize,
    radio: CGFloat,
    sombra: Bool = true,
    @ViewBuilder contenido: () -> some View
  ) -> some View {
    let fillet = HUDNotchGeometry.filletSize(for: pantalla)
    return contenido()
      .frame(width: tamaño.width)
      .fixedSize(horizontal: false, vertical: true)
      .frame(minHeight: tamaño.height, alignment: .top)
      .background {
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: radio,
          bottomTrailingRadius: radio,
          topTrailingRadius: 0,
          style: .continuous
        )
        .fill(Color.black)
        .shadow(
          color: .black.opacity(sombra ? 0.35 : 0),
          radius: sombra ? HUDMetrics.standard.shadowRadius : 0,
          y: sombra ? HUDMetrics.standard.shadowOffsetY : 0
        )
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

  /// La ventana anfitriona: del tamaño real y anclando la forma arriba y al
  /// centro, igual que `HUDSurface`. El resto tiene que quedar transparente.
  static func enLaVentana(
    tamaño: CGSize,
    radio: CGFloat,
    encuadre: HUDNotchGeometry.EncuadreDeLaVentana = .abierta,
    @ViewBuilder contenido: () -> some View
  ) -> some View {
    // La ventana mide lo que mide el estado: en reposo **es** la muesca —sin
    // sombra que alojar, sólo lo que las alas cuelgan a los lados— y sólo
    // crece con la forma abierta. El marco punteado del PNG es lo que deja ver
    // de un vistazo que ya no hay 190 puntos de ventana transparente
    // comiéndose clics bajo la muesca.
    let ventana = HUDNotchGeometry.windowSize(for: pantalla, encuadre: encuadre)
    // El marco va **detrás**: es el contorno de la ventana, y una línea
    // punteada cruzando la silueta arruina justo lo que se viene a mirar.
    return ZStack(alignment: .top) {
      marcoDeLaVentana
      silueta(tamaño: tamaño, radio: radio, sombra: encuadre == .abierta, contenido: contenido)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(width: ventana.width, height: ventana.height)
  }

  /// El contorno de la ventana anfitriona, punteado y apenas visible. No es
  /// decoración: es lo que deja ver de un vistazo que la forma mide lo suyo y
  /// no lo que mide la ventana.
  static var marcoDeLaVentana: some View {
    Rectangle()
      .strokeBorder(
        Color.white.opacity(0.22),
        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
      )
  }

  /// El punto mango abajo al centro, lo único que la muesca dice en reposo.
  ///
  /// Con su alto exacto y el aire adentro, como `HUDMarcaDeReposo`: pedir
  /// `maxHeight: .infinity` acá es justo lo que estiraba la forma.
  static func marcaDeReposo(alto: CGFloat) -> some View {
    Circle()
      .fill(mango.opacity(0.9))
      .frame(width: 3, height: 3)
      .padding(.bottom, 5)
      .frame(maxWidth: .infinity, alignment: .bottom)
      .frame(height: alto, alignment: .bottom)
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
    enLaVentana(tamaño: tamañoAbierto, radio: metricas.bottomCornerRadius) {
      VStack(spacing: 0) {
        // La cabecera **es** la silueta en reposo: la forma crece desde donde
        // descansaba.
        Color.clear.frame(height: HUDNotchGeometry.alturaDeCabecera(for: pantalla))
        onda.frame(height: metricas.waveBandHeight)
        // Una línea que se recorta por la izquierda: lo último dicho es lo
        // que se está revisando. En la cursiva de quince puntos del overlay de
        // Tauri, con su cursor mango al final.
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text("…el martes a las diez en la oficina")
            .font(.system(size: 15, weight: .regular).italic())
            .foregroundStyle(.white.opacity(0.9))
          cursor.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        }
        .frame(height: metricas.textBandHeight)
        Text("Correo")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
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
    let tamaño = CGSize(
      width: metricas.contentWidth,
      height: min(
        reposo.height + HUDNotchGeometry.altoDelContextoEnReposo,
        HUDNotchGeometry.altoMaximoDelHover
      )
    )
    return enLaVentana(tamaño: tamaño, radio: HUDNotchGeometry.radioEnReposo(for: pantalla)) {
      Text(contexto)
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.78))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .frame(height: tamaño.height, alignment: .bottom)
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
    return enLaVentana(tamaño: tamaño, radio: metricas.bottomCornerRadius) {
      VStack(spacing: 0) {
        Color.clear.frame(height: HUDNotchGeometry.alturaDeCabecera(for: pantalla))
        HStack(spacing: 8) {
          Text("Listo")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
          Text("Copiar")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(mango)
        }
        .frame(height: metricas.textBandHeight)
      }
    }
  }

  /// Rojo `#FF5C5C`, la punta de la onda de brasas. Repetido como el mango y
  /// por lo mismo: traer `DiloBrand` arrastraría media app.
  static let rojo = Color(red: 1.0, green: 0.361, blue: 0.361)

  /// Nueve niveles congelados, con forma de sílaba. No hay micrófono acá.
  static let niveles: [Double] = [0.18, 0.46, 0.72, 0.95, 0.61, 0.33, 0.78, 0.52, 0.24]

  /// La onda de brasas de `HUDOndaDeBrasas`, con sus medidas y su degradado.
  ///
  /// Redibujada y no importada: la vista de verdad depende de
  /// `DictationHUDContent`, que arrastra el dictado entero. Lo que estos PNG
  /// aprueban es la **forma** —que las nueve barras quepan en su banda y que
  /// el color se lea sobre el negro—, y para eso las medidas tienen que ser
  /// las mismas: 5 de ancho, 4 de aire, 3 de radio, entre 7 y 16 de alto.
  static var onda: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(Array(niveles.enumerated()), id: \.offset) { _, v in
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(
            LinearGradient(colors: [mango, rojo], startPoint: .bottom, endPoint: .top)
          )
          .frame(width: 5, height: min(max(7, 6 + pow(v, 0.7) * 11), 16))
          .shadow(color: rojo.opacity(0.5), radius: 4)
      }
    }
    .frame(height: 20)
  }

  /// El cursor mango del final del parcial (`HUDCursorDeDictado`), encendido.
  static var cursor: some View {
    RoundedRectangle(cornerRadius: 1, style: .continuous)
      .fill(mango)
      .frame(width: 2, height: 15)
  }

  // MARK: La apertura

  /// Los cuatro fotogramas de la revelación: 0 %, 33 %, 66 % y 100 % de la
  /// **apertura**.
  ///
  /// Del avance y no del tiempo. La curva de Tauri está tan cargada al
  /// principio que a un tercio del tiempo la forma ya está casi abierta, y los
  /// cuatro cortes salían tres veces el mismo PNG. Repartidos por avance se ve
  /// la forma a media altura, que es lo que hay que juzgar; cuánto tarda en
  /// llegar a cada uno lo dice la corrida del script, en milisegundos.
  ///
  /// Existe porque la animación es lo único de la muesca que un PNG suelto no
  /// puede mostrar, y una sesión que no puede tocar la GUI no la va a ver
  /// correr. Cuatro cortes alcanzan para juzgar lo que importa: que crezca
  /// hacia abajo desde la silueta, que la cabecera no se mueva del borde y que
  /// lo de adentro entre después de que la forma tenga dónde ponerlo.
  ///
  /// La curva es la del estilo de fábrica —«Baja», que en el escenario
  /// permanente es la de Tauri—, evaluada con la misma función que la app
  /// compila (`HUDRevealStyle.progresoDeTauri`), no con una copia.
  static func apertura(_ p: Double) -> some View {
    let reposo = HUDNotchGeometry.reposoSize(for: pantalla)
    let abierta = tamañoAbierto
    let tamaño = CGSize(
      width: reposo.width + (abierta.width - reposo.width) * p,
      height: reposo.height + (abierta.height - reposo.height) * p
    )
    let radio = HUDNotchGeometry.radioEnReposo(for: pantalla)
      + (metricas.bottomCornerRadius - HUDNotchGeometry.radioEnReposo(for: pantalla)) * p
    return enLaVentana(tamaño: tamaño, radio: radio) {
      // El `scard-pop`: lo de adentro entra desde 0,92 y opacidad cero,
      // anclado arriba, como en la app (`DictationHUDShellView.popDelContenido`).
      VStack(spacing: 0) {
        Color.clear.frame(height: HUDNotchGeometry.alturaDeCabecera(for: pantalla))
        onda.frame(height: metricas.waveBandHeight)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text("…el martes a las diez")
            .font(.system(size: 15, weight: .regular).italic())
            .foregroundStyle(.white.opacity(0.9))
          cursor.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        }
        .frame(height: metricas.textBandHeight)
        Text("Correo")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(mango)
          .frame(height: metricas.shapingBandHeight)
      }
      .frame(height: tamaño.height, alignment: .top)
      .clipped()
      .scaleEffect(0.92 + 0.08 * p, anchor: .top)
      .opacity(p)
    }
  }

  /// En qué fracción del tiempo la curva de Tauri llega a este avance. Es su
  /// inversa, y se despeja igual que ella: por bisección.
  static func cuandoLlega(a avance: Double) -> Double {
    guard avance > 0 else { return 0 }
    guard avance < 1 else { return 1 }
    var bajo = 0.0
    var alto = 1.0
    for _ in 0..<40 {
      let medio = (bajo + alto) / 2
      if HUDRevealStyle.progresoDeTauri(medio) < avance { bajo = medio } else { alto = medio }
    }
    return (bajo + alto) / 2
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
    .frame(width: 720, height: max(240, HUDNotchGeometry.windowSize(for: pantalla).height),
           alignment: .top)
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
          radio: HUDNotchGeometry.radioEnReposo(for: pantalla),
          sombra: false
        ) { marcaDeReposo(alto: HUDNotchGeometry.reposoSize(for: pantalla).height) }
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

  /// El rectángulo de negro **opaco** que una vista deja, en puntos. La
  /// sombra es negro al 35 %, así que lo que las separa es la opacidad.
  ///
  /// Es la misma medición que hace `MuescaTests`: acá se imprime para que la
  /// corrida del script diga los números, y allá se afirma.
  @MainActor
  static func medir(_ nombre: String, _ vista: some View) {
    let renderer = ImageRenderer(content: vista)
    renderer.scale = 1
    guard let imagen = renderer.cgImage else {
      print("\(nombre): no rasterizó")
      return
    }
    let mapa = NSBitmapImageRep(cgImage: imagen)
    // Las alas cóncavas se afinan hacia afuera hasta desaparecer, así que sus
    // últimas columnas son antialias: el ancho del cuerpo se mide por debajo
    // de ellas, donde la forma tiene su ancho entero.
    let ala = Int(HUDNotchGeometry.filletSize(for: pantalla).rounded(.up))
    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    var cuerpoMinX = Int.max, cuerpoMaxX = Int.min
    for y in 0..<mapa.pixelsHigh {
      for x in 0..<mapa.pixelsWide {
        guard
          let color = mapa.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
          color.alphaComponent > 0.9,
          color.redComponent < 0.1, color.greenComponent < 0.1, color.blueComponent < 0.1
        else { continue }
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
        if y >= ala {
          cuerpoMinX = min(cuerpoMinX, x)
          cuerpoMaxX = max(cuerpoMaxX, x)
        }
      }
    }
    guard minX <= maxX, cuerpoMinX <= cuerpoMaxX else {
      print("\(nombre): sin negro")
      return
    }
    print(
      "\(nombre): cuerpo \(cuerpoMaxX - cuerpoMinX + 1)×\(maxY - minY + 1) pt, "
        + "con alas \(maxX - minX + 1) pt de ancho, arriba en y=\(minY)"
    )
  }

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

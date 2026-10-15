import AppKit
import SwiftUI

/// El panel del clic derecho en el ícono de la barra, dibujado.
///
/// **Es el panel de la muesca traído a la barra** (2026-10-15): el mismo
/// vidrio ahumado y oscuro (`PanelDeVidrio`), la misma jerarquía y densidad de
/// Droppy —lo principal en blanco y semibold, lo secundario en gris, letra de
/// 10,5 a 12,5— y las mismas piezas cuando sirven: lo último dictado es
/// `HUDUltimoDelPanel` y los modos son `HUDChipDelPanel`. De Switchboard trae
/// la forma de panel de barra: una tarjeta que flota bajo el ícono con un
/// encabezado que dice quién es y en qué está, filas que se iluminan al
/// pasar, y los vínculos al pie. Sin la punta de Switchboard: el vidrio de
/// la muesca no la lleva, y los paneles del sistema en macOS 26 tampoco.
///
/// Recibe el panel en palabras (`PanelDeLaBarra.Contenido`) y valores
/// sueltos, sin `AppSettings` ni el controlador, para que el render en PNG
/// (`scripts/render-panel-de-la-barra.sh`) dibuje esta misma vista y no una
/// copia.
struct VistaDelPanelDeLaBarra: View {
  static let ancho: CGFloat = 300
  static let radio: CGFloat = 20
  /// El aire alrededor del contenido.
  static let aire: CGFloat = 14

  /// Con qué se pinta el fondo.
  enum Material: Equatable, Sendable {
    /// Vidrio ahumado de verdad (`glassEffect`), con su velo negro.
    case vidrio
    /// El gris medido del vidrio, para el PNG: `ImageRenderer` no dibuja
    /// vidrio.
    case imitacion
    /// «Panel con vidrio» apagado en Apariencia: negro, como la muesca.
    case negro
  }

  let contenido: PanelDeLaBarra.Contenido
  /// Lo que se acaba de copiar: su fila dice ✓ en el color del acuse.
  var copiado: PanelDeLaBarra.Accion.Copia?
  /// El ícono de la barra, para el encabezado. Nil, la onda.
  var marca: NSImage?
  var material: Material = .vidrio
  var alElegir: (PanelDeLaBarra.Accion) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      encabezado
        .padding(.bottom, 12)
      if let toma = contenido.toma {
        tarjetaDeLaToma(toma)
          .padding(.bottom, 10)
      }
      if let ultimo = contenido.ultimo {
        bloqueDelUltimo(ultimo)
          .padding(.bottom, 6)
      }
      VStack(spacing: 0) {
        ForEach(contenido.acciones) { fila in
          filaDeAccion(fila)
        }
      }
      if !contenido.modos.isEmpty {
        filaDeModos
          .padding(.top, 4)
      }
      separador
        .padding(.vertical, 8)
      pie
    }
    .padding(Self.aire)
    .frame(width: Self.ancho, alignment: .topLeading)
    .background(FondoDelPanelDeLaBarra(material: material))
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Dilo, panel de la barra"))
  }

  private var separador: some View {
    Rectangle()
      .fill(Color.white.opacity(0.08))
      .frame(height: 1)
      .accessibilityHidden(true)
  }

  /// La marca, «Dilo», en qué está con su punto de color y el gatillo como
  /// una tecla, y «Abrir» a la derecha —lo mismo que el clic izquierdo—.
  private var encabezado: some View {
    let encabezado = contenido.encabezado
    let paleta = PaletaDeDilo.actual
    return HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white.opacity(0.08))
        .frame(width: 30, height: 30)
        .overlay { marcaDeDilo(paleta) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: "Dilo")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
        HStack(spacing: 5) {
          Circle()
            .fill(color(de: encabezado.tono, paleta: paleta))
            .frame(width: 6, height: 6)
          Text(verbatim: encabezado.estado)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
          if let atajo = encabezado.atajo {
            TeclaDelPanel(texto: atajo)
          }
        }
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Button { alElegir(.abrirDilo) } label: {
        Text("Abrir")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .frame(height: 24)
      }
      .buttonStyle(EstiloDePildora())
      .accessibilityLabel(Text("Abrir Dilo"))
      .help("Abre la ventana de Dilo (también con un clic izquierdo en el ícono)")
    }
  }

  @ViewBuilder
  private func marcaDeDilo(_ paleta: PaletaDeDilo) -> some View {
    let degradado = LinearGradient(
      colors: [paleta.ondaBase.color, paleta.ondaPunta.color],
      startPoint: .bottomLeading,
      endPoint: .topTrailing
    )
    if let marca {
      Image(nsImage: marca)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 17, height: 17)
        .foregroundStyle(degradado)
    } else {
      Image(systemName: "waveform")
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(degradado)
    }
  }

  /// El punto del encabezado: menta cuando está listo —lo que salió bien en
  /// toda la app—, el acento haciendo algo, ámbar si hay una toma esperando.
  private func color(de tono: PanelDeLaBarra.Contenido.Tono, paleta: PaletaDeDilo) -> Color {
    switch tono {
    case .reposo: paleta.acuse.color
    case .activo: paleta.acento.color
    case .aviso: paleta.aviso.color
    }
  }

  /// Una toma que quedó en RAM: lo único del panel que pide algo, así que va
  /// arriba y en ámbar. Reintentar en una píldora y botarla con una ✕. Sin
  /// ícono a la izquierda: el ámbar ya lo dice, y con él la frase no cabía.
  private func tarjetaDeLaToma(_ toma: PanelDeLaBarra.Contenido.Toma) -> some View {
    let aviso = PaletaDeDilo.actual.aviso.color
    return HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Un dictado no salió")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Text("Quedó grabado · \(toma.reloj)")
          .font(.system(size: 10.5))
          .foregroundStyle(.white.opacity(0.5))
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 6)
      Button { alElegir(.reintentarToma) } label: {
        Text("Reintentar")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.black)
          .padding(.horizontal, 10)
          .frame(height: 22)
          .background(Capsule(style: .continuous).fill(aviso))
          .contentShape(Capsule(style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Reintentar el dictado que no salió"))
      Button { alElegir(.descartarToma) } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.white.opacity(0.6))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(EstiloDePildora(forma: .circulo))
      .accessibilityLabel(Text("Descartar la grabación"))
      .help("Descartar la grabación")
    }
    .padding(.leading, 12)
    .padding(.trailing, 8)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(aviso.opacity(0.08))
        .strokeBorder(aviso.opacity(0.22), lineWidth: 1)
    )
  }

  /// Lo último dictado, como en el panel de la muesca: un clic lo copia.
  /// Debajo, en gris, lo dicho sin el modo y lo que el modo propuso, cuando
  /// son otra cosa.
  private func bloqueDelUltimo(_ ultimo: PanelDeLaBarra.Contenido.UltimoDictado) -> some View {
    VStack(spacing: 0) {
      Button { alElegir(.copiar(.entregado)) } label: {
        HUDUltimoDelPanel(
          titulo: ultimo.titulo,
          subtitulo: ultimo.detalle,
          copiado: copiado == .entregado
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(EstiloDeFila())
      .accessibilityLabel(Text("Copiar el último dictado: \(ultimo.titulo)"))
      .help("Copiar el último dictado")
      ForEach(ultimo.otras, id: \.copia) { otra in
        Button { alElegir(.copiar(otra.copia)) } label: {
          filaDeOtraVersion(otra)
        }
        .buttonStyle(EstiloDeFila())
        .accessibilityLabel(Text("Copiar \(otra.etiqueta): \(otra.vistazo)"))
      }
    }
    .padding(.horizontal, -8)
  }

  private func filaDeOtraVersion(_ otra: PanelDeLaBarra.Contenido.UltimoDictado.Otra) -> some View {
    let listo = copiado == otra.copia
    return HStack(spacing: 6) {
      Text(verbatim: otra.etiqueta)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.42))
        .lineLimit(1)
        .fixedSize()
      Text(verbatim: otra.vistazo)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.62))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      Image(systemName: listo ? "checkmark" : "doc.on.doc")
        .font(.system(size: 9.5, weight: listo ? .bold : .medium))
        .foregroundStyle(listo ? PaletaDeDilo.actual.acuse.color : .white.opacity(0.32))
        .frame(width: 22)
    }
    // La columna del título de lo último: el cuadro del ícono y su aire.
    .padding(.leading, HUDUltimoDelPanel.cuadro + 10)
    .padding(.horizontal, 8)
    .frame(height: 22)
    .contentShape(Rectangle())
  }

  /// Una acción: el ícono en la columna del cuadro de lo último, la frase
  /// y, si tiene, su tecla.
  private func filaDeAccion(_ fila: PanelDeLaBarra.Contenido.Fila) -> some View {
    Button { alElegir(fila.accion) } label: {
      HStack(spacing: 10) {
        Image(systemName: fila.icono)
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(.white.opacity(0.62))
          .frame(width: HUDUltimoDelPanel.cuadro)
        Text(verbatim: fila.titulo)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
        Spacer(minLength: 8)
        if let atajo = fila.atajo {
          TeclaDelPanel(texto: atajo)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .contentShape(Rectangle())
    }
    .buttonStyle(EstiloDeFila())
    .padding(.horizontal, -8)
    .accessibilityLabel(Text(verbatim: fila.accesibilidad))
  }

  /// El modo del atajo general, como en el panel de la muesca: todas las
  /// pestañas a la vista —aquí sobra ancho— y el elegido en su píldora.
  private var filaDeModos: some View {
    HStack(spacing: 10) {
      Image(systemName: "wand.and.stars")
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.62))
        .frame(width: HUDUltimoDelPanel.cuadro)
        .accessibilityHidden(true)
      // Se desplaza sólo si no caben: con tres o cuatro modos, la fila
      // entera y quieta (y así también sale en el PNG, que no dibuja un
      // `ScrollView`).
      ViewThatFits(in: .horizontal) {
        chipsDeModo
        ScrollView(.horizontal, showsIndicators: false) { chipsDeModo }
      }
      // La letra del primer chip en la columna de las frases de arriba; su
      // píldora sobresale a la izquierda, como el resaltado de una fila.
      .padding(.leading, -8)
      Spacer(minLength: 0)
    }
    .frame(height: 28)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Modo del atajo"))
  }

  private var chipsDeModo: some View {
    HStack(spacing: 2) {
      ForEach(contenido.modos, id: \.id) { chip in
        Button { alElegir(.elegirModo(chip.id)) } label: {
          HUDChipDelPanel(nombre: chip.nombre, elegido: chip.elegido)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Modo \(chip.nombre)"))
        .accessibilityAddTraits(chip.elegido ? [.isSelected] : [])
      }
    }
  }

  /// Los vínculos y «Salir», en dos columnas: son lo que se busca de vez en
  /// cuando, no a cada rato.
  private var pie: some View {
    let celdas = contenido.vinculos + [contenido.salir]
    let filas = stride(from: 0, to: celdas.count, by: 2).map { Array(celdas[$0..<min($0 + 2, celdas.count)]) }
    return VStack(spacing: 0) {
      ForEach(filas, id: \.first?.accion) { par in
        HStack(spacing: 4) {
          ForEach(par) { celda in
            vinculo(celda)
          }
          if par.count == 1 { Color.clear.frame(maxWidth: .infinity) }
        }
      }
    }
    .padding(.horizontal, -8)
  }

  private func vinculo(_ fila: PanelDeLaBarra.Contenido.Fila) -> some View {
    Button { alElegir(fila.accion) } label: {
      HStack(spacing: 7) {
        Image(systemName: fila.icono)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(.white.opacity(0.42))
          .frame(width: 14)
        Text(verbatim: fila.titulo)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.68))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(EstiloDeFila())
    .accessibilityLabel(Text(verbatim: fila.accesibilidad))
    .help(fila.accesibilidad)
  }
}

/// Una tecla, como la dibuja un menú del sistema pero a la escala del panel:
/// el gatillo en el encabezado y el de leer al lado de su fila.
struct TeclaDelPanel: View {
  let texto: String

  var body: some View {
    Text(verbatim: texto)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.white.opacity(0.62))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 5)
      .frame(height: 16)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.white.opacity(0.07))
          .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
      )
      .accessibilityLabel(Text("Atajo \(texto)"))
  }
}

/// Una fila sin caja que se ilumina al pasar y un poco más al apretar.
/// Técnica observada en Switchboard (`BarRowButtonStyle`).
private struct EstiloDeFila: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Fila(configuration: configuration)
  }

  private struct Fila: View {
    let configuration: ButtonStyleConfiguration
    @State private var encima = false

    var body: some View {
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(configuration.isPressed ? 0.12 : encima ? 0.07 : 0))
        )
        .onHover { encima = $0 }
    }
  }
}

/// Un botón chico con fondo gris: «Abrir» y la ✕ de la toma.
private struct EstiloDePildora: ButtonStyle {
  enum Forma { case capsula, circulo }
  var forma = Forma.capsula

  func makeBody(configuration: Configuration) -> some View {
    Pildora(configuration: configuration, forma: forma)
  }

  private struct Pildora: View {
    let configuration: ButtonStyleConfiguration
    let forma: Forma
    @State private var encima = false

    var body: some View {
      let opacidad = configuration.isPressed ? 0.22 : encima ? 0.17 : 0.11
      configuration.label
        .background {
          switch forma {
          case .capsula: Capsule(style: .continuous).fill(Color.white.opacity(opacidad))
          case .circulo: Circle().fill(Color.white.opacity(opacidad))
          }
        }
        .contentShape(Capsule(style: .continuous))
        .onHover { encima = $0 }
    }
  }
}

/// El fondo: el vidrio ahumado del panel de la muesca, la misma receta
/// (`PanelDeVidrio.tinte` y `negroEncima`), en una tarjeta de radio 20 con un
/// filo blanco tenue que se apaga hacia abajo —la luz de arriba, como el
/// canto de la barra de Switchboard—.
///
/// «Reducir transparencia» le gana al vidrio y lo deja negro, igual que en
/// la muesca.
struct FondoDelPanelDeLaBarra: View {
  @Environment(\.accessibilityReduceTransparency) private var reducirTransparencia

  let material: VistaDelPanelDeLaBarra.Material

  var body: some View {
    let forma = RoundedRectangle(cornerRadius: VistaDelPanelDeLaBarra.radio, style: .continuous)
    ZStack {
      switch reducirTransparencia ? .negro : material {
      case .vidrio:
        Color.clear
          .glassEffect(.regular.tint(.black.opacity(PanelDeVidrio.tinte)), in: forma)
        forma.fill(Color.black.opacity(PanelDeVidrio.negroEncima))
      case .imitacion:
        forma.fill(Color(white: PanelDeVidrio.grisDeLaLamina))
      case .negro:
        forma.fill(Color.black)
      }
      forma.strokeBorder(
        LinearGradient(
          colors: [.white.opacity(0.2), .white.opacity(0.07), .white.opacity(0.05)],
          startPoint: .top,
          endPoint: .bottom
        ),
        lineWidth: 1
      )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

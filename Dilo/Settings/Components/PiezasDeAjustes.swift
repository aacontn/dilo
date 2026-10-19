import SwiftUI

/// El ícono de una sección: el símbolo en el color de su familia, sobre una
/// baldosa del mismo color apenas encendida. Como los de Ajustes del Sistema
/// pero en el idioma de la muesca: el color en el detalle, no en un bloque
/// lleno (2026-10-19).
struct IconoDeSeccion: View {
  let seccion: SettingsSection
  var tamano: CGFloat = 22
  /// Elegida, la baldosa se llena: es lo que dice dónde estás sin leer.
  var llena = false

  var body: some View {
    let color = seccion.colorDelIcono.color
    Image(systemName: seccion.icon)
      .font(.system(size: tamano * 0.5, weight: .semibold))
      .foregroundStyle(llena ? Color.black.opacity(0.78) : color)
      .frame(width: tamano, height: tamano)
      .background {
        RoundedRectangle(cornerRadius: tamano * 0.28, style: .continuous)
          .fill(llena ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.16)))
      }
      .overlay {
        RoundedRectangle(cornerRadius: tamano * 0.28, style: .continuous)
          .strokeBorder(color.opacity(llena ? 0 : 0.22), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }
}

extension EnvironmentValues {
  /// La fila que la búsqueda acaba de traer a la vista: se ilumina un
  /// momento para que el ojo la encuentre.
  @Entry var ajusteResaltado: AjusteID?
  /// Con qué se pinta el fondo de la ventana. Los renders piden la imitación:
  /// el vidrio de verdad no sale en un PNG.
  @Entry var materialDeAjustes: MaterialDeAjustes = .vidrio
}

/// El fondo de Ajustes y de los Primeros pasos.
enum MaterialDeAjustes: Equatable, Sendable {
  /// Vidrio ahumado: la receta del panel de la muesca (`PanelDeVidrio`).
  case vidrio
  /// El gris que el vidrio deja en la pantalla, para los PNG.
  case imitacion
  /// Sin vidrio: «Reducir transparencia», o lo que pida quien dibuja.
  case solido
}

/// Marca una fila como destino de la búsqueda: le da su id para el
/// `ScrollViewReader` y la ilumina cuando la búsqueda la trae.
struct AnclaDeAjuste: ViewModifier {
  let ajuste: AjusteID?

  @Environment(\.ajusteResaltado) private var resaltado
  @Environment(\.accessibilityReduceMotion) private var reducirMovimiento

  private var encendida: Bool {
    guard let ajuste, let resaltado else { return false }
    return resaltado.ancla == ajuste
  }

  func body(content: Content) -> some View {
    if let ajuste {
      iluminable(content.id(ajuste))
    } else {
      content
    }
  }

  private func iluminable(_ content: some View) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(SettingsTheme.accent.opacity(encendida ? 0.12 : 0))
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(SettingsTheme.accent.opacity(encendida ? 0.7 : 0), lineWidth: 1)
          }
          .padding(.horizontal, -8)
          .allowsHitTesting(false)
      }
      .animation(reducirMovimiento ? nil : .easeOut(duration: 0.3), value: encendida)
  }
}

extension View {
  func anclaDeAjuste(_ ajuste: AjusteID?) -> some View {
    modifier(AnclaDeAjuste(ajuste: ajuste))
  }
}

/// Un rótulo dentro de una sección, para lo que antes vivía escondido en un
/// desplegable («Idiomas y traducción», «Sonidos», «Leer en voz alta»):
/// ahora se ve, y la búsqueda lo encuentra.
struct SubtituloDeSeccion: View {
  let titulo: LocalizedStringKey
  var detalle: LocalizedStringKey?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(titulo)
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
      if let detalle {
        Text(detalle)
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
    .padding(.top, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Una lista de palabras como fichas con su ✕, que se acomodan en
/// renglones. Tus palabras y las muletillas eran una fila por palabra, cada
/// una con su botón «Quitar»: con veinte palabras, una pila de filas iguales
/// que empujaba todo lo demás fuera de la pantalla (2026-10-19).
struct FichasQuitables: View {
  let valores: [String]
  /// Las que llevan la marca de aprendidas de una corrección.
  var marcadas: Set<String> = []
  let quitar: (String) -> Void

  var body: some View {
    RenglonesDeFichas(espacio: 6) {
      ForEach(valores, id: \.self) { valor in
        HStack(spacing: 5) {
          if marcadas.contains(valor) {
            Image(systemName: "sparkle")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(SettingsTheme.accent)
              .help("Aprendida de una corrección tuya")
          }
          Text(verbatim: valor)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
          Button {
            quitar(valor)
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.white.opacity(0.5))
              .frame(width: 14, height: 14)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Quitar")
          .accessibilityLabel(Text("Quitar \(valor)"))
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10)
  }
}

/// Acomoda a sus hijos de izquierda a derecha y salta de renglón cuando no
/// caben.
struct RenglonesDeFichas: Layout {
  var espacio: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let ancho = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var alto: CGFloat = 0
    var maximo: CGFloat = 0
    for vista in subviews {
      let medida = vista.sizeThatFits(.unspecified)
      if x > 0, x + medida.width > ancho {
        y += alto + espacio
        x = 0
        alto = 0
      }
      x += medida.width + espacio
      alto = max(alto, medida.height)
      maximo = max(maximo, x - espacio)
    }
    return CGSize(width: proposal.width ?? maximo, height: y + alto)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var alto: CGFloat = 0
    for vista in subviews {
      let medida = vista.sizeThatFits(.unspecified)
      if x > bounds.minX, x + medida.width > bounds.maxX {
        y += alto + espacio
        x = bounds.minX
        alto = 0
      }
      vista.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(medida))
      x += medida.width + espacio
      alto = max(alto, medida.height)
    }
  }
}

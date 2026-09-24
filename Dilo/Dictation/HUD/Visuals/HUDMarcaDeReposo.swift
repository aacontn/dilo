import DiloConsumo
import SwiftUI

/// Lo que se ve cuando nadie está dictando: la presencia discreta y
/// permanente del contrato del notch.
///
/// **No anima.** Ni `TimelineView`, ni shader, ni un pulso que respire: el
/// reposo tiene que costar lo que cuesta una ventana quieta (spec §3, ~0 % de
/// CPU). Un punto que late es lo primero que se nota y lo último que se deja
/// de pagar.
///
/// Con carcasa real no dibuja nada: ahí el notch ya está y la marca caería
/// detrás de la cámara. En una pantalla sin carcasa la marca es lo único que
/// distingue la silueta de una franja negra cualquiera.
struct HUDMarcaDeReposo: View {
  /// False contra hardware real, donde el recorte físico es la presencia.
  let dibujaMarca: Bool
  /// El nombre del modo activo, o nil —que es lo de fábrica—. El único dato
  /// que la muesca dice sin que nadie se acerque, y sólo si se pidió
  /// (`AppSettings.hudModoEnReposo`).
  var modo: String?
  var scale: CGFloat = 1
  /// El alto exacto de la silueta que esta marca llena: el de la muesca en
  /// reposo, o el del panel que abre el hover.
  ///
  /// Llega de afuera y no se deduce acá porque quien lo sabe es la forma
  /// (`HUDNotchGeometry.reposoSize`), y un segundo lugar que lo calcule es un
  /// lugar del que se va a desviar.
  let alto: CGFloat
  /// Los datos de cada costado (`DatosDeLaMuesca`), y cuánto mide cada
  /// costado. Con el panel del hover abierto no van a los costados: van
  /// debajo del contexto, con su detalle —cada ventana y cuándo se
  /// reinicia—, que en el costado no cabe.
  var izquierdo: LadoDeLaMuesca?
  var derecho: LadoDeLaMuesca?
  var anchoDeLado: CGFloat = 0

  var body: some View {
    HStack(spacing: 0) {
      if anchoDeLado > 0 {
        costado(izquierdo)
      }
      centro
      if anchoDeLado > 0 {
        costado(derecho)
      }
    }
    .frame(height: alto)
    .accessibilityElement()
    .accessibilityLabel(Text("Dilo"))
    .accessibilityValue(Text(paraVoiceOver))
  }

  private var paraVoiceOver: String {
    let base = modo ?? String(localized: "En reposo")
    let datos = ladosConDato.map { "\($0.etiqueta) \($0.valor)" }
    return ([base] + datos).joined(separator: ", ")
  }

  private var ladosConDato: [LadoDeLaMuesca] {
    anchoDeLado > 0 ? [izquierdo, derecho].compactMap { $0 } : []
  }

  /// Un dato a un costado: su ícono y el valor, con una barrita debajo que se
  /// llena con el nivel. Cifras de ancho fijo para que el número no baile
  /// cada vez que cambia, y el valor y la barrita se entibian cerca del
  /// límite: mango desde el 75 %, rojo desde el 90 %.
  ///
  /// El ícono y no el nombre (2026-09-24): «se ve más bonito si usamos íconos
  /// en general». El nombre sigue estando para VoiceOver.
  @ViewBuilder
  private func costado(_ lado: LadoDeLaMuesca?) -> some View {
    HStack(spacing: 4 * scale) {
      if let lado {
        IconoDelDato(dato: lado.dato, lado: 12 * scale)
          .foregroundStyle(.white.opacity(0.62))
        VStack(alignment: .leading, spacing: 2 * scale) {
          Text(lado.valor)
            .font(.system(size: 10.5 * scale, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Self.color(para: lado.nivel))
          if let nivel = lado.nivel {
            Self.barrita(nivel: nivel, ancho: 26 * scale, alto: 2 * scale)
          }
        }
      }
    }
    .lineLimit(1)
    .frame(width: anchoDeLado, height: alto)
  }

  /// Una barra finita que se llena con el nivel, del color del valor.
  static func barrita(nivel: Double, ancho: CGFloat, alto: CGFloat) -> some View {
    Capsule()
      .fill(.white.opacity(0.14))
      .frame(width: ancho, height: alto)
      .overlay(alignment: .leading) {
        Capsule()
          .fill(color(para: nivel))
          .frame(width: max(alto, ancho * min(1, max(0, nivel / 100))), height: alto)
      }
  }

  static func color(para nivel: Double?) -> Color {
    guard let nivel else { return .white.opacity(0.85) }
    if nivel >= 90 { return Color(red: 1, green: 0.38, blue: 0.32) }
    if nivel >= 75 { return DiloBrand.mango }
    return .white.opacity(0.85)
  }

  /// Lo de siempre: el modo, o el punto.
  private var centro: some View {
    VStack(spacing: 2 * scale) {
      // Uno solo: el modo si se pidió, y si no el punto. Dos datos a la vez
      // no caben en una silueta del alto de la barra, y apilarlos volvería a
      // hacer de la muesca una etiqueta. Lo que el hover revela ya no pasa
      // por acá: es el panel (`HUDPanelDelHover`).
      if let modo, !modo.isEmpty {
        Text(modo)
          .font(.system(size: 9 * scale, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.45))
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, 10 * scale)
      } else if dibujaMarca {
        punto
      }
    }
    .padding(.bottom, 5 * scale)
    .frame(maxWidth: .infinity, alignment: .bottom)
    // Un alto exacto, y **nunca** `maxHeight: .infinity`. Con infinito la
    // marca se quedaba con el alto entero de la ventana anfitriona —que está
    // dimensionada para el estado más alto— y el fondo negro de `HUDSurface`
    // se estiraba detrás de ella: en un 1080p externo la muesca de 160×24
    // salía como un bloque de 160×196 colgando de la barra, con el punto
    // mango abajo del todo. El aire de abajo va adentro del alto, no sumado
    // encima, o la silueta mide cinco puntos de más.
    .frame(height: alto, alignment: .bottom)
  }

  /// Un punto mango de tres puntos, abajo y al centro. Lo único que la muesca
  /// dice en reposo.
  ///
  /// Era una raya de 18×3 centrada en la silueta, y con la silueta del alto de
  /// la barra ocupaba media muesca: se leía como una etiqueta, no como una
  /// luz de encendido. Tampoco es un micrófono — un glifo de micrófono
  /// permanente dice «te estoy escuchando», que es exactamente lo que el
  /// reposo **no** hace.
  private var punto: some View {
    Circle()
      .fill(DiloBrand.mango.opacity(0.9))
      .frame(width: 3 * scale, height: 3 * scale)
  }
}

/// El detalle de los datos en el panel del hover: una columna por dato, con
/// su nombre y hasta dos filas —la ventana, cuánto va y en cuánto se
/// reinicia—.
///
/// **Letra fija, no escalada.** El panel del hover crece de alto una
/// cantidad fija para esto (`HUDNotchGeometry.altoDelDetalleDeDatos`): una
/// letra que creciera con el tamaño elegido en Ajustes se saldría por abajo.
/// Tampoco anima: el tiempo que falta se calcula al dibujar, y el panel se
/// vuelve a dibujar cada vez que un dato cambia.
struct HUDDetalleDeLosDatos: View {
  let lados: [LadoDeLaMuesca]
  var ahora = Date()

  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      ForEach(lados, id: \.etiqueta) { lado in
        columna(lado)
      }
    }
  }

  private func columna(_ lado: LadoDeLaMuesca) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        IconoDelDato(dato: lado.dato, lado: 9)
        Text(verbatim: lado.etiqueta.uppercased())
          .font(.system(size: 8, weight: .semibold, design: .rounded))
          .tracking(0.6)
      }
      .foregroundStyle(.white.opacity(0.42))
      if lado.detalle.isEmpty {
        Text("Todavía sin datos")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.45))
      }
      ForEach(Array(lado.detalle.enumerated()), id: \.offset) { _, fila in
        filaDelDetalle(fila)
      }
    }
    .lineLimit(1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func filaDelDetalle(_ fila: FilaDelDetalle) -> some View {
    HStack(spacing: 5) {
      Text(Self.nombre(fila.cual))
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
      Text(verbatim: fila.valor)
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(HUDMarcaDeReposo.color(para: fila.nivel))
      Spacer(minLength: 4)
      if let reinicio = fila.seReiniciaEn {
        HStack(spacing: 2) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 7, weight: .semibold))
          Text(verbatim: TextoDelDato.faltaPara(reinicio, desde: ahora))
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.45))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.seReinicia(en: TextoDelDato.faltaPara(reinicio, desde: ahora)))
      }
    }
  }

  /// El nombre de cada fila. Corto: al lado va la cifra y el reinicio.
  static func nombre(_ cual: FilaDelDetalle.Cual) -> String {
    switch cual {
    case .cincoHoras: String(localized: "5 h")
    case .semana: String(localized: "Semana")
    case .tokensDelBloque: String(localized: "Tokens, 5 h")
    case .planCincoHoras: String(localized: "Plan, 5 h")
    case .ahora: String(localized: "Ahora")
    case .baja: String(localized: "Baja")
    case .sube: String(localized: "Sube")
    case .libre: String(localized: "Libre")
    }
  }

  static func seReinicia(en falta: String) -> String {
    String(localized: "Se reinicia en \(falta)")
  }
}

#Preview("Reposo · notch simulado") {
  HUDShellPreviewHarness(screen: HUDPreviewScreen.externalNotchSimulado, enReposo: true)
}

#Preview("Reposo · con contexto") {
  HUDShellPreviewHarness(
    screen: HUDPreviewScreen.externalNotchSimulado,
    enReposo: true,
    contexto: "Correo"
  )
}

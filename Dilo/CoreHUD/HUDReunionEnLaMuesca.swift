import SwiftUI

/// Una reunión grabando, como la dibuja la muesca: cuándo empezó y cómo va
/// cada **Pista**. La arma `ControlDeReuniones` (por `ReunionEnLaMuesca.de`);
/// la forma sólo la dibuja.
///
/// Vive en `CoreHUD` y sin `DiloReuniones` para que `scripts/render-muesca.sh`
/// la compile con la geometría de verdad.
struct ReunionEnLaMuesca: Equatable, Sendable {
  /// La marca de una pista: la misma regla que `EstadoDeLaMarca`, en el
  /// vocabulario del dibujo.
  enum Marca: Equatable, Sendable {
    case apagada
    case encendida
    case ambar
    case sinAudio
  }

  var inicio: Date
  var titulo: String
  /// El micrófono: la pista `yo`.
  var microfono: Marca
  /// El parlante: la pista `ellos`, el audio del Mac.
  var parlante: Marca
}

/// La reunión con la forma (sin dictado): `● 12:04` y las dos marcas, en lo
/// que mide la muesca de dictar (spec, «Mientras graba»).
///
/// El tiempo llega ya escrito: quien lo refresca es `HUDReunionViva`, a 4 Hz
/// y sin shader, y el render de la muesca lo pasa fijo.
struct HUDReunionEnLaMuesca: View {
  let tiempo: String
  let microfono: ReunionEnLaMuesca.Marca
  let parlante: ReunionEnLaMuesca.Marca
  /// El alto exacto de la forma: la vista lo llena y no lo estira, como
  /// `HUDMarcaDeReposo`.
  let alto: CGFloat
  /// En la cabecera del panel del hover: todo junto y al centro, sin
  /// repartirse el ancho, para dejarles los costados a los datos.
  var compacta = false

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(PaletaDeDilo.actual.grabando.color)
        .frame(width: 6, height: 6)
      Text(verbatim: tiempo)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(1)
        .fixedSize()
      if compacta { Color.clear.frame(width: 4) } else { Spacer(minLength: 6) }
      HUDMarcaDePista(simbolo: "mic.fill", tachado: "mic.slash.fill", marca: microfono)
      HUDMarcaDePista(simbolo: "speaker.wave.2.fill", tachado: "speaker.slash.fill", marca: parlante)
    }
    .padding(.horizontal, compacta ? 0 : 12)
    .frame(height: alto)
    .fixedSize(horizontal: compacta, vertical: false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Reunión grabando"))
    .accessibilityValue(Text(verbatim: tiempo))
    .accessibilityHint(Text("Abre la ventana de la reunión"))
  }
}

/// Una marca: encendida en blanco cuando su pista tiene señal, apagada en
/// gris con silencio de verdad, y ámbar —el del micrófono muerto del
/// dictado— cuando la vigía ve ceros exactos. Sin audio va tachada.
struct HUDMarcaDePista: View {
  let simbolo: String
  let tachado: String
  let marca: ReunionEnLaMuesca.Marca

  var body: some View {
    Image(systemName: marca == .sinAudio ? tachado : simbolo)
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: 13)
      // Cambia a lo sumo cuatro veces por segundo: un corte corto, nunca
      // una animación que corra sola.
      .animation(.easeOut(duration: 0.12), value: marca)
  }

  private var color: Color {
    switch marca {
    case .encendida: .white.opacity(0.95)
    case .apagada: .white.opacity(0.3)
    case .ambar, .sinAudio: PaletaDeDilo.actual.microfonoMuerto.color
    }
  }
}

extension ContenidoDelSegmento {
  /// La reunión al costado mientras se dicta: el punto rojo y «Grabando».
  /// Nunca se esconde —abre el micrófono— y un clic abre su ventana.
  static func reunion(_ reunion: ReunionEnLaMuesca) -> ContenidoDelSegmento {
    ContenidoDelSegmento(
      id: "reunion",
      simbolo: "circle.fill",
      texto: String(localized: "Grabando"),
      destacada: false,
      accesibilidad: String(localized: "Reunión grabando: abre su ventana"),
      grabando: true
    )
  }
}

extension HUDNotchGeometry {
  /// Lo que mide la reunión con la forma: lo de dictar. Contra una carcasa
  /// real el centro es la cámara, así que se ensancha hacia los dos lados lo
  /// que mide un dato de los costados y el contenido va a las orejas.
  static func tamañoDeLaReunion(for screen: HUDScreenSnapshot) -> CGSize {
    let dictando = tamañoDictando(for: screen)
    guard hasMeasuredNotch(for: screen) else { return dictando }
    return CGSize(width: reposoSize(for: screen).width + anchoDeUnLado * 2, height: reposoSize(for: screen).height)
  }
}

extension ActividadDeLaMuesca {
  /// Una reunión grabando. Alta y abre el micrófono —y el audio del Mac—:
  /// **nunca se queda sin asiento** ni en pantalla completa. Sin dictado
  /// tiene la forma; dictando, la sesión exige el principal y la reunión
  /// baja a un costado, a la izquierda, porque la derecha es de la toma.
  static let reunion = ActividadDeLaMuesca(
    id: "reunion", prioridad: .alta, abreElMicrofono: true, ladoPreferido: .izquierda
  )
}

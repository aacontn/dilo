/// Un permiso de macOS que Dilo tiene que pedirle a la persona, con el porqué
/// en una frase.
///
/// El porqué vive acá y no en la vista por la misma razón que el de los
/// motores vive en `SpeechEngineKind`: es contenido del producto, no
/// decoración de una pantalla. El onboarding lo muestra, y mañana lo puede
/// mostrar también un aviso en Ajustes sin copiarlo.
public enum Permiso: String, CaseIterable, Sendable {
  /// Sin esto no hay nada que transcribir.
  case microfono
  /// Sólo lo pide el motor de Apple: es `SFSpeechRecognizer` quien lo exige.
  /// Parakeet transcribe con su propio modelo y no lo necesita.
  case reconocimientoDeVoz
  /// La compuerta del Cmd+V sintético: es lo que deja el texto donde estabas
  /// escribiendo.
  case accesibilidad
  /// El tap de teclado que oye el gatillo con otra app al frente.
  case monitoreoDeEntrada

  public var titulo: String {
    switch self {
    case .microfono: "Micrófono"
    case .reconocimientoDeVoz: "Reconocimiento de voz"
    case .accesibilidad: "Accesibilidad"
    case .monitoreoDeEntrada: "Monitoreo de entrada"
    }
  }

  /// Una frase, la que contesta "¿y para qué quiere eso?". Sin esto un
  /// permiso es una exigencia; con esto es un trato.
  public var porque: String {
    switch self {
    case .microfono:
      "Para escucharte mientras tienes la tecla apretada. Sólo ahí."
    case .reconocimientoDeVoz:
      "Para que el motor de Apple convierta tu voz en texto, acá mismo, sin subir nada."
    case .accesibilidad:
      "Para dejar el texto donde está tu cursor, en la app en la que estabas escribiendo."
    case .monitoreoDeEntrada:
      "Para oír tu tecla de dictado aunque estés en otra app."
    }
  }

  /// El panel exacto de Ajustes del Sistema. Abrir "Privacidad y seguridad" y
  /// decir "busca ahí abajo" es hacerle a la persona el trabajo a medias.
  public var panelDeAjustes: String {
    switch self {
    case .microfono:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case .reconocimientoDeVoz:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    case .accesibilidad:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case .monitoreoDeEntrada:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    }
  }

  /// Qué permisos se piden en esta copia, en este orden.
  ///
  /// La regla es la de siempre: **lo que este anfitrión no puede hacer no se
  /// pide**. Hoy los dos anfitriones pegan y oyen el gatillo, así que la lista
  /// sale igual en los dos; el día que el sandbox pierda una de las dos, el
  /// onboarding deja de pedir un permiso que no serviría de nada, sin que
  /// nadie tenga que acordarse de tocar esta pantalla.
  ///
  /// El reconocimiento de voz cuelga del motor elegido y no del anfitrión:
  /// pedirlo con Parakeet puesto sería pedir un permiso que ese motor no usa.
  public static func pasos(
    anfitrion: any HostCapabilities,
    motorEsApple: Bool
  ) -> [Permiso] {
    var pasos: [Permiso] = [.microfono]
    if motorEsApple { pasos.append(.reconocimientoDeVoz) }
    if anfitrion.admite(.pegadoDirecto) { pasos.append(.accesibilidad) }
    if anfitrion.admite(.atajoGlobal) { pasos.append(.monitoreoDeEntrada) }
    return pasos
  }
}

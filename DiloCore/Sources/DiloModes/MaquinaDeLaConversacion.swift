import Foundation

/// En qué está la **Conversación**: lo que dice la barra de llamada.
public enum EstadoDeLaConversacion: Equatable, Sendable {
  case colgada
  /// Tu turno: el micrófono va al motor de voz.
  case escuchando
  /// Lo dicho se está transcribiendo o Claude está pensando.
  case pensando
  /// Dilo está diciendo la respuesta.
  case hablando
}

/// Los turnos de la **Conversación**, en **half duplex**: o habla la persona
/// o habla Dilo, nunca los dos a la vez.
///
/// Mientras Dilo piensa o habla el micrófono no va al motor, para que no se
/// escuche a sí mismo por los parlantes. Apretar el gatillo lo interrumpe y
/// le da el turno a la persona. Es un reductor puro, como
/// `DictationSessionMachine`: recibe un evento, cambia el estado y devuelve
/// los efectos que el controlador ejecuta.
public struct MaquinaDeLaConversacion: Equatable, Sendable {
  public enum Evento: Equatable, Sendable {
    /// Empezar la llamada.
    case llamar
    /// Terminó tu turno: silencio, o soltaste el gatillo.
    case terminoTuTurno
    /// El motor devolvió lo que dijiste.
    case transcrito(vacio: Bool)
    /// La primera oración de la respuesta empezó a sonar.
    case empezoAHablar
    /// Dilo terminó de decir la respuesta (o el aviso de una falla).
    case terminoDeHablar
    /// Apretaste el gatillo mientras Dilo pensaba o hablaba.
    case interrumpir
    case silenciar(Bool)
    case colgar
    /// Un turno que no salió del micrófono: lo dicho después del nombre que
    /// despertó a Dilo, o un turno que entra de afuera con la llamada en
    /// curso. Colgada, la llamada empieza ya pensando; escuchando, el
    /// micrófono se cierra sin entregar; pensando o hablando, lo de antes se
    /// corta. En los tres casos se consulta.
    case turnoDeAfuera
  }

  public enum Efecto: Equatable, Sendable {
    case abrirMicrofono
    /// `entregar`: si lo dicho va a transcribirse o se descarta.
    case cerrarMicrofono(entregar: Bool)
    case consultar
    case cancelarConsulta
    case callarLaVoz
  }

  public private(set) var estado = EstadoDeLaConversacion.colgada
  public private(set) var silenciada = false

  public init() {}

  /// Si el micrófono está yendo al motor de voz. Es la regla del half
  /// duplex: sólo escuchando, y nunca silenciada.
  public var microfonoAbierto: Bool { estado == .escuchando && !silenciada }

  public mutating func recibir(_ evento: Evento) -> [Efecto] {
    switch (estado, evento) {
    case (.colgada, .llamar):
      estado = .escuchando
      silenciada = false
      return [.abrirMicrofono]
    case (.colgada, .turnoDeAfuera):
      estado = .pensando
      silenciada = false
      return [.consultar]
    case (.colgada, _):
      return []

    case (.escuchando, .turnoDeAfuera):
      let microfono = microfonoAbierto
      estado = .pensando
      return (microfono ? [.cerrarMicrofono(entregar: false)] : []) + [.consultar]
    case (.pensando, .turnoDeAfuera), (.hablando, .turnoDeAfuera):
      estado = .pensando
      return [.cancelarConsulta, .callarLaVoz, .consultar]

    case (_, .colgar):
      let estaba = estado
      let microfono = microfonoAbierto
      estado = .colgada
      silenciada = false
      var efectos: [Efecto] = []
      if microfono { efectos.append(.cerrarMicrofono(entregar: false)) }
      if estaba == .pensando || estaba == .hablando { efectos += [.cancelarConsulta, .callarLaVoz] }
      return efectos

    case let (_, .silenciar(silenciar)):
      guard silenciar != silenciada else { return [] }
      let estabaAbierto = microfonoAbierto
      silenciada = silenciar
      if estado == .escuchando {
        return silenciar ? (estabaAbierto ? [.cerrarMicrofono(entregar: false)] : []) : [.abrirMicrofono]
      }
      return []

    case (.escuchando, .terminoTuTurno):
      guard !silenciada else { return [] }
      estado = .pensando
      return [.cerrarMicrofono(entregar: true)]

    case let (.pensando, .transcrito(vacio)):
      // Nada que contestar: el turno vuelve a la persona.
      guard !vacio else {
        estado = .escuchando
        return silenciada ? [] : [.abrirMicrofono]
      }
      return [.consultar]

    case (.pensando, .empezoAHablar):
      estado = .hablando
      return []

    case (.pensando, .terminoDeHablar), (.hablando, .terminoDeHablar):
      estado = .escuchando
      return silenciada ? [] : [.abrirMicrofono]

    case (.pensando, .interrumpir), (.hablando, .interrumpir):
      estado = .escuchando
      return [.cancelarConsulta, .callarLaVoz] + (silenciada ? [] : [.abrirMicrofono])

    default:
      return []
    }
  }
}

/// Cuándo terminó el turno de la persona, por silencio.
///
/// El nivel llega del micrófono en la escala de la muesca (0 a 1 sobre 50
/// dB, `MicrophoneInput.publishLevel`). El turno termina cuando hubo voz y
/// después `silencioParaTerminar` sin ella. Los umbrales son de partida, sin
/// medir con Alfonso en una pieza de verdad: son constantes con nombre y se
/// calibran acá.
public struct FinDelTurno: Sendable {
  /// Sobre esto es voz: 0,3 en la escala de 50 dB son −35 dBFS, por encima de
  /// una pieza callada (−45 a −50) y por debajo de alguien que habla a medio
  /// metro (−25 a −15).
  public static let nivelDeVoz: Float = 0.30
  /// Cuánto silencio termina el turno. Es la mitad de lo que tarda Dilo en
  /// contestar, así que va lo más corto que no corte a la gente: bajó de
  /// 1.100 ms porque la conversación no se sentía como una. Si corta, se
  /// sube acá.
  public static let silencioParaTerminar: Duration = .milliseconds(700)
  /// Cuánto se espera si lo último que se oyó deja la frase abierta («…y
  /// pero»): ahí la pausa es de quien busca la palabra, no de quien terminó.
  public static let silencioConLaFraseAbierta: Duration = .milliseconds(1_400)
  /// Las palabras con que una frase no termina. El motor las escribe plegadas
  /// o no; se comparan plegadas.
  static let dejanLaFraseAbierta: Set<String> = [
    "y", "e", "o", "u", "ni", "pero", "que", "porque", "pues", "aunque", "si", "cuando", "como", "donde",
    "mientras", "entonces", "de", "del", "al", "a", "en", "con", "para", "por", "sin", "sobre", "el", "la",
    "los", "las", "un", "una", "unos", "unas", "mi", "tu", "su", "este", "esta", "eh", "em", "mm",
  ]
  /// Cuánta voz hace falta antes de que el silencio cuente: un golpe en la
  /// mesa no es un turno.
  public static let vozMinima: Duration = .milliseconds(250)
  /// Sin voz durante esto, la conversación cuelga sola: alguien se fue y el
  /// micrófono no tiene por qué quedarse abierto.
  public static let sinVozParaColgar: Duration = .seconds(90)
  /// Entre dos muestras más separadas que esto no se cuenta voz: un hueco
  /// del micrófono no es medio segundo hablando.
  static let huecoMaximo: Duration = .milliseconds(300)

  private let inicio: ContinuousClock.Instant
  private var ultimaMuestra: ContinuousClock.Instant?
  private var ultimaVoz: ContinuousClock.Instant?
  public private(set) var voz: Duration = .zero

  public init(inicio: ContinuousClock.Instant) {
    self.inicio = inicio
  }

  public var huboVoz: Bool { voz >= Self.vozMinima }

  public mutating func muestra(nivel: Float, en instante: ContinuousClock.Instant) {
    defer { ultimaMuestra = instante }
    guard nivel >= Self.nivelDeVoz else { return }
    if let ultimaMuestra, let ultimaVoz, ultimaVoz == ultimaMuestra {
      let paso = instante - ultimaMuestra
      if paso <= Self.huecoMaximo { voz += paso }
    }
    ultimaVoz = instante
  }

  /// Si lo oído hasta ahora termina en una palabra que deja la frase abierta.
  public static func dejaLaFraseAbierta(_ parcial: String) -> Bool {
    SenalesDelTurno.plegar(parcial).split(separator: " ").last
      .map { dejanLaFraseAbierta.contains(String($0)) } ?? false
  }

  /// Si el turno ya terminó por silencio.
  public func termino(en instante: ContinuousClock.Instant, fraseAbierta: Bool = false) -> Bool {
    guard huboVoz, let ultimaVoz else { return false }
    return instante - ultimaVoz >= (fraseAbierta ? Self.silencioConLaFraseAbierta : Self.silencioParaTerminar)
  }

  /// Cuánto lleva callada la persona.
  public func silencio(en instante: ContinuousClock.Instant) -> Duration {
    ultimaVoz.map { instante - $0 } ?? .zero
  }

  /// Si pasó tanto sin voz que la conversación tiene que colgar.
  public func nadieHabla(en instante: ContinuousClock.Instant) -> Bool {
    instante - (ultimaVoz ?? inicio) >= Self.sinVozParaColgar
  }
}

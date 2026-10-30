import Foundation

/// Qué tramo del micrófono transcribir, y cuándo, mientras la **escucha de
/// nombres** está prendida.
///
/// El **Motor de voz** no corre sobre todo lo que se oye: eso es lo que
/// costaría un núcleo entero. Un detector de voz liviano mira cada trozo y,
/// cuando empieza alguien a hablar, esto pide transcribir **sólo el
/// principio** —`ventanaDelNombre`—, que es donde tiene que estar el nombre.
/// Si no está, el resto de ese tramo se ignora sin transcribir nada. Si está,
/// espera a que la persona termine (`silencioTrasElNombre`, el mismo de
/// `FinDelTurno`) y pide el tramo entero, para que lo dicho tras el nombre sea
/// el primer turno.
///
/// Trabaja con índices de muestra absolutos a 16 kHz, los mismos del
/// `BuferDeEscucha`, y no sabe qué detector de voz hay atrás: recibe una
/// probabilidad por trozo. Puro: los tests le pasan probabilidades inventadas.
public struct VentanaDeEscucha: Sendable {
  public struct Ajustes: Sendable, Equatable {
    public var tasa: Double = 16_000
    /// Desde aquí un trozo tiene voz. 0,5 es el corte de Silero.
    public var umbralDeVoz: Float = 0.5
    /// Cuánto del principio de un tramo se transcribe para buscar el nombre.
    /// El nombre dura 0,3–0,5 s; con 1,5 s el motor tiene contexto para
    /// poner la coma que lo aparta (`NombreQueDespierta`).
    public var ventanaDelNombre: Double = 1.5
    /// Silencio que cierra un tramo sin nombre. Corto: cada tramo nuevo es
    /// otra oportunidad de oír un nombre al principio.
    public var silencioParaCortar: Double = 0.5
    /// Silencio que cierra lo que sigue a un nombre: el de `FinDelTurno`.
    public var silencioTrasElNombre: Double = 1.1
    /// Audio de antes del trozo que dio la voz: el detector llega tarde a la
    /// primera sílaba, y sin esto «Dilo» se oye «lo».
    public var antesDeLaVoz: Double = 0.35
    /// Audio que se agrega tras la última voz, para no comerse la última
    /// sílaba.
    public var despuesDeLaVoz: Double = 0.15
    /// Tope de un llamado: más que esto ya no es «Dilo, …», es alguien
    /// hablando. Tiene que caber en el `BuferDeEscucha`.
    public var maximoDelLlamado: Double = 10

    public init() {}

    func muestras(_ segundos: Double) -> Int { Int((segundos * tasa).rounded()) }
  }

  /// Lo que hay que hacer después de un trozo.
  public enum Accion: Equatable, Sendable {
    case nada
    /// Transcribir este tramo y preguntarle a `NombreQueDespierta`; la
    /// respuesta vuelve por `resolver(hayNombre:)`.
    case buscarNombre(Range<Int>)
    /// El nombre estaba y la persona terminó: transcribir el tramo entero y
    /// avisar el llamado con lo que siguió al nombre.
    case transcribirLlamado(Range<Int>)
    /// El nombre estaba en un tramo que ya había terminado: el texto de la
    /// búsqueda es el llamado entero, no hay que transcribir otra vez.
    case llamarConLoBuscado
  }

  enum Estado: Equatable {
    case quieta
    case oyendo(inicio: Int, ultimaVoz: Int)
    /// Se pidió buscar el nombre; `cerrado` dice si el tramo ya terminó
    /// cuando se pidió (la búsqueda fue el tramo entero).
    case esperando(inicio: Int, ultimaVoz: Int, cerrado: Bool)
    case ignorando(ultimaVoz: Int)
    case llamado(inicio: Int, ultimaVoz: Int)
  }

  public let ajustes: Ajustes
  private(set) var estado: Estado = .quieta

  public init(ajustes: Ajustes = Ajustes()) {
    self.ajustes = ajustes
  }

  /// Si hay una búsqueda o un llamado en curso: mientras tanto el búfer no se
  /// puede vaciar.
  public var ocupada: Bool { estado != .quieta }

  /// Un trozo del detector: `probabilidad` de voz en `inicio..<fin`.
  public mutating func trozo(probabilidad: Float, inicio: Int, fin: Int) -> Accion {
    let voz = probabilidad >= ajustes.umbralDeVoz
    switch estado {
    case .quieta:
      guard voz else { return .nada }
      estado = .oyendo(inicio: max(0, inicio - ajustes.muestras(ajustes.antesDeLaVoz)), ultimaVoz: fin)
      return revisarVentana(fin: fin)

    case let .oyendo(desde, ultimaVoz):
      let ultima = voz ? fin : ultimaVoz
      estado = .oyendo(inicio: desde, ultimaVoz: ultima)
      if !voz, fin - ultima >= ajustes.muestras(ajustes.silencioParaCortar) {
        estado = .esperando(inicio: desde, ultimaVoz: ultima, cerrado: true)
        return .buscarNombre(desde..<cierre(ultima, fin: fin))
      }
      return revisarVentana(fin: fin)

    case let .esperando(desde, ultimaVoz, cerrado):
      estado = .esperando(inicio: desde, ultimaVoz: voz ? fin : ultimaVoz, cerrado: cerrado)
      return .nada

    case let .ignorando(ultimaVoz):
      let ultima = voz ? fin : ultimaVoz
      estado = fin - ultima >= ajustes.muestras(ajustes.silencioParaCortar) ? .quieta : .ignorando(ultimaVoz: ultima)
      return .nada

    case let .llamado(desde, ultimaVoz):
      let ultima = voz ? fin : ultimaVoz
      let callado = fin - ultima >= ajustes.muestras(ajustes.silencioTrasElNombre)
      let largo = fin - desde >= ajustes.muestras(ajustes.maximoDelLlamado)
      guard callado || largo else {
        estado = .llamado(inicio: desde, ultimaVoz: ultima)
        return .nada
      }
      // Cortado por largo, lo que sigue es la misma persona hablando: se
      // ignora hasta que se calle, como un tramo sin nombre.
      estado = callado ? .quieta : .ignorando(ultimaVoz: ultima)
      return .transcribirLlamado(desde..<cierre(ultima, fin: fin))
    }
  }

  /// La respuesta a un `buscarNombre`.
  public mutating func resolver(hayNombre: Bool) -> Accion {
    guard case let .esperando(desde, ultimaVoz, cerrado) = estado else { return .nada }
    switch (hayNombre, cerrado) {
    case (true, true):
      estado = .quieta
      return .llamarConLoBuscado
    case (true, false):
      estado = .llamado(inicio: desde, ultimaVoz: ultimaVoz)
    case (false, true):
      estado = .quieta
    case (false, false):
      estado = .ignorando(ultimaVoz: ultimaVoz)
    }
    return .nada
  }

  /// Vuelve a empezar: se pausó la escucha o se vació el búfer.
  public mutating func olvidar() {
    estado = .quieta
  }

  private mutating func revisarVentana(fin: Int) -> Accion {
    guard case let .oyendo(desde, ultimaVoz) = estado,
      fin - desde >= ajustes.muestras(ajustes.ventanaDelNombre)
    else { return .nada }
    estado = .esperando(inicio: desde, ultimaVoz: ultimaVoz, cerrado: false)
    return .buscarNombre(desde..<fin)
  }

  private func cierre(_ ultimaVoz: Int, fin: Int) -> Int {
    min(fin, ultimaVoz + ajustes.muestras(ajustes.despuesDeLaVoz))
  }
}

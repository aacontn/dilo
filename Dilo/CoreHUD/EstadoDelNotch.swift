import Foundation

/// Los cinco estados del contrato del notch
/// (`docs/design/2026-09-21-experiencia-dilo.md`, tabla «Contrato del notch»).
///
/// El notch no es una ventana que se abre y se cierra: es un **escenario
/// permanente**. Siempre está uno de estos cinco estados en pantalla, y
/// `reposo` —la silueta compacta— es el que más dura. Por eso el estado es un
/// tipo propio y no una bolsa de banderas en el contenido: «está escuchando»,
/// «está procesando» y «ya terminó» son excluyentes, y con banderas sueltas
/// terminan solapándose (la píldora heredada mostraba onda mientras esperaba
/// un modelo que todavía no cargaba).
///
/// Puro a propósito: sin AppKit ni SwiftUI, para que las transiciones y los
/// tiempos se puedan probar sin abrir una ventana.
enum EstadoDelNotch: Equatable, Sendable {
  /// Presencia discreta permanente. No escucha, no anima, y un clic abre el
  /// menú de acciones —el mismo del status item—.
  case reposo

  /// Falta algo antes de poder escuchar: el modelo, un permiso, el
  /// micrófono abriéndose. Dice qué falta; nunca dibuja una onda ficticia.
  case preparando(FaltaDelNotch)

  /// El micrófono está abierto. Es el **único** estado que captura.
  case dictando

  /// Lo ya grabado se está transformando. No puede parecer que sigue
  /// grabando: acá no hay onda ni texto parcial.
  case procesando

  /// Lo entregado, por unos segundos, con la acción de copiar a mano.
  /// Después vuelve solo a reposo.
  case resultado(ResultadoDelNotch)

  /// Si el micrófono está abierto en este estado.
  ///
  /// Es la regla que el contrato pone primero: **reposo no escucha**. Vive acá
  /// y no en el controlador porque es una propiedad del estado, y un test puro
  /// la puede afirmar para los cinco sin abrir un micrófono.
  var captura: Bool {
    self == .dictando
  }

  /// Si en este estado hay algo moviéndose solo en pantalla: un `TimelineView`
  /// corriendo, un shader redibujándose cada frame.
  ///
  /// El reposo del spec §3 (~0 % de CPU, < 60 MB) depende de que esto sea
  /// falso mientras nadie dicta. Una forma quieta cuesta lo que cuesta una
  /// ventana; una que respira cuesta 60 cuadros por segundo para siempre.
  var anima: Bool {
    switch self {
    case .dictando, .procesando: true
    case .reposo, .preparando, .resultado: false
    }
  }

  /// Si la forma recibe el mouse. Reposo, para abrir el menú; resultado, para
  /// copiar. Mientras se dicta no: el clic es del documento en el que estás
  /// escribiendo, no del HUD.
  var tomaElMouse: Bool {
    switch self {
    case .reposo, .resultado: true
    case .preparando, .dictando, .procesando: false
    }
  }

  /// Si la forma está en su silueta compacta en vez de abierta.
  var esCompacto: Bool {
    self == .reposo
  }

  /// El nombre corto con que este estado aparece en el log de la muesca
  /// (`RegistroDeLaMuesca`). Sin pasar por el catálogo a propósito: `log show`
  /// tiene que leerse igual en un Mac en inglés que en uno en español, y el
  /// valor asociado no viaja — lo que se está diagnosticando ahí es el tamaño
  /// de la forma, no qué dice.
  var nombreEnElLog: String {
    switch self {
    case .reposo: "reposo"
    case .preparando: "preparando"
    case .dictando: "dictando"
    case .procesando: "procesando"
    case .resultado: "resultado"
    }
  }

  /// La línea que le toca a este estado, o nil cuando no dice nada.
  var texto: String? {
    switch self {
    case .reposo: nil
    case let .preparando(falta): falta.texto
    case .dictando: nil
    // Sin nombrar el modo: si hay uno, el chip ya lo dice, y repetirlo en
    // dos líneas es la mitad de la forma diciendo lo mismo.
    case .procesando: String(localized: "Procesando…")
    case let .resultado(resultado): resultado.texto
    }
  }
}

/// Qué falta para poder escuchar. El caso `.aviso` lleva el texto tal cual lo
/// arma el controlador de dictado, que es el único que sabe qué modelo se está
/// bajando y con qué porcentaje.
enum FaltaDelNotch: Equatable, Sendable {
  case cargandoModelo
  case permisoDeMicrofono
  case permisoDeDictado
  case aviso(String)

  var texto: String {
    switch self {
    case .cargandoModelo: String(localized: "Cargando el modelo…")
    case .permisoDeMicrofono: String(localized: "Falta el permiso del micrófono")
    case .permisoDeDictado: String(localized: "Falta el permiso de dictado")
    case let .aviso(texto): texto
    }
  }
}

/// Con qué termina una sesión. Los dos primeros ofrecen Copiar; un aviso no
/// —no hay nada que copiar en «No se pudo pegar el texto»—.
enum ResultadoDelNotch: Equatable, Sendable {
  /// Las palabras aterrizaron donde tenían que aterrizar.
  case listo
  /// No se pudo pegar, pero el texto está en el portapapeles: las palabras no
  /// se perdieron, que es lo que el contrato prohíbe.
  case copiado
  /// Cualquier otra cosa que el HUD tenga que decir, incluidos los errores.
  case aviso(String)

  var texto: String {
    switch self {
    case .listo: String(localized: "Listo")
    case .copiado: String(localized: "Copiado al portapapeles")
    case let .aviso(texto): texto
    }
  }

  /// Si este resultado tiene texto que copiar.
  var ofreceCopiar: Bool {
    switch self {
    case .listo, .copiado: true
    case .aviso: false
    }
  }
}

/// Las transiciones del contrato, sin efectos y sin reloj.
///
/// Un reducer, como `DictationSessionMachine` (ADR-0005): recibe un evento,
/// mueve el estado y devuelve lo que hay que hacer con el tiempo. Quién
/// duerme y con qué reloj es problema de `ControlDelNotch`.
struct MaquinaDelNotch: Equatable, Sendable {
  /// Cuánto se queda el resultado antes de volver a reposo. Dos segundos y
  /// medio: alcanza para leer «Copiado al portapapeles» y para alcanzar a
  /// hacer clic en Copiar, y no tanto como para que la forma abierta se
  /// vuelva parte del escritorio.
  static let duracionDelResultado = Duration.milliseconds(2_500)

  enum Evento: Equatable, Sendable {
    case preparar(FaltaDelNotch)
    case escuchar
    case procesar
    case entregar(ResultadoDelNotch)
    /// La sesión se cayó o se canceló: vuelta inmediata a reposo.
    case cancelar
    /// Venció el resultado número `turno`. El turno viaja en el evento
    /// porque un resultado nuevo puede llegar antes de que venza el
    /// anterior, y el temporizador viejo no puede llevarse el nuevo puesto.
    case expiroElResultado(turno: Int)
  }

  enum Efecto: Equatable, Sendable {
    /// Volver a reposo dentro de `duracion`, avisando con este turno.
    case programarVueltaAReposo(Duration, turno: Int)
    /// Olvidar el temporizador armado, si había.
    case cancelarVuelta
  }

  private(set) var estado = EstadoDelNotch.reposo
  /// Cuántos resultados se han mostrado. Es el turno que viaja en el
  /// temporizador.
  private(set) var turnoDelResultado = 0

  mutating func recibir(_ evento: Evento) -> [Efecto] {
    switch evento {
    case let .preparar(falta):
      estado = .preparando(falta)
      return [.cancelarVuelta]

    case .escuchar:
      estado = .dictando
      return [.cancelarVuelta]

    case .procesar:
      // Sólo se procesa lo que se grabó. Desde reposo o desde un resultado
      // esto es un evento perdido de una sesión que ya terminó, y moverlo
      // dejaría la forma abierta diciendo que trabaja sin nada que hacer.
      guard estado == .dictando || esPreparando else { return [] }
      estado = .procesando
      return [.cancelarVuelta]

    case let .entregar(resultado):
      estado = .resultado(resultado)
      turnoDelResultado += 1
      return [.programarVueltaAReposo(Self.duracionDelResultado, turno: turnoDelResultado)]

    case .cancelar:
      estado = .reposo
      return [.cancelarVuelta]

    case let .expiroElResultado(turno):
      // Un vencimiento viejo no baja un resultado nuevo, y tampoco cierra
      // una sesión que ya empezó de nuevo.
      guard turno == turnoDelResultado, case .resultado = estado else { return [] }
      estado = .reposo
      return []
    }
  }

  private var esPreparando: Bool {
    if case .preparando = estado { return true }
    return false
  }
}

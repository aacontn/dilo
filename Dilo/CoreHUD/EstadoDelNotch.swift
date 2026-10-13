import DiloCapabilities
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

  /// Cómo terminó, por un instante, en la misma muesca y sin crecer.
  ///
  /// **Dejó de ser una franja con botones** (2026-09-22): eran 400×50 con
  /// «Listo» y «Copiar» al lado. Un dictado que aterriza donde tenía que
  /// aterrizar acusa recibo con un check donde estaba la onda —«podría
  /// reemplazarse la onda por un check o algo así como lo hacíamos en el
  /// Tauri»— y se va en menos de un segundo. Lo que sí se dice con palabras
  /// es el camino del error: que el pegado falló, que falta un permiso, un
  /// aviso. «Copiar el último dictado» vive en el menú de la barra y en el
  /// panel del hover, que es donde alguien lo va a ir a buscar cuando lo
  /// necesite.
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

  /// Si la forma recibe el mouse. Reposo: ahí un clic abre el menú de
  /// acciones, o copia lo último dictado con el panel del hover abierto.
  ///
  /// Mientras hay una sesión no: el clic es del documento en el que estás
  /// escribiendo, no del HUD. Los errores y avisos tampoco, porque no tienen
  /// ninguna acción que ofrecer. La única excepción es la tarjeta de un
  /// dictado que no se pegó: ofrece el texto para copiarlo o arrastrarlo, y
  /// eso sólo se hace con el mouse.
  var tomaElMouse: Bool {
    switch self {
    case .reposo, .resultado(.retenido): true
    case .preparando, .dictando, .procesando, .resultado: false
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
    // El acuse no lleva palabras: el check las dice todas.
    case let .resultado(resultado): resultado.esAcuse ? nil : resultado.texto
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

/// Con qué termina una sesión.
///
/// **Uno se acusa y los otros dos se dicen.** El camino feliz —`listo`— no
/// tiene nada que informar: un check donde estaba la onda, menos de un
/// segundo, y a reposo. Los otros dos son el camino del error, y ahí sí hay
/// palabras, porque el contrato del notch prohíbe perder las palabras en
/// silencio.
enum ResultadoDelNotch: Equatable, Sendable {
  /// Las palabras aterrizaron donde tenían que aterrizar.
  case listo
  /// No se pudo pegar, pero el texto está en el portapapeles: las palabras no
  /// se perdieron, que es lo que el contrato prohíbe.
  case copiado
  /// Cualquier otra cosa que el HUD tenga que decir, incluidos los errores.
  case aviso(String)
  /// El dictado no entró, o no se sabe si entró: la tarjeta lo ofrece para
  /// copiar o arrastrar mientras siga en pantalla.
  case retenido(TarjetaDeRespaldo)

  var texto: String {
    switch self {
    case .listo: String(localized: "Listo")
    case .copiado: String(localized: "Copiado al portapapeles")
    case let .aviso(texto): texto
    case let .retenido(tarjeta): tarjeta.titulo
    }
  }

  /// Si esto es un acuse y no un mensaje: el check, sin palabras.
  var esAcuse: Bool { self == .listo }

  /// Cuánto se queda en pantalla. El acuse es un parpadeo; un error hay que
  /// alcanzar a leerlo; la tarjeta, alcanzar a usarla.
  var duracion: Duration {
    if case .retenido = self { return MaquinaDelNotch.duracionDeLaTarjeta }
    return esAcuse ? MaquinaDelNotch.duracionDelAcuse : MaquinaDelNotch.duracionDelResultado
  }

  /// La tarjeta que está a la vista, si es una.
  var tarjeta: TarjetaDeRespaldo? {
    if case let .retenido(tarjeta) = self { return tarjeta }
    return nil
  }
}

/// Lo que dice y ofrece la tarjeta de un dictado que no se pegó.
///
/// Perder un dictado en silencio está prohibido: lo que no entró se dice con
/// palabras y se ofrece entero. Un clic lo copia y se puede arrastrar a donde
/// iba; mientras la tarjeta dura, además, sigue en el portapapeles para ⌘V.
struct TarjetaDeRespaldo: Equatable, Sendable {
  enum Porque: Equatable, Sendable {
    /// Se mandó el ⌘V y nada lo confirmó ni lo desmintió.
    case sinConfirmar
    case noSePego(MotivoParaNoPegar)
  }

  let texto: String
  let porque: Porque

  /// Una línea que cabe en la muesca. Dice qué pasó y qué hacer; el detalle
  /// de cómo copiarlo aparece al poner el puntero encima.
  var titulo: String {
    switch porque {
    case .sinConfirmar: String(localized: "¿No se pegó? Pulsa ⌘V")
    case .noSePego(.focoCambio): String(localized: "Cambiaste de lugar: pulsa ⌘V")
    case .noSePego(.entradaSegura): String(localized: "Es una contraseña: no lo pegué")
    case .noSePego(.teclasSostenidas): String(localized: "Teclas apretadas: pulsa ⌘V")
    case .noSePego(.sinRespaldo), .noSePego(.portapapelesAjeno):
      String(localized: "No lo pegué: clic para copiar")
    case .noSePego(.sinAtajo): String(localized: "No pude pegarlo: pulsa ⌘V")
    case .noSePego(.noEntro): String(localized: "No entró: pulsa ⌘V")
    }
  }

  /// Lo que dice con el puntero encima: los dos gestos que no se ven.
  static var pista: String { String(localized: "Clic para copiar · o arrástralo") }
}

extension TarjetaDeRespaldo {
  /// La tarjeta que un cambio de estado deja tapada, si alguno.
  ///
  /// Antes, lo que empezaba encima de la tarjeta la tapaba y el texto sólo
  /// seguía en «Copiar el último dictado» —que el dictado siguiente pisa—.
  /// Ahora una tarjeta tapada se corre a una píldora al costado
  /// (`ActividadDeLaMuesca.retenido`) y se puede copiar con un clic cuando lo
  /// que la tapó termina.
  ///
  /// No cuenta como tapada si volvió a reposo (venció, o se canceló), si se
  /// copió con el clic de la propia tarjeta (`.copiado`) ni si otra tarjeta
  /// la reemplazó: en los tres casos no queda nada pendiente de ella.
  static func tapada(de anterior: EstadoDelNotch, a nuevo: EstadoDelNotch) -> TarjetaDeRespaldo? {
    guard case let .resultado(.retenido(tarjeta)) = anterior else { return nil }
    switch nuevo {
    case .reposo, .resultado(.copiado), .resultado(.retenido):
      return nil
    case .preparando, .dictando, .procesando, .resultado:
      return tarjeta
    }
  }

  /// Cuánto se queda la píldora de una tarjeta tapada, contado desde que la
  /// muesca vuelve a reposo; mientras dura otra sesión no corre. Un minuto:
  /// lo que tarda alguien en darse cuenta de que el dictado de antes no
  /// llegó. Después el texto sigue en los recientes del panel del hover.
  static let duracionEnPildora = Duration.seconds(60)
}

extension ResultadoDelNotch {
  /// Lo que la muesca dice de una entrega. Vive acá y no en el controlador
  /// de dictado para que el contrato de qué se acusa y qué se dice esté en un
  /// solo lugar, y se pruebe sin una sesión.
  ///
  /// Lo que entró se acusa con el check. Lo que no entró, o no se sabe, es
  /// la tarjeta: un pegado sin confirmar casi siempre es un ⌘V que no llegó,
  /// y callarlo es perder el dictado en silencio.
  static func tras(_ entrega: ResultadoDeEntrega, texto: String) -> ResultadoDelNotch {
    switch entrega {
    case .pegado, .nadaQueEntregar: .listo
    case .copiado: .copiado
    case .pegadoSinConfirmar: .retenido(TarjetaDeRespaldo(texto: texto, porque: .sinConfirmar))
    case let .retenido(motivo): .retenido(TarjetaDeRespaldo(texto: texto, porque: .noSePego(motivo)))
    }
  }
}

/// Las transiciones del contrato, sin efectos y sin reloj.
///
/// Un reducer, como `DictationSessionMachine` (ADR-0005): recibe un evento,
/// mueve el estado y devuelve lo que hay que hacer con el tiempo. Quién
/// duerme y con qué reloj es problema de `ControlDelNotch`.
struct MaquinaDelNotch: Equatable, Sendable {
  /// Cuánto se queda un resultado con palabras antes de volver a reposo. Dos
  /// segundos y medio: alcanza para leer «Copiado al portapapeles» o el
  /// motivo de un error, y no tanto como para que la forma abierta se vuelva
  /// parte del escritorio.
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

  /// Cuánto dura el acuse del camino feliz: el check donde estaba la onda.
  /// Menos de un segundo — más que eso deja de ser un acuse y empieza a ser
  /// un estado que alguien tiene que esperar.
  static let duracionDelAcuse = Duration.milliseconds(700)

  /// Lo que dura la tarjeta de un dictado sin pegar. Es lo mismo que el
  /// dictado se queda en el portapapeles (`TiemposDePegado.esperaSinSenal`):
  /// mientras se ve, ⌘V lo pega.
  static let duracionDeLaTarjeta = TiemposDePegado.deFabrica.esperaSinSenal

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
      // Cada resultado se queda lo suyo: el acuse es un parpadeo y un error
      // hay que alcanzar a leerlo. Una sola duración para los dos dejaba el
      // «Listo» dos segundos y medio en pantalla, que es la mitad de lo que
      // Alfonso rechazó el 2026-09-22.
      estado = .resultado(resultado)
      turnoDelResultado += 1
      return [.programarVueltaAReposo(resultado.duracion, turno: turnoDelResultado)]

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

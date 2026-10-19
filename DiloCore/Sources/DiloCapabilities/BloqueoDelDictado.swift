/// Por qué un **Dictado** no puede empezar, dicho **antes** de abrir el
/// micrófono.
///
/// Antes esto vivía en strings sueltos (`preparationFailureMessage`) y en
/// cuatro `guard` de `checkAndBegin`, y lo que ninguno miraba —un micrófono
/// quitado con la app abierta, el aviso del permiso sin contestar— se
/// descubría con el micrófono ya abierto y el motor fallando a media frase.
/// Tipado, la muesca dice el primero y un test cubre cada caso; el texto
/// visible lo pone la app, que es la que tiene el catálogo de idiomas.
///
/// La lista de casos es propia; la idea de nombrar cada bloqueo en vez de un
/// «no se pudo» genérico viene de cómo lo resuelven otras apps de dictado
/// (sólo la técnica, sin código).
public enum BloqueoDelDictado: Equatable, Sendable {
  /// El micrófono está denegado en Privacidad.
  case microfonoDenegado
  /// macOS todavía no preguntó, o la persona no contestó el aviso.
  case microfonoSinDecidir
  /// No hay ninguna entrada de audio: un Mac mini sin micrófono enchufado.
  case sinMicrofono
  case reconocimientoDeVozDenegado
  case sinAccesibilidad
  /// El idioma del motor de Apple se está bajando. Se resuelve solo.
  case bajandoModelo(idioma: String, porcentaje: Int?)
  /// El motor todavía se está preparando. Se resuelve solo.
  case preparandoMotor
  /// La preparación del motor falló por algo que no es un permiso; lleva el
  /// porqué tal como lo dijo el sistema.
  case motorFallo(String)
  case campoProtegido
  case traduccionSinIdioma
  case traduccionNoLista
  /// Se eligió traducir con Claude y no hay clave de Anthropic en el
  /// Llavero (2026-10-19). Distinto de «no está lista»: esperar no lo
  /// arregla, pegar la clave en Ajustes sí.
  case traduccionSinClave

  /// El permiso que lo arregla, para que quien lo muestre pueda ofrecer su
  /// panel exacto (`Permiso.panelDeAjustes`) sin repetir la lista.
  public var permiso: Permiso? {
    switch self {
    case .microfonoDenegado, .microfonoSinDecidir: .microfono
    case .reconocimientoDeVozDenegado: .reconocimientoDeVoz
    case .sinAccesibilidad: .accesibilidad
    case .sinMicrofono, .bajandoModelo, .preparandoMotor, .motorFallo,
      .campoProtegido, .traduccionSinIdioma, .traduccionNoLista, .traduccionSinClave:
      nil
    }
  }

  /// Si esperar lo arregla: no hay nada que la persona tenga que hacer.
  public var seResuelveSolo: Bool {
    switch self {
    case .bajandoModelo, .preparandoMotor: true
    default: false
    }
  }

  /// Para el log: una palabra que se lee igual en un Mac en inglés, y sin el
  /// porqué del sistema, que puede traer una ruta.
  public var nombreEnElLog: String {
    switch self {
    case .microfonoDenegado: "microfonoDenegado"
    case .microfonoSinDecidir: "microfonoSinDecidir"
    case .sinMicrofono: "sinMicrofono"
    case .reconocimientoDeVozDenegado: "reconocimientoDeVozDenegado"
    case .sinAccesibilidad: "sinAccesibilidad"
    case .bajandoModelo: "bajandoModelo"
    case .preparandoMotor: "preparandoMotor"
    case .motorFallo: "motorFallo"
    case .campoProtegido: "campoProtegido"
    case .traduccionSinIdioma: "traduccionSinIdioma"
    case .traduccionNoLista: "traduccionNoLista"
    case .traduccionSinClave: "traduccionSinClave"
    }
  }
}

/// Lo que se lee del sistema al apretar el gatillo, en una foto. Barato a
/// propósito: ninguna de estas lecturas abre el micrófono ni muestra un
/// diálogo, y todas juntas no le suman al arranque lo que se nota.
public struct PermisosLeidos: Equatable, Sendable {
  public var microfono: EstadoParaDictar.Autorizacion
  public var hayMicrofono: Bool
  public var reconocimientoDeVoz: EstadoParaDictar.Autorizacion

  public init(
    microfono: EstadoParaDictar.Autorizacion,
    hayMicrofono: Bool,
    reconocimientoDeVoz: EstadoParaDictar.Autorizacion
  ) {
    self.microfono = microfono
    self.hayMicrofono = hayMicrofono
    self.reconocimientoDeVoz = reconocimientoDeVoz
  }

  public static let todosConcedidos = PermisosLeidos(
    microfono: .concedida, hayMicrofono: true, reconocimientoDeVoz: .concedida
  )
}

/// Una foto de todo lo que decide si se puede dictar. Valor puro: el test
/// arma la foto que quiera y pregunta.
public struct EstadoParaDictar: Equatable, Sendable {
  public enum Autorizacion: Equatable, Sendable {
    case concedida, denegada, sinDecidir
  }

  /// En qué está el **Motor de voz** del idioma de esta sesión.
  public enum Motor: Equatable, Sendable {
    case listo
    case preparando
    case bajandoModelo(idioma: String, porcentaje: Int?)
    /// La preparación paró en un permiso. No es un bloqueo propio: el del
    /// permiso ya lo dice, y decirlo dos veces es la mitad de la lista
    /// repetida.
    case esperandoPermiso
    case fallo(String)
  }

  public enum Traduccion: Equatable, Sendable {
    /// La sesión no traduce.
    case noAplica
    case sinIdioma
    case noLista
    /// Traduce con Claude y falta la clave de Anthropic.
    case sinClave
    case lista
  }

  public var permisos: PermisosLeidos
  /// Si la preparación del motor exige el permiso de reconocimiento de voz.
  /// Hoy lo exige con los dos motores (`requestPermissionsAndPrepare`), y por
  /// eso la app pasa `true`; el día que Parakeet prepare sin él, esto se
  /// apaga para Parakeet sin tocar la regla.
  public var pideReconocimientoDeVoz: Bool
  /// Lo que este anfitrión puede hacer: lo que esconde no bloquea.
  public var admitePegadoDirecto: Bool
  public var accesibilidad: Bool
  public var motor: Motor
  public var campoEsSeguro: Bool
  public var traduccion: Traduccion

  public init(
    permisos: PermisosLeidos,
    pideReconocimientoDeVoz: Bool,
    admitePegadoDirecto: Bool,
    accesibilidad: Bool,
    motor: Motor,
    campoEsSeguro: Bool,
    traduccion: Traduccion
  ) {
    self.permisos = permisos
    self.pideReconocimientoDeVoz = pideReconocimientoDeVoz
    self.admitePegadoDirecto = admitePegadoDirecto
    self.accesibilidad = accesibilidad
    self.motor = motor
    self.campoEsSeguro = campoEsSeguro
    self.traduccion = traduccion
  }

  /// Todos los bloqueos, en el orden en que la persona los tiene que
  /// resolver: sin micrófono no sirve de nada lo demás, y un campo de clave
  /// sólo importa cuando todo lo otro está listo para dictar en él. La muesca
  /// dice el primero.
  ///
  /// El Monitoreo de entrada no está, a propósito: si el gatillo llegó, el
  /// tap ya lo oye, y una sesión abierta desde el menú no lo necesita.
  /// Tampoco la entrada segura de otra app: no impide dictar, y el pegado ya
  /// la mira al entregar (`CompuertasDelPegado`) y deja el texto en la
  /// tarjeta en vez de perderlo.
  public var bloqueos: [BloqueoDelDictado] {
    var lista: [BloqueoDelDictado] = []
    switch permisos.microfono {
    case .denegada: lista.append(.microfonoDenegado)
    case .sinDecidir: lista.append(.microfonoSinDecidir)
    case .concedida: if !permisos.hayMicrofono { lista.append(.sinMicrofono) }
    }
    if pideReconocimientoDeVoz, permisos.reconocimientoDeVoz != .concedida {
      lista.append(.reconocimientoDeVozDenegado)
    }
    if admitePegadoDirecto, !accesibilidad { lista.append(.sinAccesibilidad) }
    switch motor {
    case .listo, .esperandoPermiso: break
    case .preparando: lista.append(.preparandoMotor)
    case let .bajandoModelo(idioma, porcentaje):
      lista.append(.bajandoModelo(idioma: idioma, porcentaje: porcentaje))
    case let .fallo(porque): lista.append(.motorFallo(porque))
    }
    if campoEsSeguro { lista.append(.campoProtegido) }
    switch traduccion {
    case .noAplica, .lista: break
    case .sinIdioma: lista.append(.traduccionSinIdioma)
    case .noLista: lista.append(.traduccionNoLista)
    case .sinClave: lista.append(.traduccionSinClave)
    }
    return lista
  }

  /// El que la muesca dice, o nil si se puede dictar.
  public var primerBloqueo: BloqueoDelDictado? { bloqueos.first }
}

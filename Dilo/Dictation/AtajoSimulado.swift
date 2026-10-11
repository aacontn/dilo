import CoreGraphics

/// Un ⌘ + tecla que Dilo aprieta por la persona —⌘V para pegar lo dictado,
/// ⌘C para leer lo seleccionado—, contado entero: ⌘ baja, la tecla baja, la
/// tecla sube, ⌘ sube.
///
/// Antes se mandaba sólo la tecla con el flag de ⌘ puesto, sin que ⌘ bajara ni
/// subiera nunca como evento propio. El sistema podía quedarse creyendo que ⌘
/// seguía apretada, y el siguiente espacio que se escribía llegaba como
/// ⌘Espacio: Spotlight se abría solo justo después de dictar. La secuencia
/// completa es la que la documentación de `CGEventCreateKeyboardEvent` pide
/// para una mayúscula: el modificador baja y sube como una tecla más.
///
/// Lo que la persona tiene apretado de verdad se respeta: si ya sostiene ⌘,
/// Dilo no la aprieta ni la suelta por ella, y el último evento devuelve los
/// modificadores que de verdad están abajo —ninguno, casi siempre—. En el
/// medio la tecla viaja sólo con ⌘, porque ⇧ o ⌥ encima cambian el comando
/// (⌥⇧⌘V es «pegar con el estilo del destino»).
enum AtajoSimulado {
  /// ⌘ izquierda (`kVK_Command`): la que manda un teclado real en un ⌘V.
  static let comando: CGKeyCode = 55

  /// Lo que lleva `eventSourceUserData` en cada evento que Dilo simula, para
  /// que su propio tap lo deje pasar sin leerlo como un gatillo. "DILO".
  static let marca: Int64 = 0x4449_4C4F

  /// Las teclas modificadoras que se miran antes de simular: ⌘, ⇧, ⌥ y ⌃ de
  /// los dos lados, más fn.
  static let teclasModificadoras: [CGKeyCode] = [55, 54, 56, 60, 58, 61, 59, 62, 63]

  /// Los bits que describen modificadores en un `CGEventFlags`: los
  /// compartidos y los de cada lado (`NX_DEVICE*KEYMASK`). Es lo único que
  /// esta secuencia reescribe; el resto queda como CoreGraphics lo creó.
  static let bitsDeModificador = CGEventFlags(
    rawValue: CGEventFlags([
      .maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
      .maskCommand, .maskSecondaryFn,
    ]).rawValue | 0x2000 | 0x0040 | 0x0020 | 0x0010 | 0x0008 | 0x0004 | 0x0002 | 0x0001
  )

  /// Lo que la persona tiene apretado de verdad cuando Dilo va a simular.
  struct TeclasApretadas: Equatable, Sendable {
    /// Los modificadores físicamente abajo, por código de tecla.
    var modificadores: Set<CGKeyCode> = []
    /// Bloq Mayús es un estado y no una tecla sostenida: viaja en todos los
    /// eventos, para que ninguno lo apague a ojos de la app de destino.
    var bloqMayus = false

    static let ninguna = TeclasApretadas()

    /// Leídas del estado del teclado físico (`hidSystemState`) y no del de la
    /// sesión, que también suma lo que otros procesos simulan: un ⌘ que otra
    /// app dejó colgado se leería como de la persona y Dilo no lo soltaría.
    static func delTeclado() -> TeclasApretadas {
      TeclasApretadas(
        modificadores: Set(teclasModificadoras.filter {
          CGEventSource.keyState(.hidSystemState, key: $0)
        }),
        bloqMayus: CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
      )
    }

    /// Los bits que estas teclas ponen en un evento, con su lado: un ⌘ sin
    /// el bit de la izquierda se lee como ⌘ derecha, que es el gatillo de
    /// fábrica de Dictar y traducir.
    var bits: CGEventFlags {
      var bits: CGEventFlags = bloqMayus ? .maskAlphaShift : []
      for tecla in modificadores {
        bits.formUnion(AtajoSimulado.bits(de: tecla))
      }
      return bits
    }
  }

  /// Un evento de la secuencia, todavía como datos.
  struct Pulsacion: Equatable, Sendable {
    let tecla: CGKeyCode
    let abajo: Bool
    /// Los bits de modificador que lleva el evento, compartidos y de lado.
    let modificadores: CGEventFlags
  }

  /// La secuencia de ⌘ + `tecla`, respetando lo que la persona ya sostiene.
  ///
  /// El último evento lleva siempre exactamente `apretadas.bits`: así ningún
  /// modificador queda marcado por Dilo, y ninguno de la persona queda suelto.
  static func pulsaciones(
    de tecla: CGKeyCode,
    con apretadas: TeclasApretadas
  ) -> [Pulsacion] {
    let deLaPersona = apretadas.bits
    let comandoDeLaPersona = deLaPersona.intersection(bits(de: 55).union(bits(de: 54)))
    let laPersonaSostieneComando = !comandoDeLaPersona.isEmpty
    let comandoParaLaTecla = laPersonaSostieneComando ? comandoDeLaPersona : bits(de: comando)
    let conComando = comandoParaLaTecla.union(deLaPersona.intersection(.maskAlphaShift))

    guard !laPersonaSostieneComando else {
      return [
        Pulsacion(tecla: tecla, abajo: true, modificadores: conComando),
        Pulsacion(tecla: tecla, abajo: false, modificadores: deLaPersona),
      ]
    }
    return [
      Pulsacion(tecla: comando, abajo: true, modificadores: conComando),
      Pulsacion(tecla: tecla, abajo: true, modificadores: conComando),
      Pulsacion(tecla: tecla, abajo: false, modificadores: conComando),
      Pulsacion(tecla: comando, abajo: false, modificadores: deLaPersona),
    ]
  }

  /// Crea los eventos de todas las pulsaciones y recién entonces los publica.
  ///
  /// Si uno no se puede crear no se publica ninguno: un ⌘ que baja sin su
  /// subida es justamente lo que este tipo existe para impedir.
  ///
  /// - Returns: false si no se publicó nada.
  static func publicar(
    _ pulsaciones: [Pulsacion],
    crear: (Pulsacion) -> CGEvent?,
    publicar: (CGEvent) -> Void
  ) -> Bool {
    var eventos: [CGEvent] = []
    for pulsacion in pulsaciones {
      guard let evento = crear(pulsacion) else { return false }
      eventos.append(evento)
    }
    eventos.forEach(publicar)
    return true
  }

  /// El evento real de una pulsación, con sus modificadores y la marca.
  ///
  /// La fuente es la del teclado físico: es la tabla que un espacio escrito
  /// después lee para saber qué modificadores lo acompañan, así que el ⌘ que
  /// sube acá es el que la deja limpia.
  static func evento(
    _ pulsacion: Pulsacion,
    fuente: CGEventSource?
  ) -> CGEvent? {
    guard let evento = CGEvent(
      keyboardEventSource: fuente,
      virtualKey: pulsacion.tecla,
      keyDown: pulsacion.abajo
    ) else { return nil }
    evento.flags = evento.flags
      .subtracting(bitsDeModificador)
      .union(pulsacion.modificadores)
    evento.setIntegerValueField(.eventSourceUserData, value: marca)
    return evento
  }

  /// Si un evento lo simuló Dilo.
  static func esDeDilo(_ evento: CGEvent) -> Bool {
    evento.getIntegerValueField(.eventSourceUserData) == marca
  }

  /// Los bits de una tecla modificadora, compartido más el de su lado.
  static func bits(de tecla: CGKeyCode) -> CGEventFlags {
    let lado = KeyBinding.deviceMasks(forKeyCode: Int64(tecla))?.own ?? 0
    return KeyBinding.modifierMask(forKeyCode: Int64(tecla))
      .union(CGEventFlags(rawValue: lado))
  }
}

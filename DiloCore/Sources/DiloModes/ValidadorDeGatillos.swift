import Foundation

/// Qué gatillos Dilo acepta y cuáles rechaza antes de que alguien los guarde.
///
/// Sale de los diez minutos que Alfonso dictó con Talkify en un teclado ISO
/// latinoamericano (spec §8.1): el segundo idioma se disparaba con ⌥ derecha,
/// que en ese teclado es AltGr y escribe `@ # \ | { } [ ]`. Dictando prompts
/// arrancaba una sesión en inglés a cada rato y el texto salía mezclado. La
/// interfaz lo dejó guardar y nada avisó.
///
/// La regla de fondo: **un gatillo por defecto no puede escribir un símbolo en
/// teclado latino, y ninguno puede robarle al sistema el volumen.**
public enum ValidadorDeGatillos {
  /// Por qué un gatillo no sirve. El texto es el que se muestra: son reparos,
  /// no errores internos, y quien los lee está eligiendo una tecla.
  public enum Reparo: Equatable, Sendable {
    /// ⌥ sola, de cualquier lado. La derecha es AltGr; la izquierda también
    /// compone (⌥+letra escribe `œ ∂ ƒ`). Sostener ⌥ para dictar deja el
    /// teclado en modo símbolo mientras hablas.
    case opcionSola
    /// ⌥ como único modificador de una tecla que escribe: ⌥D es `∂`.
    case opcionMasTeclaQueEscribe
    /// Volumen, silencio, brillo. Son del sistema; no se toman prestadas.
    case teclaDelSistema
    /// Una tecla que escribe un carácter, sola y sin ningún modificador que
    /// lo evite: sostenerla para hablar llena el documento de letras.
    case teclaQueEscribeSola
    /// Sin tecla ni botón: no hay nada que apretar.
    case vacio
    /// Otro atajo de Dilo ya la usa. Lleva el nombre de quién: "esa tecla
    /// está ocupada" sin decir por quién obliga a ir a buscarla a mano.
    case yaLaUsa(String)

    public var explicacion: String {
      switch self {
      case let .yaLaUsa(quien):
        "Esa tecla ya la usa \(quien). Elige otra, o quítasela primero: dos "
          + "cosas con la misma tecla es un atajo muerto."
      case .opcionSola:
        "⌥ sola no sirve de gatillo: en un teclado latino es la tecla que "
          + "escribe @ # \\ | { } [ ], y sostenerla mientras hablas te deja "
          + "escribiendo símbolos. Prueba con fn o con una combinación con ⌘."
      case .opcionMasTeclaQueEscribe:
        "⌥ con una letra escribe un símbolo en vez de disparar el modo. "
          + "Agrégale ⌃ o ⌘, o usa otra tecla."
      case .teclaDelSistema:
        "Esa tecla es del volumen o del brillo. Son del sistema y Dilo no se "
          + "las quita a nadie."
      case .teclaQueEscribeSola:
        "Esa tecla escribe un carácter. Sostenerla para hablar te llenaría el "
          + "texto de letras. Agrégale ⌃ o ⌘, o usa una tecla que no escriba: "
          + "fn, F13 a F20, esc, Clear del teclado numérico."
      case .vacio:
        "Todavía no elegiste ninguna tecla."
      }
    }
  }

  public enum Veredicto: Equatable, Sendable {
    case sirve
    case noSirve(Reparo)

    public var sirve: Bool { self == .sirve }
    public var reparo: Reparo? {
      guard case let .noSirve(reparo) = self else { return nil }
      return reparo
    }
  }

  /// Teclas que en un teclado latino producen un carácter. Todo lo que no
  /// aparezca acá —Escape, tabulador, flechas, teclas de función, Enter— no
  /// escribe nada por sí solo y puede convivir con ⌥.
  ///
  /// Se listan por código de tecla porque la distribución cambia qué letra
  /// sale, pero no cambia si la tecla escribe o no.
  ///
  /// La tecla § de un teclado ISO no aparece: es la que Dilo deja disponible
  /// a propósito para quien la tiene, porque en la práctica nadie la usa para
  /// escribir y sí es cómoda de sostener con el meñique izquierdo.
  public static let teclasQueEscriben: Set<Int64> = Set(
    // Fila de números, las tres filas de letras, y los signos.
    [
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
      21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 38, 39,
      40, 41, 42, 43, 44, 45, 46, 47, 50,
      // Teclado numérico.
      65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
    ]
  )

  static let teclasModificadoras: Set<Int64> = [
    Gatillo.Tecla.comandoIzquierdo, Gatillo.Tecla.comandoDerecho,
    Gatillo.Tecla.opcionIzquierda, Gatillo.Tecla.opcionDerecha,
    Gatillo.Tecla.controlIzquierdo, Gatillo.Tecla.controlDerecho,
    Gatillo.Tecla.mayusculaIzquierda, Gatillo.Tecla.mayusculaDerecha,
    Gatillo.Tecla.fn,
  ]

  public static func revisar(_ gatillo: Gatillo) -> Veredicto {
    if gatillo.botonDelMouse != nil { return .sirve }
    guard let keyCode = gatillo.keyCode else { return .noSirve(.vacio) }

    if Gatillo.Tecla.sistema.contains(keyCode) { return .noSirve(.teclaDelSistema) }

    let esOpcion = keyCode == Gatillo.Tecla.opcionIzquierda
      || keyCode == Gatillo.Tecla.opcionDerecha
    let sinOtrosModificadores = gatillo.modifierFlags
      & ~(Gatillo.Modificador.opcion) == 0
    if esOpcion, sinOtrosModificadores { return .noSirve(.opcionSola) }

    // ⌥ sola como modificador exigido sobre una tecla que escribe: el sistema
    // compone el símbolo antes de que el tap de Dilo alcance a tragarse el
    // evento, así que el gatillo y el carácter salen juntos.
    let soloOpcion = gatillo.modifierFlags & ~Gatillo.Modificador.fn
      == Gatillo.Modificador.opcion
    if soloOpcion, teclasQueEscriben.contains(keyCode) {
      return .noSirve(.opcionMasTeclaQueEscribe)
    }

    // Una tecla que escribe, pelada. Es lo único que queda fuera: cualquier
    // tecla física que no produzca un carácter —fn, F13 a F20, esc, las
    // flechas, Clear del numérico, § en ISO— sirve de gatillo tal cual,
    // porque sostenerla no ensucia nada. Con un modificador encima la tecla
    // deja de escribir y vuelve a servir.
    let sinNingunModificador = gatillo.modifierFlags
      & ~Gatillo.Modificador.fn == 0
    if sinNingunModificador, teclasQueEscriben.contains(keyCode) {
      return .noSirve(.teclaQueEscribeSola)
    }

    return .sirve
  }

  /// Un atajo que ya está tomado, con el nombre que se le muestra a la
  /// persona. El `id` es para excluirse a sí mismo al revisar: reasignar a un
  /// modo la tecla que ya tenía no es una colisión.
  public struct GatilloEnUso: Equatable, Sendable {
    public var id: String
    public var nombre: String
    public var gatillo: Gatillo

    public init(id: String, nombre: String, gatillo: Gatillo) {
      self.id = id
      self.nombre = nombre
      self.gatillo = gatillo
    }
  }

  /// La revisión completa: la tecla sirve **y** no se la está quitando a
  /// nadie.
  ///
  /// Antes cada pantalla revisaba lo suyo: Modos comparaba contra los otros
  /// modos y Atajos contra los cuatro roles, así que la tecla del dictado y
  /// la de un modo podían quedar iguales y el modo no disparaba nunca. Una
  /// sola función, con todos los ocupados adentro, es la única forma de que
  /// no vuelva a pasar.
  ///
  /// - Parameter ocupados: todo lo que hoy tiene tecla en Dilo — dictado,
  ///   segundo idioma, traducir, leer en voz alta y cada modo.
  /// - Parameter salvo: el id de quien está eligiendo, para no chocar
  ///   consigo mismo.
  public static func revisar(
    _ gatillo: Gatillo,
    entre ocupados: [GatilloEnUso],
    salvo id: String? = nil
  ) -> Veredicto {
    let veredicto = revisar(gatillo)
    guard veredicto.sirve else { return veredicto }
    guard let choque = ocupados.first(where: {
      $0.id != id && $0.gatillo.disparaLoMismoQue(gatillo)
    }) else {
      return .sirve
    }
    return .noSirve(.yaLaUsa(choque.nombre))
  }

  /// Los gatillos que Dilo propone cuando nadie eligió nada. Ninguno escribe
  /// un símbolo en teclado latino: es la condición, no una coincidencia — el
  /// test lo pasa por `revisar` uno por uno.
  public static let porDefecto: [Gatillo] = [
    .fn, .controlOpcionEspacio, .controlComandoL,
  ]
}

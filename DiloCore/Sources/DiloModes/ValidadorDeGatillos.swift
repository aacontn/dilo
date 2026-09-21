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
    /// Sin tecla ni botón: no hay nada que apretar.
    case vacio

    public var explicacion: String {
      switch self {
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
  static let teclasQueEscriben: Set<Int64> = Set(
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

    return .sirve
  }

  /// Los gatillos que Dilo propone cuando nadie eligió nada. Ninguno escribe
  /// un símbolo en teclado latino: es la condición, no una coincidencia — el
  /// test lo pasa por `revisar` uno por uno.
  public static let porDefecto: [Gatillo] = [
    .fn, .controlOpcionEspacio, .controlComandoL,
  ]
}

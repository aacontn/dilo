import Foundation

/// Cómo se llama cada tecla física, por código de tecla (`kVK_*`).
///
/// Vive acá, del lado puro, y no en la app: Alfonso no podía asignar F18 ni
/// F19 en su teclado Apple extendido porque el único mapa de nombres que
/// existía —el de `KeyBinding.keyName`— terminaba en F15, y para todo lo demás
/// caía en `charactersIgnoringModifiers`. AppKit devuelve para las teclas de
/// función un carácter del área de uso privado (`NSF18FunctionKey`, `U+F715`),
/// que no dibuja nada: la fila de ajustes quedaba en blanco y parecía que la
/// tecla no se había grabado. Un mapa sin pantalla se testea; el de antes no.
///
/// La regla: **ninguna tecla se queda sin nombre**. Cuando no hay leyenda, el
/// último recurso es `Tecla 0x4F`, que al menos es distinto para cada tecla y
/// se puede comparar con lo que muestra el visor de teclado de macOS.
public enum NombresDeTecla {
  /// Los códigos de las teclas de función, F1 a F20. Están desordenados
  /// respecto del número a propósito: así los numeró Apple en `Events.h` y
  /// escribirlos "ordenados" sería inventarlos.
  public static let funcion: [Int64: Int] = [
    122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8,
    101: 9, 109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15,
    106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
  ]

  /// Las teclas con glifo o palabra fija: las que no cambian con la
  /// distribución del teclado porque no escriben nada.
  public static let fijas: [Int64: String] = [
    53: "⎋", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    114: "Ayuda", 115: "Inicio", 116: "Re Pág", 119: "Fin", 121: "Av Pág",
    57: "Bloq Mayús", 110: "Menú",
    // Teclado numérico. Clear y Enter no escriben; el resto sí, y el
    // validador los trata como tales.
    71: "Clear", 76: "Intro num", 65: "Num .", 67: "Num *", 69: "Num +",
    75: "Num /", 78: "Num -", 81: "Num =",
    82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4",
    87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
  ]

  /// Los modificadores, con el lado dicho cuando lo tienen. `fn`/🌐 entra acá
  /// aunque no combine: es una tecla que se puede sostener y por eso es el
  /// gatillo por defecto de Dilo.
  public static let modificadores: [Int64: String] = [
    63: "fn", 55: "⌘", 54: "⌘ derecha", 58: "⌥", 61: "⌥ derecha",
    59: "⌃", 62: "⌃ derecha", 56: "⇧", 60: "⇧ derecha",
  ]

  /// El nombre de una tecla, o nil si no hay ninguno fijo —una letra, un
  /// número, un signo: eso lo dice la distribución, que este módulo no ve.
  public static func nombreFijo(_ keyCode: Int64) -> String? {
    if let numero = funcion[keyCode] { return "F\(numero)" }
    if let nombre = fijas[keyCode] { return nombre }
    return modificadores[keyCode]
  }

  /// El nombre que se muestra pase lo que pase. `leyenda` es lo que la
  /// distribución imprime en la tecla (la "Ñ" de un teclado latino), y sólo se
  /// usa cuando no hay nombre fijo.
  ///
  /// Nunca devuelve vacío: una fila de ajustes con la tecla en blanco es la
  /// que hace creer que el atajo no se guardó.
  public static func nombre(_ keyCode: Int64, leyenda: String? = nil) -> String {
    if let fijo = nombreFijo(keyCode) { return fijo }
    if let leyenda, !leyenda.isEmpty { return leyenda.uppercased() }
    return String(format: "Tecla 0x%02X", keyCode)
  }

  /// Si un carácter viene del área de uso privado de Unicode. AppKit manda
  /// ahí las teclas de función y las de navegación (`U+F700`–`U+F8FF`): son
  /// códigos internos, no algo que se pueda mostrar ni usar de leyenda.
  public static func esCaracterPrivado(_ texto: String) -> Bool {
    guard let primero = texto.unicodeScalars.first else { return true }
    return (0xF700 ... 0xF8FF).contains(Int(primero.value))
  }
}

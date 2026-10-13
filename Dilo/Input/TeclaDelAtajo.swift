// La técnica —recorrer los códigos de tecla traduciendo con ⌘ y caer a la
// distribución latina cuando la activa no trae tabla— es la de Muesli y la de
// imnotpayingforwisprflow; el código es propio, sobre la misma traducción que
// `KeyboardLayout` usa para dibujar las teclas.
import Carbon
import CoreGraphics

/// Qué tecla física escribe una letra **con ⌘ apretada** en la distribución
/// activa. Es la que hay que apretar para ⌘V y ⌘C: en Dvorak la V está donde
/// QWERTY tiene la K, y mandar la tecla 9 fija es mandar ⌘K.
///
/// Se resuelve en cada atajo y sin caché. Son a lo más 128 traducciones, unos
/// microsegundos, y así un cambio de distribución a mitad del dictado no deja
/// una tecla vieja.
enum TeclaDelAtajo {
  /// La de un teclado ANSI de EE. UU., para cuando nada contesta: es lo que
  /// Dilo mandaba siempre.
  static let deRespaldo: [Character: CGKeyCode] = ["v": 9, "c": 8]

  /// La tecla que escribe `letra` con ⌘ en la distribución activa.
  ///
  /// Traducir **con ⌘** es lo que resuelve «Dvorak – QWERTY ⌘», que escribe en
  /// Dvorak pero con ⌘ apretada se comporta como QWERTY. Un método de entrada
  /// (japonés, pinyin) puede no traer tabla propia: entonces se le pregunta a
  /// la distribución latina que el sistema le asocia.
  static func resolver(_ letra: Character) -> CGKeyCode {
    let fuentes = [
      TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
    ]
    for case let fuente? in fuentes {
      guard let tabla = tabla(de: fuente) else { continue }
      if let tecla = tecla(para: letra, traducir: { traducir($0, conComando: true, en: tabla) }) {
        return tecla
      }
    }
    return deRespaldo[letra] ?? 9
  }

  /// La primera tecla de 0 a 127 que, traducida, da `letra`. Separada de
  /// Carbon para probarla con una distribución inventada.
  static func tecla(
    para letra: Character,
    traducir: (CGKeyCode) -> String?
  ) -> CGKeyCode? {
    let buscada = String(letra).lowercased()
    return (0..<128).lazy.map { CGKeyCode($0) }.first { codigo in
      traducir(codigo)?.lowercased() == buscada
    }
  }

  /// La tabla Unicode de una fuente de entrada, o nil si no trae (los
  /// métodos de entrada que no son una distribución).
  private static func tabla(de fuente: TISInputSource) -> Data? {
    guard let puntero = TISGetInputSourceProperty(fuente, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    return Unmanaged<CFData>.fromOpaque(puntero).takeUnretainedValue() as Data
  }

  /// Lo que escribe `codigo` en esa tabla. `kUCKeyActionDown` y no el de
  /// dibujar que usa `KeyboardLayout`: acá importa qué produce apretarla, y
  /// con ⌘ abajo, que es lo que la app de destino va a recibir.
  private static func traducir(_ codigo: CGKeyCode, conComando: Bool, en tabla: Data) -> String? {
    // UCKeyTranslate quiere los modificadores de Carbon corridos ocho bits.
    let modificadores = conComando ? UInt32(cmdKey >> 8) & 0xFF : 0
    var muerta: UInt32 = 0
    var largo = 0
    var caracteres = [UniChar](repeating: 0, count: 4)
    let traducido = tabla.withUnsafeBytes { bytes -> Bool in
      guard let distribucion = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
      else { return false }
      return UCKeyTranslate(
        distribucion,
        codigo,
        UInt16(kUCKeyActionDown),
        modificadores,
        UInt32(LMGetKbdType()),
        // La máscara y no el número de bit: `…NoDeadKeysBit` vale 0, y pasarlo
        // como opción es no pedir nada.
        OptionBits(kUCKeyTranslateNoDeadKeysMask),
        &muerta,
        caracteres.count,
        &largo,
        &caracteres
      ) == noErr
    }
    guard traducido, largo > 0 else { return nil }
    return String(utf16CodeUnits: caracteres, count: largo)
  }
}

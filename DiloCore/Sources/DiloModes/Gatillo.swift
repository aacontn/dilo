import Foundation

/// Un gatillo: la tecla (o combinación) que dispara algo en Dilo.
///
/// Es un valor puro a propósito. El `KeyBinding` de Talkify vive en la app,
/// depende de AppKit y de `CGEventFlags`, y no se puede testear sin abrir
/// Xcode; las reglas de qué gatillo sirve y qué modo dispara sí se pueden, y
/// son justamente donde estuvo el bug que Alfonso encontró dictando. Por eso
/// el valor se copia acá con la misma forma —los mismos nombres de campo— y
/// la app traduce en una línea (`KeyBinding+Gatillo.swift`).
public struct Gatillo: Codable, Equatable, Hashable, Sendable {
  /// El código de tecla de macOS (`kVK_*`). Nil sólo cuando el gatillo es un
  /// botón del mouse, que Dilo acepta pero nunca propone.
  public var keyCode: Int64?
  /// Los modificadores exigidos, con los bits de `CGEventFlags`. Se guardan
  /// crudos para que el valor viaje entre la app y este módulo sin traducir.
  public var modifierFlags: UInt64
  /// Si la tecla ligada es en sí misma un modificador (fn, ⌘ derecha…).
  public var esModificador: Bool
  /// Lo que se muestra: "fn", "⌃ ⌥ espacio". Se captura al grabar el gatillo
  /// porque depende de la distribución del teclado, que este módulo no ve.
  public var etiqueta: String
  /// El carácter que el menú de la barra usa como equivalente de teclado.
  /// Vacío cuando la tecla no tiene uno (los modificadores pelados). Viaja
  /// con el gatillo para que la vuelta a `KeyBinding` no pierda nada.
  public var equivalenteDeMenu: String
  public var botonDelMouse: Int64?

  public init(
    keyCode: Int64? = nil,
    modifierFlags: UInt64 = 0,
    esModificador: Bool = false,
    etiqueta: String = "",
    equivalenteDeMenu: String = "",
    botonDelMouse: Int64? = nil
  ) {
    self.keyCode = keyCode
    self.modifierFlags = modifierFlags
    self.esModificador = esModificador
    self.etiqueta = etiqueta
    self.equivalenteDeMenu = equivalenteDeMenu
    self.botonDelMouse = botonDelMouse
  }

  /// Dos gatillos disparan lo mismo cuando coinciden la entrada y los
  /// modificadores. La etiqueta no entra: es texto para mirar, y dos teclados
  /// distintos la escriben distinto.
  public func disparaLoMismoQue(_ otro: Gatillo) -> Bool {
    keyCode == otro.keyCode
      && botonDelMouse == otro.botonDelMouse
      && modifierFlags == otro.modifierFlags
  }

  /// Los bits de `CGEventFlags` que Dilo mira. Se repiten acá como constantes
  /// para no arrastrar CoreGraphics a un módulo que se testea sin pantalla.
  public enum Modificador {
    public static let comando: UInt64 = 0x0010_0000
    public static let opcion: UInt64 = 0x0008_0000
    public static let control: UInt64 = 0x0004_0000
    public static let mayuscula: UInt64 = 0x0002_0000
    public static let fn: UInt64 = 0x0080_0000
  }

  /// Los códigos de tecla que este módulo necesita nombrar.
  public enum Tecla {
    public static let escape: Int64 = 53
    public static let espacio: Int64 = 49
    public static let comandoIzquierdo: Int64 = 55
    public static let comandoDerecho: Int64 = 54
    public static let opcionIzquierda: Int64 = 58
    public static let opcionDerecha: Int64 = 61
    public static let controlIzquierdo: Int64 = 59
    public static let controlDerecho: Int64 = 62
    public static let mayusculaIzquierda: Int64 = 56
    public static let mayusculaDerecha: Int64 = 60
    public static let fn: Int64 = 63

    /// Volumen y silencio (`kVK_VolumeUp`, `VolumeDown`, `Mute`) y el brillo.
    /// Son teclas del sistema: robarlas deja a la persona sin subir el volumen
    /// y sin forma obvia de entender por qué.
    public static let sistema: Set<Int64> = [72, 73, 74, 144, 145, 107, 113]
  }

  /// El gatillo por defecto del dictado: fn/🌐 sostenido. No escribe nada en
  /// ningún teclado, latino incluido.
  public static let fn = Gatillo(
    keyCode: Tecla.fn, esModificador: true, etiqueta: "fn"
  )

  /// La alternativa cuando fn está tomada: ⌃⌥Espacio.
  public static let controlOpcionEspacio = Gatillo(
    keyCode: Tecla.espacio,
    modifierFlags: Modificador.control | Modificador.opcion,
    etiqueta: "⌃ ⌥ espacio",
    equivalenteDeMenu: " "
  )

  /// El gatillo de fábrica del modo Limpio: ⌃⌘L. Lleva ⌘, que es lo que el
  /// spec §8.1 bendice, y ⌃ además lo saca del camino de los atajos de menú
  /// de cualquier app.
  public static let controlComandoL = Gatillo(
    keyCode: 37,
    modifierFlags: Modificador.control | Modificador.comando,
    etiqueta: "⌃ ⌘ L",
    equivalenteDeMenu: "l"
  )
}

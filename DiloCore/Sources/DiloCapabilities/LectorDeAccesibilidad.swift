import ApplicationServices
import Foundation

/// Las únicas llamadas reales a la API de Accesibilidad que hace Dilo.
///
/// Existe como costura para dos cosas. La primera es que `FullHost` sea
/// testeable sin tocar el sistema —un doble responde lo que el test quiera—.
/// La segunda es la que importa: con un espía en el medio, un test puede
/// **probar** que `SandboxedHost` no llama a Accesibilidad ni una vez, en
/// lugar de prometerlo en un comentario.
public protocol LectorDeAccesibilidad: Sendable {
  /// El elemento de todo el sistema, la raíz de cualquier pregunta por el foco.
  func elementoDelSistema() -> AXUIElement
  /// La raíz de una app concreta. Los navegadores no contestan por el
  /// elemento del sistema y sí por el suyo (medido en macOS 26).
  func elementoDeLaApp(_ pid: pid_t) -> AXUIElement
  /// Un atributo cualquiera. `.success` dice que se leyó, no de qué tipo es:
  /// quien lo pide comprueba el tipo antes de convertirlo.
  func atributo(_ elemento: AXUIElement, _ nombre: String) -> CFTypeRef?
  /// De qué proceso es este elemento.
  func pid(de elemento: AXUIElement) -> pid_t
  /// Si este proceso tiene Accesibilidad concedida.
  var estaAutorizado: Bool { get }
  /// Pide Accesibilidad mostrando el diálogo del sistema.
  func pedirAutorizacion() -> Bool
  /// Cuánto se espera a que una app conteste por este elemento. Una app
  /// trabada no puede colgar a Dilo: sin esto cada pregunta espera seis
  /// segundos.
  func fijarEspera(_ elemento: AXUIElement, segundos: Float)
  /// Si el atributo se puede escribir, o nil si la app no lo sabe decir.
  func seEscribe(_ elemento: AXUIElement, _ nombre: String) -> Bool?
  /// Un atributo con parámetro, como el texto de un rango
  /// (`kAXStringForRangeParameterizedAttribute`): leer cien caracteres
  /// alrededor del cursor sin copiar el documento entero por IPC.
  func atributoConParametro(
    _ elemento: AXUIElement, _ nombre: String, _ parametro: CFTypeRef
  ) -> CFTypeRef?
}

extension LectorDeAccesibilidad {
  /// Un doble de pruebas no espera a nadie.
  public func fijarEspera(_ elemento: AXUIElement, segundos: Float) {}

  public func seEscribe(_ elemento: AXUIElement, _ nombre: String) -> Bool? { nil }

  /// Un doble que no lo sabe contestar dice que no se pudo leer.
  public func atributoConParametro(
    _ elemento: AXUIElement, _ nombre: String, _ parametro: CFTypeRef
  ) -> CFTypeRef? { nil }
}

/// El lector de verdad: la API de Accesibilidad tal cual.
public struct AccesibilidadDelSistema: LectorDeAccesibilidad {
  public init() {}

  public func elementoDelSistema() -> AXUIElement {
    AXUIElementCreateSystemWide()
  }

  public func elementoDeLaApp(_ pid: pid_t) -> AXUIElement {
    AXUIElementCreateApplication(pid)
  }

  public func atributo(_ elemento: AXUIElement, _ nombre: String) -> CFTypeRef? {
    var valor: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      elemento,
      nombre as CFString,
      &valor
    ) == .success else {
      return nil
    }
    return valor
  }

  public func pid(de elemento: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(elemento, &pid)
    return pid
  }

  public var estaAutorizado: Bool {
    AXIsProcessTrusted()
  }

  public func pedirAutorizacion() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  public func fijarEspera(_ elemento: AXUIElement, segundos: Float) {
    AXUIElementSetMessagingTimeout(elemento, segundos)
  }

  public func seEscribe(_ elemento: AXUIElement, _ nombre: String) -> Bool? {
    var seEscribe = DarwinBoolean(false)
    switch AXUIElementIsAttributeSettable(elemento, nombre as CFString, &seEscribe) {
    case .success: return seEscribe.boolValue
    default: return nil
    }
  }

  public func atributoConParametro(
    _ elemento: AXUIElement, _ nombre: String, _ parametro: CFTypeRef
  ) -> CFTypeRef? {
    var valor: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      elemento, nombre as CFString, parametro, &valor
    ) == .success else { return nil }
    return valor
  }
}

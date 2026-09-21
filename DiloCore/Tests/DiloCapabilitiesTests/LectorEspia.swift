import ApplicationServices
import Foundation
import os

@testable import DiloCapabilities

/// Un lector de Accesibilidad que no lee nada y anota todo.
///
/// Sirve para dos cosas opuestas: darle a `FullHost` respuestas de mentira sin
/// tocar el sistema, y demostrar que `SandboxedHost` teniendo el lector a mano
/// no lo llama ni una vez.
final class LectorEspia: LectorDeAccesibilidad {
  /// El proceso de los tests. Un elemento válido que no pide ningún permiso:
  /// preguntarse a uno mismo siempre se puede.
  /// Computado y no `static let` porque `AXUIElement` no es `Sendable`:
  /// una constante global de ese tipo no compila con Swift 6.
  static var elementoPropio: AXUIElement {
    AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
  }

  private let estado = OSAllocatedUnfairLock(initialState: Estado())

  private struct Estado {
    var llamadas: [String] = []
    var atributos: [String: String] = [:]
    var atributosDeElemento: Set<String> = []
    var autorizado = false
  }

  /// - Parameters:
  ///   - atributos: qué contesta cada atributo de texto.
  ///   - atributosDeElemento: qué atributos contestan con otro elemento —el
  ///     propio, que es el único que se puede fabricar sin permisos.
  init(
    atributos: [String: String] = [:],
    atributosDeElemento: Set<String> = [],
    autorizado: Bool = false
  ) {
    estado.withLock {
      $0.atributos = atributos
      $0.atributosDeElemento = atributosDeElemento
      $0.autorizado = autorizado
    }
  }

  var llamadas: [String] { estado.withLock { $0.llamadas } }

  private func anotar(_ llamada: String) {
    estado.withLock { $0.llamadas.append(llamada) }
  }

  func elementoDelSistema() -> AXUIElement {
    anotar("elementoDelSistema")
    return Self.elementoPropio
  }

  func elementoDeLaApp(_ pid: pid_t) -> AXUIElement {
    anotar("elementoDeLaApp")
    return Self.elementoPropio
  }

  func atributo(_ elemento: AXUIElement, _ nombre: String) -> CFTypeRef? {
    anotar("atributo:\(nombre)")
    if estado.withLock({ $0.atributosDeElemento.contains(nombre) }) {
      return Self.elementoPropio
    }
    return estado.withLock { $0.atributos[nombre] } as CFTypeRef?
  }

  func pid(de elemento: AXUIElement) -> pid_t {
    anotar("pid")
    return 501
  }

  var estaAutorizado: Bool {
    anotar("estaAutorizado")
    return estado.withLock { $0.autorizado }
  }

  func pedirAutorizacion() -> Bool {
    anotar("pedirAutorizacion")
    return estado.withLock { $0.autorizado }
  }
}

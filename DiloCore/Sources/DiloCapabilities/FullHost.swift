import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// El anfitrión del target de venta directa: puede todo lo que macOS permite
/// con Accesibilidad concedida.
///
/// Es el comportamiento que la app siempre tuvo; acá sólo está puesto detrás
/// del contrato para que exista el otro lado.
public struct FullHost: HostCapabilities {
  private let lector: any LectorDeAccesibilidad
  private let pidAlFrente: @Sendable () -> pid_t

  /// - Parameter pidAlFrente: Qué proceso está al frente. Entra por acá para
  ///   que un test diga cuál es en vez de depender de la app que tenga el foco
  ///   la máquina que corre la suite.
  public init(
    lector: any LectorDeAccesibilidad = AccesibilidadDelSistema(),
    pidAlFrente: @escaping @Sendable () -> pid_t = {
      NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }
  ) {
    self.lector = lector
    self.pidAlFrente = pidAlFrente
  }

  public var nombre: String { "completo" }

  public func admite(_ capacidad: Capacidad) -> Bool { true }

  public var tieneAccesibilidad: Bool { lector.estaAutorizado }

  @discardableResult
  public func pedirAccesibilidad() -> Bool { lector.pedirAutorizacion() }

  /// Pregunta primero a la app al frente, igual que `focoParaLeer`: en macOS
  /// 26 el elemento del sistema contesta `kAXErrorCannotComplete` (−25204)
  /// para el foco aunque Accesibilidad esté concedida (medido el 2026-10-13).
  /// Preguntándole sólo a él, el pegado nunca tenía elemento: caía siempre a
  /// «la app al frente», el chequeo de campo de contraseña no saltaba nunca y
  /// `sigueSiendoElFoco` comparaba sólo el pid.
  public func elementoEnfocado() -> AXUIElement? {
    elementoEnfocadoDeLaAppAlFrente()
  }

  public func elemento(_ duenno: AXUIElement, atributo: String) -> AXUIElement? {
    guard let valor = lector.atributo(duenno, atributo),
      CFGetTypeID(valor) == AXUIElementGetTypeID()
    else { return nil }
    return (valor as! AXUIElement)
  }

  public func pid(de elemento: AXUIElement) -> pid_t {
    lector.pid(de: elemento)
  }

  public func esCampoSeguro(_ elemento: AXUIElement) -> Bool {
    lector.atributo(elemento, kAXSubroleAttribute as String) as? String
      == kAXSecureTextFieldSubrole as String
  }

  public func marco(de elemento: AXUIElement) -> CGRect? {
    guard let posicion = lector.atributo(elemento, kAXPositionAttribute as String),
      let tamano = lector.atributo(elemento, kAXSizeAttribute as String),
      CFGetTypeID(posicion) == AXValueGetTypeID(),
      CFGetTypeID(tamano) == AXValueGetTypeID()
    else { return nil }

    var origen = CGPoint.zero
    var medida = CGSize.zero
    guard AXValueGetValue(posicion as! AXValue, .cgPoint, &origen),
      AXValueGetValue(tamano as! AXValue, .cgSize, &medida)
    else { return nil }

    return CGRect(origin: origen, size: medida)
  }

  /// Con elemento, tienen que coincidir las dos cosas: que la app siga al
  /// frente y que su foco sea el mismo elemento. La primera la cubría antes el
  /// elemento del sistema, que sólo conoce el foco de la app activa; el de la
  /// app recuerda su foco también desde atrás, así que sin el chequeo del pid
  /// se pegaría en una ventana que ya no está a la vista.
  public func sigueSiendoElFoco(elemento: AXUIElement?, pid: pid_t) -> Bool {
    guard pidAlFrente() == pid else { return false }
    guard let elemento else { return true }
    guard let actual = elementoEnfocado(de: pid) ?? elementoEnfocadoDelSistema()
    else { return false }
    return CFEqual(actual, elemento)
  }

  public func focoParaLeer() -> FocoLegible? {
    guard let enfocado = elementoEnfocadoDeLaAppAlFrente() else { return nil }
    return FocoLegible(
      subrol: lector.atributo(enfocado, kAXSubroleAttribute as String) as? String,
      textoSeleccionado: lector.atributo(
        enfocado,
        kAXSelectedTextAttribute as String
      ) as? String
    )
  }

  public func tituloDeVentanaActiva() -> String? {
    guard let enfocado = elementoEnfocadoDeLaAppAlFrente() else { return nil }
    let ventana = elemento(enfocado, atributo: kAXWindowAttribute as String) ?? enfocado
    return lector.atributo(ventana, kAXTitleAttribute as String) as? String
  }

  public func anclaDelFoco(en pid: pid_t) -> AnclaDelFoco? {
    LecturaDelCampo(lector: lector).ancla(en: pid)
  }

  public func anclaSigueIgual(_ ancla: AnclaDelFoco) -> Bool {
    LecturaDelCampo(lector: lector).sigueIgual(ancla)
  }

  public func fotoDelCampo(_ ancla: AnclaDelFoco) -> FotoDelCampo {
    LecturaDelCampo(lector: lector).foto(de: ancla)
  }

  /// El foco se le pregunta primero a la app al frente y sólo después al
  /// elemento del sistema. Medido en macOS 26, el elemento del sistema no
  /// contesta por ninguna app —ni con texto claramente seleccionado— y el de
  /// la app devuelve el área de texto y su selección. El del sistema se
  /// queda como respaldo porque cuesta una llamada y este comportamiento es
  /// de los que vuelven.
  private func elementoEnfocadoDeLaAppAlFrente() -> AXUIElement? {
    elementoEnfocado(de: pidAlFrente()) ?? elementoEnfocadoDelSistema()
  }

  private func elementoEnfocado(de pid: pid_t) -> AXUIElement? {
    guard pid != 0 else { return nil }
    return elemento(
      lector.elementoDeLaApp(pid),
      atributo: kAXFocusedUIElementAttribute as String
    )
  }

  private func elementoEnfocadoDelSistema() -> AXUIElement? {
    elemento(lector.elementoDelSistema(), atributo: kAXFocusedUIElementAttribute as String)
  }
}

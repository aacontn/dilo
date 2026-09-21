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

  public init(lector: any LectorDeAccesibilidad = AccesibilidadDelSistema()) {
    self.lector = lector
  }

  public var nombre: String { "completo" }

  public func admite(_ capacidad: Capacidad) -> Bool { true }

  public var tieneAccesibilidad: Bool { lector.estaAutorizado }

  @discardableResult
  public func pedirAccesibilidad() -> Bool { lector.pedirAutorizacion() }

  public func elementoEnfocado() -> AXUIElement? {
    elemento(lector.elementoDelSistema(), atributo: kAXFocusedUIElementAttribute as String)
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

  public func sigueSiendoElFoco(elemento: AXUIElement?, pid: pid_t) -> Bool {
    guard let elemento else { return Self.pidAlFrente() == pid }
    guard let actual = lector.atributo(
      lector.elementoDelSistema(),
      kAXFocusedUIElementAttribute as String
    ) else { return false }
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

  /// El foco se le pregunta primero a la app al frente y sólo después al
  /// elemento del sistema. Medido en macOS 26, el elemento del sistema no
  /// contesta por ninguna app —ni con texto claramente seleccionado— y el de
  /// la app devuelve el área de texto y su selección. El del sistema se
  /// queda como respaldo porque cuesta una llamada y este comportamiento es
  /// de los que vuelven.
  private func elementoEnfocadoDeLaAppAlFrente() -> AXUIElement? {
    let pid = Self.pidAlFrente()
    if pid != 0,
      let enfocado = elemento(
        lector.elementoDeLaApp(pid),
        atributo: kAXFocusedUIElementAttribute as String
      ) {
      return enfocado
    }
    return elementoEnfocado()
  }

  private static func pidAlFrente() -> pid_t {
    NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
  }
}

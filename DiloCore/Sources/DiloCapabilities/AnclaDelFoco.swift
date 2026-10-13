// Técnica observada en imnotpayingforwisprflow (ancla con la selección leída
// dos veces, `AXSelectedTextMarkerRange` en editores web, campo editable de
// verdad) y Ocelli 2.1 (foto del campo con espera por mensaje y valor sólo
// hasta 20 000 caracteres); implementación propia sobre
// `LectorDeAccesibilidad`.
import ApplicationServices
import Foundation

/// Dónde estaba el cursor cuando empezó el dictado: el elemento y la
/// selección, sin leer el texto.
///
/// `@unchecked Sendable` porque `AXUIElement` es una referencia de
/// CoreFoundation inmutable que la API de Accesibilidad deja leer desde
/// cualquier hilo, y el ancla no cambia después de creada.
public struct AnclaDelFoco: @unchecked Sendable {
  public let pid: pid_t
  public let elemento: AXUIElement
  /// En campos nativos.
  public let seleccion: RangoDeTexto?
  /// En editores web (Safari, Chromium), donde no hay `AXSelectedTextRange`.
  /// Opaco: sólo sirve para compararlo con `CFEqual`.
  public let marcador: CFTypeRef?

  public init(pid: pid_t, elemento: AXUIElement, seleccion: RangoDeTexto?, marcador: CFTypeRef?) {
    self.pid = pid
    self.elemento = elemento
    self.seleccion = seleccion
    self.marcador = marcador
  }
}

/// Las lecturas del campo con foco, acotadas en tiempo. Sólo las usa
/// `FullHost`: en el sandbox no se pregunta nada.
struct LecturaDelCampo {
  let lector: any LectorDeAccesibilidad

  /// Por mensaje. Al empezar el dictado la persona está esperando, así que
  /// el ancla tiene poco; la foto después del ⌘V corre fuera del actor
  /// principal y puede esperar más.
  static let esperaDelAncla: Float = 0.025
  static let esperaDeLaFoto: Float = 0.25

  /// El elemento con el foco **dentro de la app** `pid`. Medido en macOS 26,
  /// el elemento del sistema no contesta por ninguna app.
  func elementoEnfocado(de pid: pid_t) -> AXUIElement? {
    guard pid > 0 else { return nil }
    let app = lector.elementoDeLaApp(pid)
    lector.fijarEspera(app, segundos: Self.esperaDelAncla)
    return elemento(app, kAXFocusedUIElementAttribute)
  }

  /// El ancla, o nil si no hay un campo editable con un cursor quieto. La
  /// selección se lee dos veces y tiene que dar lo mismo: un cursor que se
  /// mueve mientras se lee no es un ancla.
  func ancla(en pid: pid_t) -> AnclaDelFoco? {
    guard let hoja = elementoEnfocado(de: pid), esEditable(hoja) else { return nil }
    lector.fijarEspera(hoja, segundos: Self.esperaDelAncla)

    var elemento = hoja
    var seleccion = rango(de: hoja)
    if seleccion == nil,
      let editor = self.elemento(hoja, "AXEditableAncestor")
        ?? self.elemento(hoja, "AXHighestEditableAncestor") {
      lector.fijarEspera(editor, segundos: Self.esperaDelAncla)
      elemento = editor
      seleccion = rango(de: editor)
    }
    if let primera = seleccion {
      guard rango(de: elemento) == primera else { return nil }
      return AnclaDelFoco(pid: pid, elemento: elemento, seleccion: primera, marcador: nil)
    }
    guard let marcador = lector.atributo(elemento, "AXSelectedTextMarkerRange"),
      let otraVez = lector.atributo(elemento, "AXSelectedTextMarkerRange"),
      CFEqual(marcador, otraVez)
    else { return nil }
    return AnclaDelFoco(pid: pid, elemento: elemento, seleccion: nil, marcador: marcador)
  }

  /// Si el foco y el cursor siguen donde dice el ancla.
  func sigueIgual(_ ancla: AnclaDelFoco) -> Bool {
    guard let actual = elementoEnfocado(de: ancla.pid) else { return false }
    // El foco puede estar en la hoja y el ancla en su editor: vale si el
    // ancla es el foco o lo contiene.
    let mismoElemento = CFEqual(actual, ancla.elemento)
      || elemento(actual, "AXEditableAncestor").map { CFEqual($0, ancla.elemento) } == true
      || elemento(actual, "AXHighestEditableAncestor").map { CFEqual($0, ancla.elemento) } == true
    guard mismoElemento else { return false }
    if let seleccion = ancla.seleccion {
      return rango(de: ancla.elemento) == seleccion
    }
    guard let marcador = ancla.marcador,
      let ahora = lector.atributo(ancla.elemento, "AXSelectedTextMarkerRange")
    else { return false }
    return CFEqual(marcador, ahora)
  }

  /// Conteo, valor (si no es enorme) y selección del elemento del ancla.
  func foto(de ancla: AnclaDelFoco) -> FotoDelCampo {
    let elemento = ancla.elemento
    lector.fijarEspera(elemento, segundos: Self.esperaDeLaFoto)
    let conteo = (lector.atributo(elemento, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    var valor: String?
    if conteo.map({ $0 <= FotoDelCampo.largoMaximo }) ?? true {
      valor = lector.atributo(elemento, kAXValueAttribute) as? String
      if let leido = valor, leido.utf16.count > FotoDelCampo.largoMaximo { valor = nil }
    }
    return FotoDelCampo(
      conteo: conteo ?? valor.map { $0.utf16.count },
      valor: valor,
      seleccion: rango(de: elemento)
    )
  }

  /// Un campo donde pegar tiene sentido. Contraseñas, deshabilitados y de
  /// sólo lectura quedan fuera; una consulta que la app no entiende no es
  /// una negativa.
  func esEditable(_ elemento: AXUIElement) -> Bool {
    let rol = lector.atributo(elemento, kAXRoleAttribute) as? String
    let subrol = lector.atributo(elemento, kAXSubroleAttribute) as? String
    guard rol != "AXSecureTextField",
      subrol != kAXSecureTextFieldSubrole as String,
      booleano(elemento, "AXProtected") != true,
      booleano(elemento, kAXEnabledAttribute) != false,
      booleano(elemento, "AXReadOnly") != true,
      booleano(elemento, "AXEditable") != false
    else { return false }
    let deTexto = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] as [String]
    guard let rol, deTexto.contains(rol) else { return true }
    return lector.seEscribe(elemento, kAXValueAttribute) ?? true
  }

  private func elemento(_ duenno: AXUIElement, _ nombre: String) -> AXUIElement? {
    guard let valor = lector.atributo(duenno, nombre),
      CFGetTypeID(valor) == AXUIElementGetTypeID()
    else { return nil }
    return (valor as! AXUIElement)
  }

  private func booleano(_ elemento: AXUIElement, _ nombre: String) -> Bool? {
    (lector.atributo(elemento, nombre) as? NSNumber)?.boolValue
  }

  private func rango(de elemento: AXUIElement) -> RangoDeTexto? {
    guard let valor = lector.atributo(elemento, kAXSelectedTextRangeAttribute),
      CFGetTypeID(valor) == AXValueGetTypeID()
    else { return nil }
    var rango = CFRange()
    guard AXValueGetValue(valor as! AXValue, .cfRange, &rango) else { return nil }
    return RangoDeTexto(ubicacion: rango.location, largo: rango.length)
  }
}

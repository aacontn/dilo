// `alrededor(de:tope:)`: adaptado de Muesli ScreenContextCapture.swift:154-234
// (3878028), © 2026 Pranav Hari, MIT. Cambios: lee también después del cursor,
// parte del ancla ya capturada y pasa por `LectorDeAccesibilidad`.
// `LectorDeSitio`: técnica observada en BetterWispr WebsiteReader (Apache 2.0:
// `AXDocument` de la ventana o `AXURL` del `AXWebArea` más externo, espera
// corta por mensaje); implementación propia, con plazo total y sin su código.
import ApplicationServices
import Foundation

/// Lo que rodeaba al cursor cuando empezó el dictado. Vive en RAM lo que dura
/// la sesión: se arma, va al prompt y se suelta. Nunca va al historial ni a
/// un log.
public struct TextoAlrededorDelCursor: Equatable, Sendable {
  public var antes: String
  public var despues: String
  public var seleccion: String

  public init(antes: String = "", despues: String = "", seleccion: String = "") {
    self.antes = antes
    self.despues = despues
    self.seleccion = seleccion
  }

  public var estaVacio: Bool { antes.isEmpty && despues.isEmpty && seleccion.isEmpty }
}

/// Las lecturas del campo para el contexto de la limpieza. Sólo las usa
/// `FullHost`: en el sandbox no se pregunta nada.
struct LecturaDelContexto {
  let lector: any LectorDeAccesibilidad

  /// Por mensaje. Corre fuera del actor principal y en paralelo con el
  /// micrófono, pero una app trabada no puede retener el hilo segundos.
  static let espera: Float = 0.1
  /// Sobre esto el valor entero no se copia por IPC para recortarlo acá.
  static let largoMaximoDelValor = 5_000

  /// Hasta `tope` caracteres a cada lado de la selección del ancla, y la
  /// selección. Primero por rango, que es barato; si el campo no lo soporta
  /// y es chico, por el valor entero. En editores web sin rango (el ancla
  /// tiene marcador) no hay de dónde medir: vacío.
  func alrededor(de ancla: AnclaDelFoco, tope: Int) -> TextoAlrededorDelCursor {
    guard tope > 0, let cursor = ancla.seleccion else { return TextoAlrededorDelCursor() }
    let elemento = ancla.elemento
    lector.fijarEspera(elemento, segundos: Self.espera)
    let total = (lector.atributo(elemento, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue

    let desde = max(0, cursor.ubicacion - tope)
    let finDeSeleccion = cursor.ubicacion + cursor.largo
    let largoDespues = max(0, min(tope, (total ?? finDeSeleccion) - finDeSeleccion))
    let antes = texto(elemento, ubicacion: desde, largo: cursor.ubicacion - desde)
    let despues = texto(elemento, ubicacion: finDeSeleccion, largo: largoDespues)
    let seleccion = seleccion(elemento, cursor)
    if antes != nil || despues != nil {
      return TextoAlrededorDelCursor(antes: antes ?? "", despues: despues ?? "", seleccion: seleccion)
    }

    guard (total ?? 0) <= Self.largoMaximoDelValor,
      let valor = lector.atributo(elemento, kAXValueAttribute) as? String,
      valor.utf16.count <= Self.largoMaximoDelValor
    else { return TextoAlrededorDelCursor(seleccion: seleccion) }
    return Self.recortar(valor, cursor: cursor, tope: tope, seleccion: seleccion)
  }

  /// El recorte cuando sólo se pudo leer el valor entero. En unidades UTF-16,
  /// que es como cuenta Accesibilidad. Puro, para probarlo sin una app.
  static func recortar(
    _ valor: String, cursor: RangoDeTexto, tope: Int, seleccion: String = ""
  ) -> TextoAlrededorDelCursor {
    let unidades = Array(valor.utf16)
    let corte = min(max(0, cursor.ubicacion), unidades.count)
    let fin = min(max(corte, cursor.ubicacion + cursor.largo), unidades.count)
    let elegida = seleccion.isEmpty
      ? String(decoding: unidades[corte ..< fin], as: UTF16.self) : seleccion
    return TextoAlrededorDelCursor(
      antes: String(decoding: unidades[max(0, corte - tope) ..< corte], as: UTF16.self),
      despues: String(decoding: unidades[fin ..< min(unidades.count, fin + tope)], as: UTF16.self),
      seleccion: elegida
    )
  }

  /// La selección. Algunos editores no publican `AXSelectedText` pero sí el
  /// rango: entonces se reconstruye con el texto de ese rango.
  private func seleccion(_ elemento: AXUIElement, _ rango: RangoDeTexto) -> String {
    guard rango.largo > 0 else { return "" }
    if let directa = lector.atributo(elemento, kAXSelectedTextAttribute) as? String, !directa.isEmpty {
      return directa
    }
    return texto(elemento, ubicacion: rango.ubicacion, largo: rango.largo) ?? ""
  }

  private func texto(_ elemento: AXUIElement, ubicacion: Int, largo: Int) -> String? {
    guard largo > 0 else { return nil }
    var rango = CFRange(location: ubicacion, length: largo)
    guard let parametro = AXValueCreate(.cfRange, &rango) else { return nil }
    return lector.atributoConParametro(
      elemento, kAXStringForRangeParameterizedAttribute, parametro
    ) as? String
  }
}

/// La página que muestra el navegador al frente, por Accesibilidad: sin
/// AppleScript y sin pedir el permiso de Automatización.
public enum LectorDeSitio {
  /// Se completa a mano; un navegador que no está acá no se pregunta.
  public static let navegadores: Set<String> = [
    "com.apple.safari", "com.google.chrome", "company.thebrowser.browser",
    "company.thebrowser.dia", "com.brave.browser", "com.microsoft.edgemac",
    "com.operasoftware.opera", "com.vivaldi.vivaldi", "org.mozilla.firefox",
  ]

  public static func esNavegador(_ bundleID: String?) -> Bool {
    bundleID.map { navegadores.contains($0.lowercased()) } ?? false
  }

  /// Lo único que viaja: dominio y ruta, sin esquema, sin `www.`, sin
  /// consulta ni fragmento. Una consulta puede llevar un token o un correo.
  public static func dominioYRuta(_ url: String) -> String? {
    guard let partes = URLComponents(string: url), let host = partes.host?.lowercased(),
      !host.isEmpty
    else { return nil }
    let sinWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let ruta = partes.path == "/" ? "" : partes.path
    return sinWWW + ruta
  }

  /// Por mensaje. Un navegador ocupado no puede retener el hilo.
  static let espera: Float = 0.25
  /// Lo más que se recorre del árbol buscando el área web.
  static let nodosMaximos = 500
  static let honduraMaxima = 12
}

/// La lectura del sitio, con el lector inyectado para probarla sin un
/// navegador.
struct LecturaDelSitio {
  let lector: any LectorDeAccesibilidad

  /// - Parameter hasta: se rinde al llegar acá aunque quede árbol por
  ///   recorrer. El dictado no espera a un navegador lento.
  func url(dePid pid: pid_t, hasta limite: ContinuousClock.Instant) -> String? {
    guard pid > 0 else { return nil }
    let app = lector.elementoDeLaApp(pid)
    lector.fijarEspera(app, segundos: LectorDeSitio.espera)
    guard let ventana = elemento(app, kAXFocusedWindowAttribute) else { return nil }
    // Chromium publica la URL como el documento de la ventana.
    if let documento = lector.atributo(ventana, kAXDocumentAttribute) as? String,
      documento.contains("://") {
      return documento
    }
    // Subiendo desde el foco, el área web más externa: un iframe no cuenta.
    var actual = elemento(app, kAXFocusedUIElementAttribute)
    var masExterna: String?
    for _ in 0 ..< 64 {
      guard let nodo = actual, ContinuousClock.now < limite else { break }
      if lector.atributo(nodo, kAXRoleAttribute) as? String == "AXWebArea", let url = url(nodo) {
        masExterna = url
      }
      actual = elemento(nodo, kAXParentAttribute)
    }
    if let masExterna { return masExterna }

    // Con el foco en la barra de direcciones: la primera área web de la
    // ventana, a lo ancho y con tope.
    var pendientes: [(AXUIElement, Int)] = [(ventana, 0)]
    var visitados = 0
    while !pendientes.isEmpty, visitados < LectorDeSitio.nodosMaximos, ContinuousClock.now < limite {
      let (nodo, hondura) = pendientes.removeFirst()
      visitados += 1
      if lector.atributo(nodo, kAXRoleAttribute) as? String == "AXWebArea" {
        if let url = url(nodo) { return url }
        continue
      }
      guard hondura < LectorDeSitio.honduraMaxima,
        let hijos = lector.atributo(nodo, kAXChildrenAttribute) as? [AXUIElement]
      else { continue }
      pendientes += hijos.map { ($0, hondura + 1) }
    }
    return nil
  }

  private func url(_ nodo: AXUIElement) -> String? {
    let valor = lector.atributo(nodo, kAXURLAttribute)
    if let url = valor as? URL { return url.absoluteString }
    return valor as? String
  }

  private func elemento(_ duenno: AXUIElement, _ nombre: String) -> AXUIElement? {
    guard let valor = lector.atributo(duenno, nombre),
      CFGetTypeID(valor) == AXUIElementGetTypeID()
    else { return nil }
    return (valor as! AXUIElement)
  }
}

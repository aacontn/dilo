import ApplicationServices
import Foundation
import Testing
import os

@testable import DiloCapabilities

/// Un campo de texto de mentira: contesta el conteo, el texto de un rango y
/// la selección como lo haría una app de verdad, y anota cada pregunta.
final class CampoDeMentira: LectorDeAccesibilidad {
  private let estado = OSAllocatedUnfairLock(initialState: Estado())

  private struct Estado {
    var valor = ""
    var porRango = true
    var seleccionDirecta: String?
    var atributos: [String: String] = [:]
    var urls: [String: URL] = [:]
    var deElemento: Set<String> = []
    var llamadas: [String] = []
  }

  init(
    valor: String = "",
    porRango: Bool = true,
    seleccionDirecta: String? = nil,
    atributos: [String: String] = [:],
    urls: [String: URL] = [:],
    deElemento: Set<String> = []
  ) {
    estado.withLock {
      $0.valor = valor
      $0.porRango = porRango
      $0.seleccionDirecta = seleccionDirecta
      $0.atributos = atributos
      $0.urls = urls
      $0.deElemento = deElemento
    }
  }

  var llamadas: [String] { estado.withLock { $0.llamadas } }

  func elementoDelSistema() -> AXUIElement { LectorEspia.elementoPropio }
  func elementoDeLaApp(_ pid: pid_t) -> AXUIElement { LectorEspia.elementoPropio }
  func pid(de elemento: AXUIElement) -> pid_t { 1 }
  var estaAutorizado: Bool { true }
  func pedirAutorizacion() -> Bool { true }

  private func anotar(_ nombre: String) -> Estado {
    estado.withLock { e in
      e.llamadas.append(nombre)
      return e
    }
  }

  func atributo(_ elemento: AXUIElement, _ nombre: String) -> CFTypeRef? {
    let e = anotar(nombre)
    if e.deElemento.contains(nombre) { return LectorEspia.elementoPropio }
    if let url = e.urls[nombre] { return url as CFURL }
    switch nombre {
    case kAXNumberOfCharactersAttribute: return NSNumber(value: e.valor.utf16.count)
    case kAXValueAttribute: return e.valor as CFString
    case kAXSelectedTextAttribute: return e.seleccionDirecta as CFString?
    default: return e.atributos[nombre] as CFString?
    }
  }

  func atributoConParametro(
    _ elemento: AXUIElement, _ nombre: String, _ parametro: CFTypeRef
  ) -> CFTypeRef? {
    let e = anotar(nombre)
    guard e.porRango, nombre == kAXStringForRangeParameterizedAttribute else { return nil }
    var rango = CFRange()
    guard AXValueGetValue(parametro as! AXValue, .cfRange, &rango) else { return nil }
    let unidades = Array(e.valor.utf16)
    let desde = min(rango.location, unidades.count)
    let hasta = min(rango.location + rango.length, unidades.count)
    return String(decoding: unidades[desde ..< hasta], as: UTF16.self) as CFString
  }
}

struct TextoAlrededorDelCursorTests {
  private func ancla(_ ubicacion: Int, _ largo: Int = 0) -> AnclaDelFoco {
    AnclaDelFoco(
      pid: 1, elemento: LectorEspia.elementoPropio,
      seleccion: RangoDeTexto(ubicacion: ubicacion, largo: largo), marcador: nil
    )
  }

  @Test func leeAntesYDespuesDelCursorConTope() {
    let valor = "Hola Fran, el deploy de Kubernetes sale mañana. Saludos."
    let cursor = (valor as NSString).range(of: "sale").location
    let host = FullHost(lector: CampoDeMentira(valor: valor))
    let leido = host.textoAlrededor(de: ancla(cursor), tope: 12)
    #expect(leido.antes == " Kubernetes ")
    #expect(leido.despues == "sale mañana.")
    #expect(leido.seleccion.isEmpty)
  }

  @Test func laSeleccionSeReconstruyePorRangoSiNoLaPublica() {
    let valor = "revisa el PR de Decameron hoy"
    let rango = (valor as NSString).range(of: "Decameron")
    let host = FullHost(lector: CampoDeMentira(valor: valor))
    let leido = host.textoAlrededor(de: ancla(rango.location, rango.length), tope: 100)
    #expect(leido.seleccion == "Decameron")
    #expect(leido.antes == "revisa el PR de ")
    #expect(leido.despues == " hoy")
  }

  /// Sin rango, un campo chico se recorta del valor entero.
  @Test func sinRangoUnCampoChicoSeLeeEntero() {
    let host = FullHost(lector: CampoDeMentira(valor: "uno dos tres", porRango: false))
    let leido = host.textoAlrededor(de: ancla(4), tope: 3)
    #expect(leido.antes == "no ")
    #expect(leido.despues == "dos")
  }

  /// Un documento largo sin rango no se copia entero por IPC.
  @Test func sinRangoUnDocumentoLargoNoSeLee() {
    let largo = String(repeating: "palabra ", count: 1_000)
    let lector = CampoDeMentira(valor: largo, porRango: false)
    let leido = FullHost(lector: lector).textoAlrededor(de: ancla(100), tope: 50)
    #expect(leido.estaVacio)
    #expect(!lector.llamadas.contains(kAXValueAttribute))
  }

  /// En un editor web el ancla trae marcador y no rango: no hay de dónde
  /// medir, y no se pregunta nada.
  @Test func sinRangoEnElAnclaNoSePreguntaNada() {
    let lector = CampoDeMentira(valor: "algo")
    let web = AnclaDelFoco(pid: 1, elemento: LectorEspia.elementoPropio, seleccion: nil, marcador: nil)
    #expect(FullHost(lector: lector).textoAlrededor(de: web, tope: 50).estaVacio)
    #expect(lector.llamadas.isEmpty)
  }

  @Test func elRecorteCuentaEnUTF16() {
    let leido = LecturaDelContexto.recortar("añ😀 bc", cursor: RangoDeTexto(ubicacion: 4, largo: 0), tope: 10)
    #expect(leido.antes == "añ😀")
    #expect(leido.despues == " bc")
  }

  /// El contrato del sandbox, firmado por el espía: el contexto no toca
  /// Accesibilidad ni una vez.
  @Test func elSandboxNoLeeElContexto() {
    let espia = LectorEspia()
    let sandbox = SandboxedHost(lector: espia)
    #expect(sandbox.textoAlrededor(de: ancla(3), tope: 100).estaVacio)
    #expect(sandbox.sitio(dePid: 1, hasta: .now + .seconds(1)) == nil)
    #expect(!sandbox.admite(.contextoDelCampo))
    #expect(!sandbox.admite(.sitioDelNavegador))
    #expect(!sandbox.admite(.vigiaDeCorrecciones))
    #expect(espia.llamadas.isEmpty, "el sandbox llamó a Accesibilidad: \(espia.llamadas)")
  }
}

struct LectorDeSitioTests {
  @Test func soloDominioYRutaSinConsultaNiWWW() {
    #expect(LectorDeSitio.dominioYRuta("https://www.github.com/aacontn/dilo?tab=readme#x")
      == "github.com/aacontn/dilo")
    #expect(LectorDeSitio.dominioYRuta("https://mail.google.com/mail/u/0/?token=secreto")
      == "mail.google.com/mail/u/0/")
    #expect(LectorDeSitio.dominioYRuta("https://claude.ai/") == "claude.ai")
    #expect(LectorDeSitio.dominioYRuta("no es una url") == nil)
  }

  @Test func reconoceLosNavegadoresSinImportarMayusculas() {
    #expect(LectorDeSitio.esNavegador("com.google.Chrome"))
    #expect(LectorDeSitio.esNavegador("com.apple.Safari"))
    #expect(!LectorDeSitio.esNavegador("com.apple.mail"))
    #expect(!LectorDeSitio.esNavegador(nil))
  }

  /// Chromium: la URL es el documento de la ventana.
  @Test func chromeDaLaURLComoDocumentoDeLaVentana() {
    let lector = CampoDeMentira(
      atributos: [kAXDocumentAttribute: "https://www.github.com/aacontn/dilo?q=1"],
      deElemento: [kAXFocusedWindowAttribute]
    )
    #expect(FullHost(lector: lector).sitio(dePid: 42, hasta: .now + .seconds(1))
      == "github.com/aacontn/dilo")
  }

  /// Safari: el área web que contiene el foco.
  @Test func safariDaLaURLDelAreaWeb() {
    let lector = CampoDeMentira(
      atributos: [kAXRoleAttribute: "AXWebArea"],
      urls: [kAXURLAttribute: URL(string: "https://mail.google.com/mail/u/0")!],
      deElemento: [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute]
    )
    #expect(FullHost(lector: lector).sitio(dePid: 42, hasta: .now + .seconds(1))
      == "mail.google.com/mail/u/0")
  }

  /// Con el plazo vencido no se recorre el árbol: el micrófono no espera.
  @Test func conElPlazoVencidoSeRinde() {
    let lector = CampoDeMentira(
      atributos: [kAXRoleAttribute: "AXWebArea"],
      urls: [kAXURLAttribute: URL(string: "https://github.com")!],
      deElemento: [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute]
    )
    #expect(FullHost(lector: lector).sitio(dePid: 42, hasta: .now - .seconds(1)) == nil)
  }
}

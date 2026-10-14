import AppKit
import Foundation
import Observation
import Testing

@testable import Dilo

/// La capa de tokens de color: que Glaciar sea la de fábrica, que ninguna
/// traiga naranja y que cambiar de paleta avise a quien la está dibujando.
///
/// Ningún test toca `PaletaActiva.compartida`: es una por proceso y los tests
/// corren en paralelo, así que cambiarla acá teñiría el render de otro.
@Suite("Paleta de Dilo")
struct PaletaDeDiloTests {
  /// De fábrica es Glaciar y sólo quedan Glaciar y Grafito: el mango y la
  /// menta salieron como opciones el 2026-10-14.
  @Test func glaciarDeFabricaYGrafitoElegible() {
    #expect(PaletaDeDilo.Nombre.deFabrica == .glaciar)
    #expect(PaletaDeDilo.Nombre.allCases == [.glaciar, .grafito])
    #expect(PaletaActiva().paleta.nombre == .glaciar)
    #expect(PaletaDeDilo.Nombre(rawValue: "mango") == nil)
    #expect(PaletaDeDilo.Nombre(rawValue: "menta") == nil)
  }

  /// «El color naranja ya no me gusta»: ningún token cae entre el rojo y el
  /// amarillo con saturación de color.
  @Test(arguments: PaletaDeDilo.Nombre.allCases)
  func ningunaTraeNaranja(_ nombre: PaletaDeDilo.Nombre) {
    for (token, tono) in Self.tonos(de: nombre.paleta) {
      let color = tono.nsColor
      let grados = Double(color.hueComponent) * 360
      let naranja = (15...45).contains(grados) && color.saturationComponent > 0.4
      #expect(!naranja, "\(nombre.rawValue).\(token) es naranja (\(Int(grados))°)")
    }
  }

  /// El check tiene que ser otra cosa que la onda que reemplaza
  /// (`HUDCheckDeAcuse`).
  @Test(arguments: PaletaDeDilo.Nombre.allCases)
  func elAcuseNoEsDelColorDeLaOnda(_ nombre: PaletaDeDilo.Nombre) {
    let p = nombre.paleta
    #expect(p.acuse != p.ondaPunta)
    #expect(p.acuse != p.ondaBase)
  }

  @Test func cadaNombreDaSuPaleta() {
    for nombre in PaletaDeDilo.Nombre.allCases {
      #expect(nombre.paleta.nombre == nombre)
    }
  }

  /// Cambiar de paleta avisa a quien la leyó dentro de un `body`; la
  /// muestra del arnés manda sobre la elegida y soltarla la devuelve.
  @Test func cambiarDePaletaAvisa() {
    let activa = PaletaActiva()
    #expect(activa.paleta.nombre == .glaciar)
    let aviso = Avisado()
    withObservationTracking { _ = activa.paleta } onChange: { aviso.marcar() }
    activa.elegir(.grafito)
    #expect(aviso.llego)
    #expect(activa.paleta.nombre == .grafito)
    activa.mostrarDeMuestra(.glaciar)
    #expect(activa.paleta.nombre == .glaciar)
    activa.mostrarDeMuestra(nil)
    #expect(activa.paleta.nombre == .grafito)
  }

  @Test func elArnesPideUnaPaleta() throws {
    let ahora = Date()
    let pedido = try PedidoDeMuestras.leer("mostrar dictando --paleta grafito", emitido: ahora, ahora: ahora)
    #expect(pedido.paleta == .grafito)
    #expect(pedido.orden == .mostrar([.dictando], cada: .seconds(8), mantener: false, texto: nil))
    #expect(throws: PedidoDeMuestras.Rechazo.paletaDesconocida("mango")) {
      try PedidoDeMuestras.leer("mostrar dictando --paleta mango", emitido: ahora, ahora: ahora)
    }
    #expect(try PedidoDeMuestras.leer("mostrar dictando", emitido: ahora, ahora: ahora).paleta == nil)
  }

  /// De fábrica Glaciar, lo guardado se lee, y un valor que ya no existe
  /// (el mango de una copia de prueba) vuelve al de fábrica. Leerla no la
  /// aplica a la app.
  @MainActor
  @Test func elAjusteOcultoSeLee() {
    let nombre = "PaletaDeDiloTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defer { defaults.removePersistentDomain(forName: nombre) }
    #expect(AppSettings(defaults: defaults).paleta == .glaciar)
    defaults.set("grafito", forKey: "diloPaleta")
    #expect(AppSettings(defaults: defaults).paleta == .grafito)
    defaults.set("mango", forKey: "diloPaleta")
    #expect(AppSettings(defaults: defaults).paleta == .glaciar)
  }

  static func tonos(de p: PaletaDeDilo) -> [(String, Tono)] {
    [
      ("acento", p.acento), ("ondaBase", p.ondaBase), ("ondaPunta", p.ondaPunta), ("halo", p.halo),
      ("ondaCuerpo", p.ondaCuerpo), ("puntoDeReposo", p.puntoDeReposo), ("cursor", p.cursor),
      ("acuse", p.acuse), ("error", p.error), ("segmento", p.segmento), ("aviso", p.aviso),
      ("alerta", p.alerta), ("microfonoMuerto", p.microfonoMuerto), ("acentoDeAjustes", p.acentoDeAjustes),
      ("exito", p.exito), ("acentoDeLaBarra", p.acentoDeLaBarra),
      ("sesiones", p.categorias.sesiones), ("tiempo", p.categorias.tiempo),
      ("segundoIdioma", p.categorias.segundoIdioma), ("traducir", p.categorias.traducir),
      ("leerEnVoz", p.categorias.leerEnVoz),
    ]
  }
}

private final class Avisado: @unchecked Sendable {
  private let candado = NSLock()
  private var _llego = false
  var llego: Bool { candado.withLock { _llego } }
  func marcar() { candado.withLock { _llego = true } }
}

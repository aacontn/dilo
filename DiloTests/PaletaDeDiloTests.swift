import AppKit
import Foundation
import Observation
import Testing

@testable import Dilo

/// La capa de tokens de color: que la paleta de fábrica sea la de siempre,
/// que las nuevas no traigan naranja y que cambiar de paleta avise a quien la
/// está dibujando.
///
/// Ningún test toca `PaletaActiva.compartida`: es una por proceso y los tests
/// corren en paralelo, así que cambiarla acá teñiría el render de otro.
@Suite("Paleta de Dilo")
struct PaletaDeDiloTests {
  private func igual(_ tono: Tono, _ color: NSColor, alfa: Double = 1) -> Bool {
    guard let srgb = color.usingColorSpace(.sRGB) else { return false }
    let cerca = { (a: Double, b: CGFloat) in abs(a - Double(b)) < 0.002 }
    return cerca(tono.rojo, srgb.redComponent) && cerca(tono.verde, srgb.greenComponent)
      && cerca(tono.azul, srgb.blueComponent) && abs(tono.alfa - alfa) < 0.002
  }

  /// La de fábrica no cambia nada: cada token es el número que la vista
  /// tenía escrito antes de la capa.
  @Test func mangoEsLaDeSiempre() {
    let p = PaletaDeDilo.mango
    #expect(igual(p.acento, DiloBrand.mangoColor))
    #expect(igual(p.cursor, DiloBrand.mangoColor))
    #expect(igual(p.segmento, DiloBrand.mangoColor))
    #expect(igual(p.ondaBase, DiloBrand.mangoColor))
    #expect(igual(p.ondaPunta, DiloBrand.rojoColor))
    #expect(igual(p.halo, DiloBrand.rojoColor, alfa: 0.5))
    #expect(igual(p.puntoDeReposo, DiloBrand.mangoColor, alfa: 0.9))
    #expect(igual(p.acuse, DiloBrand.mentaColor))
    #expect(igual(p.ondaCuerpo, DiloBrand.mentaColor))
    #expect(igual(p.exito, DiloBrand.mentaColor))
    #expect(igual(p.acentoDeAjustes, DiloBrand.mangoColor))
    #expect(igual(p.acentoDeLaBarra, DiloBrand.mangoColor))
    #expect(p.error == Tono.blanco.opacidad(0.9))
    #expect(p.microfonoMuerto == Tono(rojo: 1, verde: 0.6, azul: 0.16))
  }

  /// «El color naranja ya no me gusta»: ningún token de las tres nuevas cae
  /// entre el rojo y el amarillo con saturación de color.
  @Test(arguments: [PaletaDeDilo.grafito, .glaciar, .menta])
  func lasNuevasNoTraenNaranja(_ paleta: PaletaDeDilo) {
    for (nombre, tono) in Self.tonos(de: paleta) {
      let color = tono.nsColor
      let tono360 = Double(color.hueComponent) * 360
      let naranja = (15...45).contains(tono360) && color.saturationComponent > 0.4
      #expect(!naranja, "\(paleta.nombre.rawValue).\(nombre) es naranja (\(Int(tono360))°)")
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
    #expect(activa.paleta.nombre == .mango)
    let aviso = Avisado()
    withObservationTracking { _ = activa.paleta } onChange: { aviso.marcar() }
    activa.elegir(.glaciar)
    #expect(aviso.llego)
    #expect(activa.paleta.nombre == .glaciar)
    activa.mostrarDeMuestra(.grafito)
    #expect(activa.paleta.nombre == .grafito)
    activa.mostrarDeMuestra(nil)
    #expect(activa.paleta.nombre == .glaciar)
  }

  @Test func elArnesPideUnaPaleta() throws {
    let ahora = Date()
    let pedido = try PedidoDeMuestras.leer("mostrar dictando --paleta menta", emitido: ahora, ahora: ahora)
    #expect(pedido.paleta == .menta)
    #expect(pedido.orden == .mostrar([.dictando], cada: .seconds(8), mantener: false, texto: nil))
    #expect(throws: PedidoDeMuestras.Rechazo.paletaDesconocida("naranja")) {
      try PedidoDeMuestras.leer("mostrar dictando --paleta naranja", emitido: ahora, ahora: ahora)
    }
    #expect(try PedidoDeMuestras.leer("mostrar dictando", emitido: ahora, ahora: ahora).paleta == nil)
  }

  /// Ajuste oculto: de fábrica mango, y lo guardado se lee. Leerla no la
  /// aplica a la app.
  @MainActor
  @Test func elAjusteOcultoSeLee() {
    let nombre = "PaletaDeDiloTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defer { defaults.removePersistentDomain(forName: nombre) }
    #expect(AppSettings(defaults: defaults).paleta == .mango)
    defaults.set("glaciar", forKey: "diloPaleta")
    #expect(AppSettings(defaults: defaults).paleta == .glaciar)
    defaults.set("naranja", forKey: "diloPaleta")
    #expect(AppSettings(defaults: defaults).paleta == .mango)
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

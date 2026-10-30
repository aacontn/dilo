import DiloReuniones
import Foundation
import Testing

@testable import Dilo

/// Lo que la interfaz de Reuniones decide sin abrir audio ni ventanas: qué
/// dice la muesca por cada aviso, las marcas desde las pistas y los chips de
/// la ventana.
@MainActor
@Suite("La interfaz de Reuniones")
struct InterfazDeReunionesTests {
  @Test func lasVigiasAvisanConSuArreglo() {
    guard case let .arreglo(permiso)? = InterfazDeReuniones.enLaMuesca(.faltaPermisoDelAudioDelSistema) else {
      Issue.record("el permiso del audio del sistema se arregla con un clic")
      return
    }
    #expect(permiso.accion == .abrirAjustes(ControlDeReuniones.panelDelAudioDelSistema))
    guard case let .arreglo(mudo)? = InterfazDeReuniones.enLaMuesca(.microfonoMudo) else {
      Issue.record("el micrófono mudo se arregla con un clic")
      return
    }
    #expect(mudo.accion == .abrirAjustes(InterfazDeReuniones.panelDelMicrofono))
    // El guion listo no interrumpe a nadie.
    #expect(InterfazDeReuniones.enLaMuesca(.guionListo(id: "r")) == nil)
    #expect(InterfazDeReuniones.enLaMuesca(.noEmpezo("No pude.")) == .frase("No pude."))
  }

  @Test func lasMarcasSalenDeLasPistas() {
    var enCurso = ControlDeReuniones.EnCurso(
      id: "r", titulo: "Reunión", inicio: Date(), carpeta: URL(filePath: "/private/tmp/r"), lugar: .raiz
    )
    enCurso.yo.nivel = -20
    enCurso.ellos.vigia = .ambar
    let enLaMuesca = ReunionEnLaMuesca(enCurso)
    #expect(enLaMuesca.microfono == .encendida)
    #expect(enLaMuesca.parlante == .ambar)
    enCurso.ellos.falla = "sin permiso"
    enCurso.ellos.vigia = .bien
    #expect(ReunionEnLaMuesca(enCurso).parlante == .sinAudio)
  }

  @Test func losChipsSonLosQueHablaron() {
    let modelo = ModeloDeLaReunion()
    var reunion = Reunion(id: "r", titulo: "Reunión", inicio: Date())
    reunion.hablantes = [.yo, Hablante(id: "h2", nombre: "Camila", pista: .ellos), Hablante(id: "h3", pista: .ellos)]
    modelo.reunion = reunion
    modelo.lineas = [
      LineaDelGuion(hablante: "h2", desde: 0, hasta: 1, texto: "Hola", solape: false, primeraPalabra: 0),
      LineaDelGuion(hablante: "yo", desde: 1, hasta: 2, texto: "Hola", solape: false, primeraPalabra: 1),
    ]
    // h3 se quedó sin líneas (se juntó con otro): no es chip.
    #expect(modelo.hablantesConLinea.map(\.id) == ["yo", "h2"])
    #expect(modelo.nombre("h2") == "Camila")
    #expect(modelo.nombre(nil) == "Sin identificar")
  }

  @Test func grabarDesdeLaTarjetaLlevaLosAsistentes() {
    let ahora = Date()
    let proxima = ProximaReunion(
      titulo: "1:1 con Camila", empieza: ahora, termina: ahora.addingTimeInterval(1800), enlace: nil,
      asistentes: ["Camila Rojas"]
    )
    let evento = InterfazDeReuniones.evento(de: proxima)
    #expect(evento.titulo == "1:1 con Camila")
    #expect(evento.asistentes == ["Camila Rojas"], "en un 1:1 el nombre se pone solo")
    #expect(evento.empieza == ahora)
  }
}

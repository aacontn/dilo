import Foundation
import Testing

@testable import DiloReuniones

@Suite("Dónde vive una reunión y qué dice su reunion.json")
struct CarpetaYDatosTests {
  private let santiago = TimeZone(identifier: "America/Santiago")!
  /// 21 oct 2026, 15:30:07 en Santiago.
  private var inicio: Date {
    var c = DateComponents()
    c.year = 2026
    c.month = 10
    c.day = 21
    c.hour = 15
    c.minute = 30
    c.second = 7
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = santiago
    return cal.date(from: c)!
  }

  @Test func elNombreVaEnASCIIMinusculasYGuiones() {
    #expect(CarpetaDeReunion.enASCII("Reunión con Camila") == "reunion-con-camila")
    #expect(CarpetaDeReunion.enASCII("  Ñandú: ¿precio — despacho?  ") == "nandu-precio-despacho")
    #expect(CarpetaDeReunion.enASCII("Q4 / UGM · Cálculo II") == "q4-ugm-calculo-ii")
    // Sin nada que quede, igual hay nombre.
    #expect(CarpetaDeReunion.enASCII("🎉🎉") == "reunion")
  }

  @Test func unTituloLargoSeCortaSinGuionColgando() {
    let nombre = CarpetaDeReunion.enASCII(String(repeating: "palabra ", count: 20))
    #expect(nombre.count <= 48)
    #expect(!nombre.hasSuffix("-"))
  }

  @Test func laCarpetaLlevaFechaHoraYTitulo() {
    let nombre = CarpetaDeReunion.nombre(inicio: inicio, titulo: "Reunión con Camila", zona: santiago)
    #expect(nombre == "2026-10-21-1530-reunion-con-camila")
    #expect(CarpetaDeReunion.año(inicio: inicio, zona: santiago) == "2026")
    #expect(CarpetaDeReunion.id(inicio: inicio, zona: santiago) == "2026-10-21T15:30:07")
  }

  @Test func dosEnElMismoMinutoNoSePisan() {
    let base = "2026-10-21-1530-reunion"
    let segunda = CarpetaDeReunion.nombre(inicio: inicio, titulo: "Reunión", existentes: [base], zona: santiago)
    #expect(segunda == base + "-2")
    let tercera = CarpetaDeReunion.nombre(
      inicio: inicio, titulo: "Reunión", existentes: [base, base + "-2"], zona: santiago
    )
    #expect(tercera == base + "-3")
  }

  @Test func elVolumenSaleDeLaRaiz() {
    #expect(CarpetaDeReunion.volumen(de: CarpetaDeReunion.raizDeFabrica)?.path == "/Volumes/SSD 1")
    #expect(CarpetaDeReunion.volumen(de: URL(filePath: "/Users/alfonso/reuniones")) == nil)
  }

  @Test func reunionJSONVaYVuelve() throws {
    var reunion = Reunion(
      id: "2026-10-21T15:30:07", titulo: "Reunión con Camila", inicio: inicio,
      evento: EventoDeLaReunion(titulo: "Reunión con Camila", asistentes: ["Camila Rojas"]),
      salida: .parlantes, proceso: ProcesoQueGraba(pid: 42, arranque: inicio)
    )
    reunion.hablantes.append(Hablante(id: "h2", nombre: "Camila", pista: .ellos))
    reunion.dictados = [TramoDeDictado(desde: 10, hasta: 14)]
    let datos = try Reunion.codificador.encode(reunion)
    let vuelta = try Reunion.decodificador.decode(Reunion.self, from: datos)
    #expect(vuelta == reunion)
    // El estado se escribe con su nombre: lo leen el CLI y el MCP.
    #expect(String(decoding: datos, as: UTF8.self).contains("\"estado\" : \"grabando\""))
  }

  @Test func unaReunionNuevaGrabaLasDosPistas() {
    let reunion = Reunion(id: "x", titulo: "x", inicio: inicio)
    #expect(reunion.pistas.map(\.pista) == [.yo, .ellos])
    #expect(reunion.archivosDeAudio == ["yo.wav", "ellos.wav"])
    #expect(reunion.hablantes == [.yo])
    #expect(Pista.yo.archivo(parte: 2) == "yo-2.wav")
  }

  @Test func losHablantesSeLlamanPorNumeroHastaTenerNombre() {
    #expect(Hablante.yo.nombreVisible == "Yo")
    #expect(Hablante(id: Hablante.id(numero: 2), pista: .ellos).nombreVisible == "Hablante 2")
    var reunion = Reunion(id: "x", titulo: "x", inicio: inicio)
    reunion.hablantes.append(Hablante(id: "h2", pista: .ellos))
    reunion.renombrar("h2", a: "  Camila ")
    #expect(reunion.hablante("h2")?.nombreVisible == "Camila")
    reunion.renombrar("h2", a: "")
    #expect(reunion.hablante("h2")?.nombreVisible == "Hablante 2")
  }

  @Test func esperandoElDiscoEsUnLugarNoUnPaso() {
    #expect(EstadoParaMostrar.de(.lista, enElRespaldo: true) == .esperandoElDisco)
    #expect(EstadoParaMostrar.de(.grabando, enElRespaldo: true) == .grabando)
    #expect(EstadoParaMostrar.de(.interrumpida, enElRespaldo: false) == .interrumpida)
  }

  @Test func laSalidaDiceSiHayQueBuscarEco() {
    #expect(SalidaDeAudio.clasificar(transporte: "bluetooth", fuente: nil, nombre: "Parlante") == .audifonos)
    #expect(SalidaDeAudio.clasificar(transporte: "integrado", fuente: "hdpn", nombre: "Salida") == .audifonos)
    #expect(SalidaDeAudio.clasificar(transporte: "integrado", fuente: "ispk", nombre: "Bocinas") == .parlantes)
    #expect(SalidaDeAudio.clasificar(transporte: "usb", fuente: nil, nombre: "Trust QHD Webcam") == .parlantes)
    #expect(SalidaDeAudio.clasificar(transporte: "usb", fuente: nil, nombre: "Jabra Headset") == .audifonos)
    #expect(!SalidaDeAudio.audifonos.pideFiltroDeEco)
    #expect(SalidaDeAudio.desconocida.pideFiltroDeEco)
  }

  @Test func lasPreferenciasCaenAlDeFabrica() throws {
    let defaults = try #require(UserDefaults(suiteName: "reuniones-prefs-\(UUID().uuidString)"))
    #expect(PreferenciasDeReuniones.leer(defaults) == PreferenciasDeReuniones())
    defaults.set("mal", forKey: PreferenciasDeReuniones.Clave.diarizador)
    #expect(PreferenciasDeReuniones.leer(defaults).diarizador == .nemotron3)
    let elegidas = PreferenciasDeReuniones(
      carpeta: URL(filePath: "/tmp/r", directoryHint: .isDirectory), diarizador: .sortformer, audio: .siempre, microfonoUID: "uid"
    )
    elegidas.guardar(en: defaults)
    #expect(PreferenciasDeReuniones.leer(defaults) == elegidas)
  }
}

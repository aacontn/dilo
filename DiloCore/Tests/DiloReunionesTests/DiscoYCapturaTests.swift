import Foundation
import Testing

@testable import DiloReuniones

@Suite("Disco, retención, reparación, búsqueda y lo que necesita la captura")
struct DiscoYCapturaTests {
  private let inicio = Date(timeIntervalSince1970: 1_792_600_200)

  private func temporal() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "dilo-reuniones-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func noSeEmpiezaConMenosDeUnGiga() {
    #expect(PoliticaDeDisco.destino(raizDisponible: true, libreEnRaiz: 5_000_000_000, libreEnRespaldo: 0) == .en(.raiz))
    #expect(
      PoliticaDeDisco.destino(raizDisponible: true, libreEnRaiz: 900_000_000, libreEnRespaldo: nil)
        == .sinEspacio(.raiz, libre: 900_000_000)
    )
    // Sin el SSD, al respaldo: grabar nunca depende del disco.
    #expect(PoliticaDeDisco.destino(raizDisponible: false, libreEnRaiz: nil, libreEnRespaldo: 20_000_000_000) == .en(.respaldo))
    // Si no se pudo leer el espacio, se intenta.
    #expect(PoliticaDeDisco.destino(raizDisponible: true, libreEnRaiz: nil, libreEnRespaldo: nil) == .en(.raiz))
    #expect(PoliticaDeDisco.hayQueAvisar(libre: 400_000_000))
    #expect(!PoliticaDeDisco.hayQueAvisar(libre: 600_000_000))
  }

  private func lista(afinadaHace dias: Double, audio: EstadoDelAudio = .wav) -> Reunion {
    var r = Reunion(id: "r", titulo: "r", inicio: inicio)
    r.estado = .lista
    r.audio = audio
    r.afinadaEl = inicio.addingTimeInterval(-dias * 86_400)
    return r
  }

  @Test func elAudioPasaAAACYALos30DiasALaPapelera() {
    #expect(RetencionDelAudio.accion(para: lista(afinadaHace: 0), politica: .treintaDias, enElRespaldo: false, ahora: inicio) == .pasarAAAC)
    #expect(RetencionDelAudio.accion(para: lista(afinadaHace: 10, audio: .aac), politica: .treintaDias, enElRespaldo: false, ahora: inicio) == .nada)
    #expect(RetencionDelAudio.accion(para: lista(afinadaHace: 31, audio: .aac), politica: .treintaDias, enElRespaldo: false, ahora: inicio) == .aLaPapelera)
    #expect(RetencionDelAudio.accion(para: lista(afinadaHace: 400, audio: .aac), politica: .siempre, enElRespaldo: false, ahora: inicio) == .nada)
    #expect(RetencionDelAudio.accion(para: lista(afinadaHace: 0), politica: .borrarAlTerminar, enElRespaldo: false, ahora: inicio) == .aLaPapelera)
  }

  @Test func loQueNoEstaListoNoSeToca() {
    var grabando = lista(afinadaHace: 90)
    grabando.estado = .afinando
    #expect(RetencionDelAudio.accion(para: grabando, politica: .borrarAlTerminar, enElRespaldo: false, ahora: inicio) == .nada)
    // En el respaldo tampoco: primero se muda al SSD.
    #expect(RetencionDelAudio.accion(para: lista(afinadaHace: 90), politica: .treintaDias, enElRespaldo: true, ahora: inicio) == .nada)
    #expect(RetencionDelAudio.nombreAAC(de: "yo-2.wav") == "yo-2.m4a")
  }

  @Test func laCabeceraWAVDiceSuTamañoYSeRepara() throws {
    let carpeta = try temporal()
    let wav = carpeta.appending(path: "ellos.wav")
    // Cabecera vieja que dice 0 bytes, 1,5 s de datos y media muestra.
    var datos = CabeceraWAV.datos(bytesDeDatos: 0)
    datos.append(CabeceraWAV.pcm16([Float](repeating: 0.25, count: 24_000)))
    datos.append(0x01)
    try datos.write(to: wav)
    let segundos = try CabeceraWAV.reparar(wav)
    #expect(segundos == 1.5)
    let reparado = try Data(contentsOf: wav)
    #expect(reparado.count == 44 + 48_000)
    #expect(CabeceraWAV.bytesDeDatos(en: reparado) == 48_000)
  }

  @Test func elPCMSeRecortaSinDarLaVuelta() {
    let datos = CabeceraWAV.pcm16([2, -2, 0])
    let valores = datos.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
    #expect(valores == [Int16.max, -Int16.max, 0])
  }

  @Test func unaReunionGrabandoSinProcesoVivoSeInterrumpio() {
    let r = Reunion(id: "r", titulo: "r", inicio: inicio, proceso: ProcesoQueGraba(pid: 9, arranque: inicio))
    #expect(ReparacionDeReuniones.estaHuerfana(r, grabandoAhora: [], estaVivo: { _ in false }))
    #expect(!ReparacionDeReuniones.estaHuerfana(r, grabandoAhora: [], estaVivo: { _ in true }))
    #expect(!ReparacionDeReuniones.estaHuerfana(r, grabandoAhora: ["r"], estaVivo: { _ in false }))
    var lista = r
    lista.estado = .lista
    #expect(!ReparacionDeReuniones.estaHuerfana(lista, grabandoAhora: [], estaVivo: { _ in false }))
  }

  @Test func repararDejaLosWAVSanosYLaReunionInterrumpida() throws {
    let raiz = try temporal()
    let carpeta = CarpetaDeReunion.url(raiz: raiz, año: "2026", nombre: "2026-10-21-1230-r")
    let r = Reunion(id: "r", titulo: "r", inicio: inicio, proceso: ProcesoQueGraba(pid: 9, arranque: inicio))
    try EscritorDeReunion.guardar(r, en: carpeta)
    var yo = CabeceraWAV.datos(bytesDeDatos: 0)
    yo.append(CabeceraWAV.pcm16([Float](repeating: 0.1, count: 16_000)))
    try yo.write(to: carpeta.appending(path: "yo.wav"))
    try CabeceraWAV.datos(bytesDeDatos: 0).write(to: carpeta.appending(path: "ellos.wav"))

    let enDisco = try #require(try LectorDeReuniones(raiz: raiz).todas().first)
    let reparada = try ReparacionDeReuniones.reparar(enDisco)
    #expect(reparada.estado == .interrumpida)
    #expect(reparada.seInterrumpio)
    #expect(reparada.fin != nil)
    #expect(CabeceraWAV.bytesDeDatos(en: try Data(contentsOf: carpeta.appending(path: "yo.wav"))) == 32_000)
    #expect(ReparacionDeReuniones.partesQueFaltan(enDisco).isEmpty)
  }

  @Test func laMudanzaSoloBorraLoComprobado() throws {
    let respaldo = try temporal()
    let raiz = try temporal()
    let nombre = "2026-10-21-1230-r"
    // En el SSD quedó la primera parte; en el interno, la segunda y el
    // reunion.json que nombra a las dos.
    let enSSD = CarpetaDeReunion.url(raiz: raiz, año: "2026", nombre: nombre)
    var vieja = Reunion(id: "r", titulo: "r", inicio: inicio)
    try EscritorDeReunion.guardar(vieja, en: enSSD)
    try Data("parte1".utf8).write(to: enSSD.appending(path: "yo.wav"))
    let enRespaldo = CarpetaDeReunion.url(raiz: respaldo, año: "2026", nombre: nombre)
    vieja.pistas[0].partes.append("yo-2.wav")
    vieja.estado = .lista
    try EscritorDeReunion.guardar(vieja, en: enRespaldo)
    try Data("parte2".utf8).write(to: enRespaldo.appending(path: "yo-2.wav"))

    let resultados = MudanzaDeReuniones.mudar(desde: respaldo, a: raiz)
    #expect(resultados.map(\.verificada) == [true])
    #expect(!FileManager.default.fileExists(atPath: enRespaldo.path(percentEncoded: false)))
    let mudada = try #require(LectorDeReuniones.reunion(en: enSSD))
    #expect(mudada.estado == .lista)
    #expect(mudada.pista(.yo)?.partes == ["yo.wav", "yo-2.wav"])
    #expect(FileManager.default.fileExists(atPath: enSSD.appending(path: "yo.wav").path(percentEncoded: false)))
  }

  @Test func laMudanzaNoTocaLoQueSeGraba() throws {
    let respaldo = try temporal()
    let raiz = try temporal()
    let carpeta = CarpetaDeReunion.url(raiz: respaldo, año: "2026", nombre: "x")
    try EscritorDeReunion.guardar(Reunion(id: "grabando", titulo: "x", inicio: inicio), en: carpeta)
    #expect(MudanzaDeReuniones.mudar(desde: respaldo, a: raiz, noTocar: ["grabando"]).isEmpty)
    #expect(FileManager.default.fileExists(atPath: carpeta.path(percentEncoded: false)))
  }

  @Test func elLectorJuntaElSSDYElRespaldoSinRepetir() throws {
    let raiz = try temporal()
    let respaldo = try temporal()
    try EscritorDeReunion.guardar(
      Reunion(id: "a", titulo: "a", inicio: inicio), en: CarpetaDeReunion.url(raiz: raiz, año: "2026", nombre: "a")
    )
    try EscritorDeReunion.guardar(
      Reunion(id: "a", titulo: "a", inicio: inicio), en: CarpetaDeReunion.url(raiz: respaldo, año: "2026", nombre: "a")
    )
    try EscritorDeReunion.guardar(
      Reunion(id: "b", titulo: "b", inicio: inicio.addingTimeInterval(60)),
      en: CarpetaDeReunion.url(raiz: respaldo, año: "2026", nombre: "b")
    )
    // Una carpeta sin reunion.json no es una reunión.
    try FileManager.default.createDirectory(
      at: CarpetaDeReunion.url(raiz: raiz, año: "2026", nombre: "basura"), withIntermediateDirectories: true
    )
    let todas = try LectorDeReuniones(raiz: raiz, respaldo: respaldo).todas()
    #expect(todas.map(\.id) == ["b", "a"])
    #expect(todas.map(\.enElRespaldo) == [true, false])
    // Una raíz que no existe no tiene reuniones.
    #expect(try LectorDeReuniones(raiz: raiz.appending(path: "no")).todas().isEmpty)
  }

  @Test func renombrarRegeneraElGuionLegible() throws {
    let raiz = try temporal()
    let carpeta = CarpetaDeReunion.url(raiz: raiz, año: "2026", nombre: "a")
    var r = Reunion(id: "a", titulo: "a", inicio: inicio)
    r.hablantes.append(Hablante(id: "h2", pista: .ellos))
    try EscritorDeReunion.guardar(r, en: carpeta)
    try EscritorDeReunion.guardarGuion(
      [PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 0, hasta: 1, texto: "Hola.")], reunion: r, en: carpeta
    )
    let enDisco = try #require(try LectorDeReuniones(raiz: raiz).todas().first)
    #expect(LectorDeReuniones.guionLegible(de: enDisco)?.contains("Hablante 2 · ") == true)
    _ = try EscritorDeReunion.renombrar("h2", a: "Camila", en: enDisco)
    #expect(LectorDeReuniones.guionLegible(de: enDisco)?.contains("Camila · ") == true)
  }

  @Test func seBuscaPorLoDichoYPorQuienLoDijo() {
    let md = """
      # Reunión con Camila

      21 oct 2026, 15:30 · 42 min · Hablan: Yo, Camila

      Yo · 15:31 — ¿Cerramos el precio hoy?

      Camila · 15:32 — Sí, pero con despacho incluido.

      Pedro · 15:33 — El despacho a regiones es aparte.
      """
    let r = Reunion(id: "2026-10-21T15:30:07", titulo: "Reunión con Camila", inicio: inicio)
    let lineas = BusquedaEnReuniones.lineas(de: md)
    #expect(lineas.count == 3)
    #expect(lineas[1] == LineaLegible(hablante: "Camila", hora: "15:32", texto: "Sí, pero con despacho incluido."))

    let deCamila = BusquedaEnReuniones.buscar("camila DESPACHO", en: [(r, md)], maximo: 10)
    #expect(deCamila.map(\.linea) == [1])
    #expect(deCamila.first?.hora == "15:32")
    // Sin tildes.
    #expect(BusquedaEnReuniones.buscar("si pero", en: [(r, md)], maximo: 10).count == 1)
    // Por hablante aparte.
    #expect(BusquedaEnReuniones.buscar("despacho", hablante: "pedro", en: [(r, md)], maximo: 10).map(\.linea) == [2])
    #expect(BusquedaEnReuniones.buscar("despacho", en: [(r, md)], maximo: 1).count == 1)
    #expect(BusquedaEnReuniones.buscar("", en: [(r, md)], maximo: 10).isEmpty)
  }

  @Test func laVigiaDistingueSilencioDePistaMuerta() {
    var mic = VigiaDeSilencio(sinBuferesSonCeros: true)
    for _ in 0..<4 { mic.segundo(muestras: 16_000, todasCero: true, pico: -160) }
    #expect(mic.estado == .bien)
    mic.segundo(muestras: 16_000, todasCero: true, pico: -160)
    #expect(mic.estado == .ambar)
    for _ in 0..<10 { mic.segundo(muestras: 0, todasCero: true, pico: -160) }
    #expect(mic.estado == .sinAudio)
    #expect(mic.pareceFaltarPermiso)
    // Una sala callada no es cero digital.
    mic.segundo(muestras: 16_000, todasCero: false, pico: -70)
    #expect(mic.estado == .bien)

    // El tap sin búferes es un Mac callado, no una falla.
    var tap = VigiaDeSilencio(sinBuferesSonCeros: false)
    for _ in 0..<30 { tap.segundo(muestras: 0, todasCero: true, pico: -160) }
    #expect(tap.estado == .bien)
    // Una pista que ya sonó y queda en ceros es una llamada en silencio, no
    // un permiso.
    tap.segundo(muestras: 100, todasCero: false, pico: -20)
    for _ in 0..<20 { tap.segundo(muestras: 16_000, todasCero: true, pico: -160) }
    #expect(tap.estado == .sinAudio)
    #expect(!tap.pareceFaltarPermiso)
  }

  @Test func elBuferAnularEntregaEnOrdenConSuTasaYBajaAMono() {
    let bufer = BuferAnular(bloques: 4, muestrasPorBloque: 3)
    // Estéreo: izquierda 1, derecha 0 → mono 0,5.
    bufer.escribir(cuadros: 5, canales: 2, tasa: 48_000, host: 10) { _, canal in canal == 0 ? 1 : 0 }
    var vistas: [(Int, Double, Double)] = []
    var muestras: [Float] = []
    let entregadas = bufer.vaciar { bloque in
      vistas.append((bloque.muestras.count, bloque.tasa, bloque.host))
      muestras += Array(bloque.muestras)
    }
    #expect(entregadas == 5)
    #expect(vistas.map(\.0) == [3, 2])
    #expect(vistas.map(\.1) == [48_000, 48_000])
    // El segundo bloque empieza tres cuadros después.
    #expect(abs(vistas[1].2 - (10 + 3.0 / 48_000)) < 1e-9)
    #expect(muestras == [Float](repeating: 0.5, count: 5))
  }

  @Test func unBuferLlenoCuentaLoQuePerdioYNoPisa() {
    let bufer = BuferAnular(bloques: 2, muestrasPorBloque: 2)
    bufer.escribir(cuadros: 6, canales: 1, tasa: 16_000, host: 0) { cuadro, _ in Float(cuadro) }
    #expect(bufer.muestrasPerdidas == 2)
    var muestras: [Float] = []
    bufer.vaciar { muestras += Array($0.muestras) }
    #expect(muestras == [0, 1, 2, 3])
    // Vaciado, vuelve a recibir.
    bufer.escribir(cuadros: 1, canales: 1, tasa: 16_000, host: 0) { _, _ in 9 }
    #expect(bufer.vaciar { _ in } == 1)
  }

  @Test func elAvanceNuncaRetrocedeEntreEtapas() {
    let fin = AvanceDeLaPasada(etapa: .transcribiendoYo, fraccionDeLaEtapa: 1).total
    let empieza = AvanceDeLaPasada(etapa: .transcribiendoEllos, fraccionDeLaEtapa: 0).total
    #expect(abs(fin - empieza) < 1e-9)
    #expect(AvanceDeLaPasada(etapa: .armandoElGuion, fraccionDeLaEtapa: 1).total == 1)
    #expect(AvanceDeLaPasada(etapa: .preparando, fraccionDeLaEtapa: 7).fraccionDeLaEtapa == 1)
  }
}

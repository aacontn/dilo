import Foundation
import Synchronization
import Testing

@testable import DiloReuniones

@Suite("La tasa de verdad de una pista")
struct TasaMedidaTests {
  /// Bloques seguidos a `real` cuadros por segundo, declarados a 48 kHz.
  private func alimentar(
    _ medida: inout TasaMedida, real: Double, segundos: Double, desde inicio: Double, cuadros: Int = 512
  ) -> [Double] {
    var host = inicio
    var tasas: [Double] = []
    while host < inicio + segundos {
      tasas.append(medida.bloque(cuadros: cuadros, host: host, declarada: 48_000))
      host += Double(cuadros) / real
    }
    return tasas
  }

  @Test func laReunionDelTreintaYUno() {
    // Lo que pasó el 2026-10-31: el tap decía 48 kHz, el agregado iba a 16 kHz
    // y a los 5.270 s subió a 44,1 kHz.
    var medida = TasaMedida(tasa: 48_000)
    let primero = alimentar(&medida, real: 16_000, segundos: 10, desde: 0)
    #expect(primero.last == 16_000)
    let despues = alimentar(&medida, real: 44_100, segundos: 10, desde: 10)
    #expect(despues.last == 44_100)
  }

  @Test func unaTasaBienDeclaradaNoSeMueve() {
    var medida = TasaMedida(tasa: 48_000)
    #expect(alimentar(&medida, real: 48_000, segundos: 30, desde: 0).allSatisfy { $0 == 48_000 })
  }

  @Test func unHuecoNoCuentaComoAudio() {
    var medida = TasaMedida(tasa: 48_000)
    var host = 0.0
    // Bloques con el tap callado entre medio: sin el reinicio, la cuenta daría
    // una tasa bajísima.
    for _ in 0 ..< 200 {
      _ = medida.bloque(cuadros: 1_024, host: host, declarada: 48_000)
      host += 1_024.0 / 48_000
      if Int(host * 10) % 7 == 0 { host += 0.5 }
    }
    #expect(medida.tasa == 48_000)
  }

  @Test func laDeclaradaNuevaMandaAlTiro() {
    var medida = TasaMedida(tasa: 48_000)
    #expect(medida.bloque(cuadros: 512, host: 0, declarada: 16_000) == 16_000)
  }

  @Test func loQueNoSeParecePasadaNadaNoSeUsa() {
    #expect(TasaMedida.conocida(cerca: 15_950) == 16_000)
    #expect(TasaMedida.conocida(cerca: 30_000) == nil)
  }
}

@Suite("Qué tramo de voz transcribir mientras graba")
struct TramosDeVozTests {
  private let trozo = 4_096

  /// Pasa trozos con estas probabilidades y junta lo que pide.
  private func correr(_ tramos: inout TramosDeVoz, _ probabilidades: [Float], desde: Int = 0) -> [TramosDeVoz.Accion] {
    var fin = desde
    var salida: [TramosDeVoz.Accion] = []
    for p in probabilidades {
      fin += trozo
      salida += tramos.trozo(fin: fin, probabilidad: p)
    }
    return salida
  }

  @Test func laVozAbreYElSilencioCierra() {
    var tramos = TramosDeVoz()
    let acciones = correr(&tramos, [0, 0, 0, 0.9, 0.9, 0.9, 0, 0, 0, 0])
    guard case let .cerrar(rango)? = acciones.last else {
      Issue.record("no cerró: \(acciones)")
      return
    }
    // Trae el principio de la palabra y no se come el final.
    #expect(rango.lowerBound == 3 * trozo - 5_600)
    #expect(rango.upperBound == 6 * trozo + 3_200)
    #expect(!tramos.hayTramoAbierto)
  }

  @Test func elTextoAvanzaMientrasSeHabla() {
    var tramos = TramosDeVoz()
    let parciales = correr(&tramos, [Float](repeating: 0.9, count: 20)).filter {
      if case .parcial = $0 { true } else { false }
    }
    #expect(parciales.count >= 2)
    #expect(tramos.hayTramoAbierto)
  }

  @Test func unGolpeNoEsVoz() {
    var ajustes = TramosDeVoz.Ajustes()
    ajustes.vozMinima = 0.5
    var tramos = TramosDeVoz(ajustes: ajustes)
    #expect(correr(&tramos, [0.9, 0, 0, 0, 0]) == [.descartar])
  }

  @Test func unMonologoSeCortaEnSuPausa() {
    var tramos = TramosDeVoz()
    // 22 s hablando, con una pausa chica casi al final de los primeros 18.
    var p = [Float](repeating: 0.9, count: 86)
    p[64] = 0.4
    let cerrados = correr(&tramos, p).compactMap { accion -> Range<Int>? in
      if case let .cerrar(rango) = accion { rango } else { nil }
    }
    #expect(cerrados.count == 1)
    #expect(cerrados.first?.upperBound == 65 * trozo)
    #expect(tramos.hayTramoAbierto)
  }

  @Test func alDictarLoAbiertoQuedaFirme() {
    var tramos = TramosDeVoz()
    _ = correr(&tramos, [0.9, 0.9, 0.9])
    guard case let .cerrar(rango)? = tramos.cerrarAhora(fin: 3 * trozo) else {
      Issue.record("no cerró")
      return
    }
    #expect(rango.upperBound == 3 * trozo)
    #expect(tramos.cerrarAhora(fin: 4 * trozo) == nil)
  }

  @Test func sinTramoSeGuardaSoloLoQueUnoNuevoPediria() {
    var tramos = TramosDeVoz()
    _ = correr(&tramos, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    let fin = 10 * trozo
    #expect(fin - tramos.retenerDesde(fin: fin) == trozo + 5_600)
    _ = correr(&tramos, [0.9], desde: fin)
    #expect(tramos.retenerDesde(fin: fin + 40 * trozo) <= fin)
  }

  @Test func elNivelSeparaVozDeSilencio() {
    #expect(TramosDeVoz.probabilidadPorNivel([Float](repeating: 0.1, count: 100)) == 1)
    #expect(TramosDeVoz.probabilidadPorNivel([Float](repeating: 0.0001, count: 100)) == 0)
  }
}

@Suite("El guion en vivo")
struct GuionEnVivoTests {
  private func linea(_ id: Int, _ pista: Pista, _ desde: Double, abierta: Bool = false, _ texto: String = "hola") -> LineaEnVivo {
    LineaEnVivo(id: id, pista: pista, desde: desde, hasta: desde + 2, texto: texto, abierta: abierta)
  }

  @Test func lasPistasSeIntercalanPorCuandoEmpezaron() {
    var guion = GuionEnVivo()
    guion.aplicar(.linea(linea(1, .ellos, 10)))
    guion.aplicar(.linea(linea(2, .yo, 4)))
    guion.aplicar(.linea(linea(3, .ellos, 6)))
    #expect(guion.lineas.map(\.id) == [2, 3, 1])
  }

  @Test func unParcialAtrasadoNoReabreUnaLineaFirme() {
    var guion = GuionEnVivo()
    guion.aplicar(.linea(linea(1, .yo, 0, abierta: true, "ho")))
    guion.aplicar(.linea(linea(1, .yo, 0, abierta: false, "hola")))
    guion.aplicar(.linea(linea(1, .yo, 0, abierta: true, "ho")))
    #expect(guion.lineas == [linea(1, .yo, 0, abierta: false, "hola")])
  }

  @Test func quitarYCerrar() {
    var guion = GuionEnVivo()
    guion.aplicar(.linea(linea(1, .yo, 0, abierta: true)))
    guion.aplicar(.linea(linea(2, .ellos, 1, abierta: true)))
    guion.aplicar(.cerrar(id: 2))
    guion.aplicar(.quitar(id: 1))
    #expect(guion.lineas.map(\.id) == [2])
    #expect(guion.lineas.first?.abierta == false)
  }

  @Test func lasNotasEntranEnSuMomentoYCortanLaCabecera() {
    let lineas = [linea(1, .yo, 0), linea(2, .yo, 3), linea(3, .ellos, 6), linea(4, .ellos, 30), linea(5, .ellos, 33)]
    let elementos = ElementoEnVivo.armar(
      lineas: lineas, notas: [NotaDeLaReunion(en: 40, texto: "fin"), NotaDeLaReunion(en: 4, texto: "ojo")]
    )
    #expect(elementos.map(\.id) == ["l1", "l2", "n4.0", "l3", "l4", "l5", "n40.0"])
    let cabeceras = elementos.compactMap { elemento -> Bool? in
      if case let .linea(_, con) = elemento { con } else { nil }
    }
    #expect(cabeceras == [true, false, true, true, false])
  }
}

@Suite("Las notas de la reunión")
struct NotasDeLaReunionTests {
  private let utc = TimeZone(identifier: "UTC")!
  private let inicio = Date(timeIntervalSince1970: 1_792_600_200)

  @Test func limpiarDejaUnaLinea() {
    #expect(NotaDeLaReunion.limpiar("  revisar\n  el   contrato ") == "revisar el contrato")
    #expect(NotaDeLaReunion.limpiar(" \n ") == nil)
  }

  @Test func elArchivoIdaYVueltaAguantaUnaLineaRota() {
    let notas = [NotaDeLaReunion(en: 12.5, texto: "uno"), NotaDeLaReunion(en: 40, texto: "dos «tres»")]
    var datos = ArchivoDeNotas.codificar(notas)
    #expect(ArchivoDeNotas.leer(datos) == notas)
    datos.append(Data("{roto\n".utf8))
    #expect(ArchivoDeNotas.leer(datos) == notas)
  }

  @Test func quedanEnElGuionAunqueSeRegenere() throws {
    let carpeta = URL(filePath: NSTemporaryDirectory()).appending(path: "notas-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: carpeta) }
    let reunion = Reunion(id: "x", titulo: "Prueba", inicio: inicio)
    try EscritorDeReunion.guardar(reunion, en: carpeta)
    try EscritorDeReunion.guardarNotas([NotaDeLaReunion(en: 60, texto: "Revisar el contrato")], en: carpeta)
    let palabras = [PalabraDelGuion(pista: .yo, hablante: "yo", desde: 1, hasta: 2, texto: "Hola")]
    try EscritorDeReunion.guardarGuion(palabras, reunion: reunion, en: carpeta, zona: utc)
    let enDisco = ReunionEnDisco(reunion: reunion, carpeta: carpeta, enElRespaldo: false)
    #expect(LectorDeReuniones.notas(de: enDisco).map(\.texto) == ["Revisar el contrato"])
    let md = try #require(LectorDeReuniones.guionLegible(de: enDisco))
    #expect(md.contains("## Notas"))
    #expect(md.contains("Nota · 16:31 — Revisar el contrato"))
    // Renombrar regenera `guion.md`: las notas no se pierden.
    _ = try EscritorDeReunion.renombrar("yo", a: nil, en: enDisco)
    #expect(LectorDeReuniones.guionLegible(de: enDisco)?.contains("Revisar el contrato") == true)
  }

  @Test func laBusquedaLasEncuentraSinCorrerLasLineas() {
    let reunion = Reunion(id: "x", titulo: "Prueba", inicio: inicio)
    let lineas = [LineaDelGuion(hablante: "yo", desde: 1, hasta: 2, texto: "Hola", solape: false, primeraPalabra: 0)]
    let md = LineasDelGuion.markdown(
      reunion: reunion, lineas: lineas, notas: [NotaDeLaReunion(en: 60, texto: "Revisar el contrato")], zona: utc
    )
    let leidas = BusquedaEnReuniones.lineas(de: md)
    #expect(leidas.map(\.hablante) == ["Yo", "Nota"])
    #expect(leidas.last?.texto == "Revisar el contrato")
  }

  @Test func copiarLasLleva() {
    let reunion = Reunion(id: "x", titulo: "Prueba", inicio: inicio)
    let notas = [NotaDeLaReunion(en: 60, texto: "Revisar el contrato")]
    #expect(GuionParaCopiar.texto(reunion: reunion, lineas: [], notas: notas, zona: utc).contains("Revisar el contrato"))
    #expect(GuionParaCopiar.paraClaude(reunion: reunion, lineas: [], notas: notas, zona: utc).contains("- 16:31 — Revisar el contrato"))
  }
}

@Suite("Cuándo rearmar el tap")
struct RearmadoDelTapTests {
  @Test func cadaVezMasEspaciado() {
    let veces = (0 ... 400).filter(VigiaDeSilencio.tocaRearmar(segundosEnCeros:))
    #expect(veces == [15, 30, 60, 120, 240])
  }
}

/// Lo que cuenta la transcripción, para mirarlo desde un test.
private final class Registro: Sendable {
  private let novedades = Mutex<[NovedadEnVivo]>([])
  private let pedidos = Mutex<[Int]>([])

  func anotar(_ novedad: NovedadEnVivo) { novedades.withLock { $0.append(novedad) } }
  func anotar(pedido muestras: Int) { pedidos.withLock { $0.append(muestras) } }
  var cuentas: [NovedadEnVivo] { novedades.withLock { $0 } }
  var transcripciones: Int { pedidos.withLock { $0.count } }
  var guion: GuionEnVivo {
    var guion = GuionEnVivo()
    for novedad in cuentas { guion.aplicar(novedad) }
    return guion
  }

  func esperar(_ condicion: (Registro) -> Bool) async {
    for _ in 0 ..< 500 {
      if condicion(self) { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

@Suite("La transcripción en vivo")
struct TranscripcionEnVivoTests {
  /// Voz = muestras en 0,5; silencio = ceros: el detector de mentira mira eso.
  private func armar(
    _ registro: Registro,
    transcribir: TranscripcionEnVivo.Transcribir? = nil,
    detectar: TranscripcionEnVivo.Detectar? = nil
  ) -> TranscripcionEnVivo {
    TranscripcionEnVivo(
      inicioHost: 100,
      transcribir: transcribir ?? { audio in
        registro.anotar(pedido: audio.count)
        return "texto de \(audio.count)"
      },
      detectar: detectar ?? { _, trozo in trozo[0] > 0 ? 0.9 : 0.1 },
      alCambiar: { registro.anotar($0) }
    )
  }

  private func entrega(_ pista: Pista, voz: Double = 0, silencio: Double = 0, desde: Int64 = 0, host: Double = 100) -> TranscripcionEnVivo.Entrega {
    let muestras = [Float](repeating: 0.5, count: Int(voz * 16_000)) + [Float](repeating: 0, count: Int(silencio * 16_000))
    return TranscripcionEnVivo.Entrega(pista: pista, muestras: muestras, muestraInicial: desde, host: host)
  }

  private func escuchando(_ vivo: TranscripcionEnVivo) -> Task<Void, Never> {
    Task { await vivo.escuchar() }
  }

  @Test func loDichoApareceYQuedaFirme() async {
    let registro = Registro()
    let vivo = armar(registro)
    let tarea = escuchando(vivo)
    vivo.recibir(entrega(.yo, voz: 3, silencio: 2))
    await registro.esperar { $0.guion.lineas.first?.abierta == false }
    let linea = registro.guion.lineas.first
    #expect(linea?.pista == .yo)
    #expect(linea?.abierta == false)
    #expect(linea?.texto.hasPrefix("texto de") == true)
    #expect((linea?.desde ?? -1) < 0.1)
    await vivo.terminar()
    await tarea.value
  }

  @Test func laPistaQueEmpiezaTardeSeUbicaEnLaReunion() async {
    let registro = Registro()
    let vivo = armar(registro)
    let tarea = escuchando(vivo)
    // El tap no corre hasta que algo suena: su primera muestra llega 60 s
    // después de apretar «Grabar».
    vivo.recibir(entrega(.ellos, voz: 2, silencio: 2, host: 160))
    await registro.esperar { !$0.guion.lineas.isEmpty && $0.guion.lineas[0].abierta == false }
    #expect((registro.guion.lineas.first?.desde ?? 0) > 59)
    await vivo.terminar()
    await tarea.value
  }

  @Test func unDictadoParaElModeloYLoDeYoNoEntra() async {
    let registro = Registro()
    let vivo = armar(registro)
    let tarea = escuchando(vivo)
    await vivo.dictado(enCurso: true)
    vivo.recibir(entrega(.yo, voz: 3, silencio: 2))
    vivo.recibir(entrega(.ellos, voz: 3, silencio: 2))
    try? await Task.sleep(for: .milliseconds(150))
    #expect(registro.transcripciones == 0)
    await vivo.dictado(enCurso: false)
    await registro.esperar { !$0.guion.lineas.isEmpty }
    #expect(registro.guion.lineas.map(\.pista) == [.ellos])
    await vivo.terminar()
    await tarea.value
  }

  @Test func sinModeloLoDiceUnaVezYDejaDePedir() async {
    let registro = Registro()
    let vivo = armar(registro, transcribir: { _ in
      registro.anotar(pedido: 0)
      throw FallaDelVivo.sinMotor
    })
    let tarea = escuchando(vivo)
    vivo.recibir(entrega(.yo, voz: 3, silencio: 2))
    await registro.esperar { $0.guion.sinMotor }
    vivo.recibir(entrega(.yo, voz: 3, silencio: 2, desde: 80_000))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(registro.guion.sinMotor)
    #expect(registro.transcripciones == 1)
    await vivo.terminar()
    await tarea.value
  }

  @Test func sinDetectorSigueConElNivel() async {
    struct Falla: Error {}
    let registro = Registro()
    let vivo = armar(registro, detectar: { _, _ in throw Falla() })
    let tarea = escuchando(vivo)
    vivo.recibir(entrega(.yo, voz: 3, silencio: 2))
    await registro.esperar { $0.guion.lineas.first?.abierta == false }
    #expect(registro.guion.lineas.count == 1)
    await vivo.terminar()
    await tarea.value
  }

  @Test func unHuecoLargoDelTapNoTraba() async {
    let registro = Registro()
    let vivo = armar(registro)
    let tarea = escuchando(vivo)
    vivo.recibir(entrega(.ellos, silencio: 600))
    vivo.recibir(entrega(.ellos, voz: 2, silencio: 2, desde: 9_600_000, host: 700))
    await registro.esperar { $0.guion.lineas.first?.abierta == false }
    #expect((registro.guion.lineas.first?.desde ?? 0) > 599)
    await vivo.terminar()
    await tarea.value
  }

  @Test func unaEntregaPerdidaCierraLoAbierto() async {
    let registro = Registro()
    let vivo = armar(registro)
    let tarea = escuchando(vivo)
    vivo.recibir(entrega(.yo, voz: 3))
    vivo.recibir(entrega(.yo, voz: 3, silencio: 2, desde: 160_000, host: 110))
    await registro.esperar { $0.guion.lineas.filter { !$0.abierta }.count == 2 }
    #expect(registro.guion.lineas.count == 2)
    await vivo.terminar()
    await tarea.value
  }

  @Test func alTerminarNadaQuedaAbierto() async {
    let registro = Registro()
    let vivo = armar(registro)
    let tarea = escuchando(vivo)
    vivo.recibir(entrega(.ellos, voz: 4))
    await registro.esperar { !$0.guion.lineas.isEmpty }
    await vivo.terminar()
    await tarea.value
    #expect(registro.guion.lineas.allSatisfy { !$0.abierta })
  }
}

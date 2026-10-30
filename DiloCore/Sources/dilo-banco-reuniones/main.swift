import DiloEngines
import DiloHablantes
import DiloReuniones
import FluidAudio
import Foundation

// El banco de la Fase 0 (spec, «Verificación», puntos 2–5): corre los
// diarizadores sobre reuniones de verdad y dice, por cada uno, cuántas
// palabras quedan con el hablante correcto, cuántas veces junta a dos
// personas y cuántas parte a una, cuánto tarda por hora de audio, cuánta RAM
// pide y qué similitud da la huella de la misma persona en dos archivos.
//
// Es taller, como `dilo-metrics`: la app no lo enlaza. Lo corre
// `scripts/banco-reuniones.sh`, un proceso por diarizador para que el pico
// de RAM sea el de ese modelo y no el de todos juntos. Mide con el mismo
// código que usa la app: Parakeet por `ParakeetEngine`, la separación por
// `SeparacionDeVoces` y palabra → hablante por `ArmadoDelGuion.atribuir`.

let uso = """
  uso: dilo-banco-reuniones <comando> <carpeta> [opciones]

    generar <carpeta>       arma dos reuniones de prueba con voces de `say`
    transcribir <carpeta>   Parakeet sobre cada caso; deja las palabras
    medir <carpeta> --diarizador <nombre>
                            separa voces y compara con las etiquetas
    huellas <carpeta>       similitud de CAM++ entre las voces etiquetadas
    resumen <carpeta>       la tabla de todo lo medido, en Markdown

  opciones: --salida <dir> (por defecto <carpeta>/banco-resultados)
            --modelos <dir> (por defecto /Volumes/SSD2/dilo-modelos)

  diarizadores: \(Diarizador.allCases.map(\.rawValue).joined(separator: ", "))

  En la carpeta: <nombre>.ellos.wav (y <nombre>.yo.wav si está) por pista, o
  <nombre>.wav mezclado; etiquetas a mano en <nombre>.etiquetas.tsv, una
  línea por intervención: desde<TAB>hasta<TAB>hablante (segundos o m:ss).
  El hablante «Yo» es la pista del micrófono.

  """

func error(_ texto: String) -> Never {
  FileHandle.standardError.write(Data((texto + "\n").utf8))
  exit(2)
}

func valor(_ bandera: String, _ argumentos: [String]) -> String? {
  guard let i = argumentos.firstIndex(of: bandera), i + 1 < argumentos.count else { return nil }
  return argumentos[i + 1]
}

/// El pico de memoria física del proceso, en MB: lo que el Monitor de
/// Actividad llama «Memoria».
func picoDeRAM() -> Double {
  var info = task_vm_info_data_t()
  var cuenta = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let resultado = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(cuenta)) {
      task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &cuenta)
    }
  }
  guard resultado == KERN_SUCCESS else { return 0 }
  return Double(info.ledger_phys_footprint_peak) / 1_048_576
}

/// Una intervención etiquetada a mano.
struct Etiqueta: Codable {
  var desde: Double
  var hasta: Double
  var hablante: String

  var esYo: Bool { TextoPlegado.plegar(hablante) == "yo" }

  /// `12.5`, `1:02.5` o `1:02:03`.
  static func segundos(_ texto: String) -> Double? {
    let partes = texto.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
    guard !partes.isEmpty, partes.count <= 3 else { return nil }
    var total = 0.0
    for parte in partes {
      guard let n = Double(parte.replacingOccurrences(of: ",", with: ".")) else { return nil }
      total = total * 60 + n
    }
    return total
  }

  static func leer(_ url: URL) -> [Etiqueta] {
    guard let texto = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return texto.split(whereSeparator: \.isNewline).compactMap { renglon in
      let renglon = renglon.trimmingCharacters(in: .whitespaces)
      guard !renglon.isEmpty, !renglon.hasPrefix("#") else { return nil }
      let campos = renglon.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard campos.count >= 3, let desde = segundos(campos[0]), let hasta = segundos(campos[1]), hasta > desde else {
        return nil
      }
      return Etiqueta(desde: desde, hasta: hasta, hablante: campos[2].trimmingCharacters(in: .whitespaces))
    }
  }
}

/// Un audio a medir con sus etiquetas.
struct Caso {
  enum Variante: String, Codable {
    /// Sólo la pista `ellos`: lo que diariza la app.
    case porPista = "por-pista"
    /// `yo` y `ellos` sumadas: para confirmar con números que por pista gana.
    case mezclado
  }

  var nombre: String
  var base: String
  var variante: Variante
  var audio: URL
  var etiquetas: [Etiqueta]

  var clave: String { "\(nombre).\(variante.rawValue)" }
}

func casos(en carpeta: URL, salida: URL) throws -> [Caso] {
  let fm = FileManager.default
  let archivos = try fm.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "wav" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  var salidaCasos: [Caso] = []
  for archivo in archivos {
    let nombre = archivo.deletingPathExtension().lastPathComponent
    if nombre.hasSuffix(".yo") { continue }
    let etiquetas = { (base: String) in Etiqueta.leer(carpeta.appending(path: "\(base).etiquetas.tsv")) }
    if nombre.hasSuffix(".ellos") {
      let base = String(nombre.dropLast(".ellos".count))
      let todas = etiquetas(base)
      salidaCasos.append(
        Caso(nombre: base, base: base, variante: .porPista, audio: archivo, etiquetas: todas.filter { !$0.esYo })
      )
      let yo = carpeta.appending(path: "\(base).yo.wav")
      if fm.fileExists(atPath: yo.path(percentEncoded: false)) {
        let mezcla = salida.appending(path: "mezclas/\(base).mezcla.wav")
        if !fm.fileExists(atPath: mezcla.path(percentEncoded: false)) {
          try mezclar(yo: yo, ellos: archivo, en: mezcla)
        }
        salidaCasos.append(Caso(nombre: base, base: base, variante: .mezclado, audio: mezcla, etiquetas: todas))
      }
    } else {
      salidaCasos.append(Caso(nombre: nombre, base: nombre, variante: .mezclado, audio: archivo, etiquetas: etiquetas(nombre)))
    }
  }
  return salidaCasos
}

func audio16k(_ url: URL) throws -> [Float] {
  try AudioConverter().resampleAudioFile(url)
}

func escribirWAV(_ muestras: [Float], en url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  var datos = CabeceraWAV.datos(bytesDeDatos: muestras.count * CabeceraWAV.bytesPorMuestra)
  datos.append(CabeceraWAV.pcm16(muestras))
  try datos.write(to: url)
}

/// `yo` + `ellos` en una sola pista, como se habría grabado con un solo
/// dispositivo: el caso que el Tauri usó y que borró la diferencia.
func mezclar(yo: URL, ellos: URL, en destino: URL) throws {
  let a = try audio16k(yo)
  let b = try audio16k(ellos)
  var mezcla = [Float](repeating: 0, count: max(a.count, b.count))
  for i in mezcla.indices {
    mezcla[i] = max(-1, min(1, (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)))
  }
  try escribirWAV(mezcla, en: destino)
}

/// Una captura que no captura: el banco sólo transcribe archivos.
struct SinCaptura: AudioCapture {
  func iniciar(
    sampleRate: Double, muestras: @escaping @Sendable ([Float]) -> Void,
    nivel: @escaping @Sendable (Float) -> Void, falla: @escaping @Sendable (String) -> Void
  ) throws {}
  func detener() {}
}

struct PalabrasDelCaso: Codable {
  var caso: String
  var segundosDeAudio: Double
  var segundosDeParakeet: Double
  var palabras: [Palabra]

  struct Palabra: Codable {
    var texto: String
    var desde: Double
    var hasta: Double
  }
}

func transcribir(_ carpeta: URL, salida: URL) async throws {
  // Transcribe con la variante que dictaría la app (Ultra o v3, la que esté).
  guard !ParakeetModelStore.enDisco().isEmpty else {
    error("No hay un modelo de Parakeet en \(ParakeetModelStore.carpeta.path). Bájalo desde Dilo → Ajustes → Motor de voz.")
  }
  let motor = ParakeetEngine(captura: SinCaptura(), reposo: nil)
  let codificador = JSONEncoder()
  codificador.outputFormatting = [.prettyPrinted]
  for caso in try casos(en: carpeta, salida: salida) {
    let destino = salida.appending(path: "palabras/\(caso.clave).json")
    if FileManager.default.fileExists(atPath: destino.path(percentEncoded: false)) { continue }
    let segundosDeAudio = Double(try audio16k(caso.audio).count) / 16_000
    let reloj = ContinuousClock.now
    let palabras = try await motor.transcribirArchivoConTiempos(caso.audio)
    let tardo = ContinuousClock.now - reloj
    let resultado = PalabrasDelCaso(
      caso: caso.clave, segundosDeAudio: segundosDeAudio,
      segundosDeParakeet: Double(tardo.components.seconds) + Double(tardo.components.attoseconds) / 1e18,
      palabras: palabras.map { .init(texto: $0.texto, desde: $0.inicio, hasta: $0.fin) }
    )
    try FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
    try codificador.encode(resultado).write(to: destino)
    print("transcrito \(caso.clave): \(palabras.count) palabras en \(String(format: "%.1f", resultado.segundosDeParakeet)) s")
  }
  await motor.descargarDeMemoria()
}

/// Lo que se mide de un caso con un diarizador.
struct Medida: Codable {
  var caso: String
  var variante: Caso.Variante
  var horasDeAudio: Double
  var segundosDeCarga: Double
  var segundosDeSeparacion: Double
  var segundosPorHora: Double
  var hablantesDetectados: Int
  var hablantesEtiquetados: Int
  var palabras: Int
  var palabrasEtiquetadas: Int
  var palabrasBien: Int
  var porcentajeBien: Double?
  /// Personas distintas que el modelo dejó en una sola voz.
  var uniones: Int
  /// Voces de más en que el modelo partió a una persona.
  var particiones: Int
  var palabrasEnSolape: Int
  var solapesRecuperados: Int
  var falla: String?
}

struct Medicion: Codable {
  var diarizador: String
  var picoDeRAMEnMB: Double
  var medidas: [Medida]
}

/// El hablante etiquetado en un instante, o nil si nadie (o más de uno).
func etiquetaEn(_ instante: Double, _ etiquetas: [Etiqueta]) -> (hablante: String?, solape: Bool) {
  let activas = etiquetas.filter { $0.desde <= instante && instante < $0.hasta }
  return (activas.count == 1 ? activas[0].hablante : activas.first?.hablante, activas.count > 1)
}

/// Compara la voz del modelo con la etiqueta de cada palabra. Las voces del
/// modelo se emparejan con las personas una a una, por la mayor cantidad de
/// palabras en común (codicioso: con ocho voces y ocho personas no cambia).
func comparar(
  _ palabras: [PalabraDeLaPista], hipotesis: [ArmadoDelGuion.Atribucion], etiquetas: [Etiqueta]
) -> (bien: Int, etiquetadas: Int, uniones: Int, particiones: Int, enSolape: Int, recuperados: Int) {
  var tabla: [String: [Int: Int]] = [:]
  var etiquetadas = 0
  var enSolape = 0
  var recuperados = 0
  for (palabra, hipotesis) in zip(palabras, hipotesis) {
    let (persona, solape) = etiquetaEn((palabra.desde + palabra.hasta) / 2, etiquetas)
    if solape {
      enSolape += 1
      if hipotesis.solape { recuperados += 1 }
    }
    guard let persona, let voz = hipotesis.indice else {
      if persona != nil { etiquetadas += 1 }
      continue
    }
    etiquetadas += 1
    tabla[persona, default: [:]][voz, default: 0] += 1
  }
  var celdas = tabla.flatMap { persona, voces in voces.map { (persona: persona, voz: $0.key, n: $0.value) } }
    .sorted { $0.n > $1.n }
  var personasUsadas = Set<String>()
  var vocesUsadas = Set<Int>()
  var bien = 0
  while let celda = celdas.first {
    celdas.removeFirst()
    guard !personasUsadas.contains(celda.persona), !vocesUsadas.contains(celda.voz) else { continue }
    personasUsadas.insert(celda.persona)
    vocesUsadas.insert(celda.voz)
    bien += celda.n
  }
  // Unión: dos personas cuya voz mayoritaria es la misma.
  let mayoritaria = tabla.compactMapValues { voces in voces.max { $0.value < $1.value }?.key }
  let porVoz = Dictionary(grouping: mayoritaria.values, by: { $0 })
  let uniones = porVoz.values.reduce(0) { $0 + max(0, $1.count - 1) }
  // Partición: una persona repartida en voces que tienen al menos el 15 %
  // de sus palabras cada una.
  let particiones = tabla.values.reduce(0) { total, voces in
    let suma = voces.values.reduce(0, +)
    let grandes = voces.values.filter { Double($0) >= 0.15 * Double(suma) }.count
    return total + max(0, grandes - 1)
  }
  return (bien, etiquetadas, uniones, particiones, enSolape, recuperados)
}

func medir(_ carpeta: URL, salida: URL, diarizador: Diarizador, modelos: URL) async throws {
  let separacion = SeparacionDeVoces(carpetaDeModelos: modelos)
  var medidas: [Medida] = []
  let decodificador = JSONDecoder()
  let inicioDeCarga = ContinuousClock.now
  var fallaDeCarga: String?
  do { try await separacion.preparar(diarizador) } catch { fallaDeCarga = error.localizedDescription }
  let carga = segundos(ContinuousClock.now - inicioDeCarga)

  for caso in try casos(en: carpeta, salida: salida) {
    let archivoDePalabras = salida.appending(path: "palabras/\(caso.clave).json")
    guard let datos = try? Data(contentsOf: archivoDePalabras),
      let transcrito = try? decodificador.decode(PalabrasDelCaso.self, from: datos)
    else {
      error("Faltan las palabras de \(caso.clave). Corre primero: dilo-banco-reuniones transcribir \(carpeta.path)")
    }
    let palabras = transcrito.palabras.map { PalabraDeLaPista(texto: $0.texto, desde: $0.desde, hasta: $0.hasta) }
    var medida = Medida(
      caso: caso.nombre, variante: caso.variante, horasDeAudio: transcrito.segundosDeAudio / 3600,
      segundosDeCarga: carga, segundosDeSeparacion: 0, segundosPorHora: 0, hablantesDetectados: 0,
      hablantesEtiquetados: Set(caso.etiquetas.map(\.hablante)).count, palabras: palabras.count,
      palabrasEtiquetadas: 0, palabrasBien: 0, porcentajeBien: nil, uniones: 0, particiones: 0,
      palabrasEnSolape: 0, solapesRecuperados: 0, falla: fallaDeCarga
    )
    if fallaDeCarga == nil {
      do {
        // El caso pasa a un WAV de 16 kHz propio: es lo que lee la app.
        let propio = salida.appending(path: "audio16k/\(caso.clave).wav")
        if !FileManager.default.fileExists(atPath: propio.path(percentEncoded: false)) {
          try escribirWAV(try audio16k(caso.audio), en: propio)
        }
        let reloj = ContinuousClock.now
        let actividad = try await separacion.separar(diarizador, audio: LectorDeAudio(partes: [propio]))
        medida.segundosDeSeparacion = segundos(ContinuousClock.now - reloj)
        medida.segundosPorHora = medida.segundosDeSeparacion / max(medida.horasDeAudio, 1e-9)
        let hipotesis = ArmadoDelGuion.atribuir(palabras, actividad: actividad)
        medida.hablantesDetectados = Set(hipotesis.compactMap(\.indice)).count
        let c = comparar(palabras, hipotesis: hipotesis, etiquetas: caso.etiquetas)
        medida.palabrasBien = c.bien
        medida.palabrasEtiquetadas = c.etiquetadas
        medida.porcentajeBien = c.etiquetadas > 0 ? 100 * Double(c.bien) / Double(c.etiquetadas) : nil
        medida.uniones = c.uniones
        medida.particiones = c.particiones
        medida.palabrasEnSolape = c.enSolape
        medida.solapesRecuperados = c.recuperados
        let segmentos = actividad.segmentos().map { "\($0.desde)\t\($0.hasta)\tvoz \($0.hablante)" }
        let destino = salida.appending(path: "segmentos/\(diarizador.rawValue)/\(caso.clave).tsv")
        try FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((segmentos.joined(separator: "\n") + "\n").utf8).write(to: destino)
      } catch {
        medida.falla = error.localizedDescription
      }
    }
    medidas.append(medida)
    let porcentaje = medida.porcentajeBien.map { String(format: "%.1f %%", $0) } ?? "sin etiquetas"
    print("\(diarizador.rawValue) \(caso.clave): \(porcentaje), \(medida.hablantesDetectados) voces, \(String(format: "%.0f", medida.segundosPorHora)) s/h\(medida.falla.map { " — falla: \($0)" } ?? "")")
  }
  await separacion.soltar()
  let medicion = Medicion(diarizador: diarizador.rawValue, picoDeRAMEnMB: picoDeRAM(), medidas: medidas)
  let codificador = JSONEncoder()
  codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
  let destino = salida.appending(path: "medicion-\(diarizador.rawValue).json")
  try codificador.encode(medicion).write(to: destino)
  print("RAM pico: \(String(format: "%.0f", medicion.picoDeRAMEnMB)) MB → \(destino.path)")
}

func segundos(_ d: Duration) -> Double {
  Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

struct ParDeHuellas: Codable {
  var a: String
  var b: String
  var mismaPersona: Bool
  var similitud: Float
}

/// La huella de cada persona etiquetada en cada archivo, y la similitud de
/// cada par entre archivos distintos (spec, «Verificación», punto 4).
func huellas(_ carpeta: URL, salida: URL, modelos: URL) async throws {
  let huellas = HuellasDeVoz(carpetaDeModelos: modelos)
  var porPersona: [(archivo: String, persona: String, huella: [Float])] = []
  for caso in try casos(en: carpeta, salida: salida) {
    // Por pista: las voces de `ellos` de su pista y Yo de la suya. Mezclado:
    // sólo cuando no hay pistas (un `<nombre>.wav` suelto); la mezcla armada
    // desde dos pistas repetiría a las mismas personas.
    let yo = carpeta.appending(path: "\(caso.base).yo.wav")
    var fuentes: [(URL, [Etiqueta])] = []
    switch caso.variante {
    case .porPista:
      fuentes.append((caso.audio, caso.etiquetas))
      if FileManager.default.fileExists(atPath: yo.path(percentEncoded: false)) {
        fuentes.append((yo, Etiqueta.leer(carpeta.appending(path: "\(caso.base).etiquetas.tsv")).filter(\.esYo)))
      }
    case .mezclado:
      guard caso.audio.deletingLastPathComponent().standardizedFileURL == carpeta.standardizedFileURL else { continue }
      fuentes.append((caso.audio, caso.etiquetas))
    }
    for (url, etiquetas) in fuentes where !etiquetas.isEmpty {
      let audio = try audio16k(url)
      for persona in Set(etiquetas.map(\.hablante)).sorted() {
        // Sólo lo que dijo sin nadie encima, y a lo más un minuto.
        var muestras: [Float] = []
        for e in etiquetas where e.hablante == persona {
          let pisada = etiquetas.contains { $0.hablante != persona && $0.desde < e.hasta && e.desde < $0.hasta }
          guard !pisada else { continue }
          let a = max(0, Int(e.desde * 16_000))
          let b = min(audio.count, Int(e.hasta * 16_000))
          if a < b { muestras += audio[a..<b] }
          if muestras.count >= 60 * 16_000 { break }
        }
        if let huella = try await huellas.huella(de: muestras) {
          porPersona.append((caso.base, persona, huella))
        }
      }
    }
  }
  var pares: [ParDeHuellas] = []
  for i in porPersona.indices {
    for j in porPersona.indices where j > i && porPersona[i].archivo != porPersona[j].archivo {
      let a = porPersona[i]
      let b = porPersona[j]
      pares.append(
        ParDeHuellas(
          a: "\(a.archivo)/\(a.persona)", b: "\(b.archivo)/\(b.persona)",
          mismaPersona: TextoPlegado.plegar(a.persona) == TextoPlegado.plegar(b.persona),
          similitud: HuellasDeVoz.similitud(a.huella, b.huella)
        )
      )
    }
  }
  let codificador = JSONEncoder()
  codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
  try codificador.encode(pares).write(to: salida.appending(path: "huellas.json"))
  for par in pares.sorted(by: { $0.similitud > $1.similitud }) {
    print(String(format: "%.3f  %@  %@ ↔ %@", par.similitud, par.mismaPersona ? "misma" : "otra ", par.a, par.b))
  }
  await huellas.soltar()
}

func resumen(_ salida: URL) throws {
  let decodificador = JSONDecoder()
  let archivos = try FileManager.default.contentsOfDirectory(at: salida, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasPrefix("medicion-") && $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  var renglones = [
    "# Banco de reuniones · \(ISO8601DateFormatter().string(from: Date()))", "",
    "| Diarizador | Caso | Variante | Bien | Uniones | Particiones | Solapes | Voces (etiq.) | s por hora | Carga s | RAM pico MB |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  ]
  for archivo in archivos {
    let medicion = try decodificador.decode(Medicion.self, from: Data(contentsOf: archivo))
    for m in medicion.medidas {
      let bien = m.falla.map { "falla: \($0)" } ?? m.porcentajeBien.map { String(format: "%.1f %%", $0) } ?? "—"
      let solapes = m.palabrasEnSolape > 0 ? "\(m.solapesRecuperados)/\(m.palabrasEnSolape)" : "—"
      renglones.append(
        "| \(medicion.diarizador) | \(m.caso) | \(m.variante.rawValue) | \(bien) | \(m.uniones) | \(m.particiones) | \(solapes) | \(m.hablantesDetectados) (\(m.hablantesEtiquetados)) | \(String(format: "%.0f", m.segundosPorHora)) | \(String(format: "%.1f", m.segundosDeCarga)) | \(String(format: "%.0f", medicion.picoDeRAMEnMB)) |"
      )
    }
  }
  if let datos = try? Data(contentsOf: salida.appending(path: "huellas.json")),
    let pares = try? decodificador.decode([ParDeHuellas].self, from: datos), !pares.isEmpty
  {
    let mismas = pares.filter(\.mismaPersona).map(\.similitud)
    let otras = pares.filter { !$0.mismaPersona }.map(\.similitud)
    renglones += ["", "## Huellas de voz (CAM++)", ""]
    if let minimo = mismas.min() {
      renglones.append(String(format: "- Misma persona, %d pares: mínimo %.3f, media %.3f", mismas.count, minimo, mismas.reduce(0, +) / Float(mismas.count)))
    }
    if let maximo = otras.max() {
      renglones.append(String(format: "- Personas distintas, %d pares: máximo %.3f, media %.3f", otras.count, maximo, otras.reduce(0, +) / Float(otras.count)))
    }
    if let minimo = mismas.min(), let maximo = otras.max() {
      renglones.append(
        minimo > maximo
          ? String(format: "- Se separan: un umbral entre %.3f y %.3f (punto medio %.3f).", maximo, minimo, (minimo + maximo) / 2)
          : "- No se separan: hay dos personas distintas más parecidas que la misma persona consigo."
      )
    }
  }
  let texto = renglones.joined(separator: "\n") + "\n"
  try Data(texto.utf8).write(to: salida.appending(path: "resumen.md"))
  print(texto)
}

/// Dos reuniones de prueba con las voces del sistema, para probar el banco
/// sin grabar a nadie: la misma gente en las dos (para las huellas), un solape
/// y Yo en su propia pista. Todo a archivo; nada suena.
func generar(_ carpeta: URL) throws {
  let voces = [
    "Yo": "Eddy (Español (España))", "Camila": "Mónica", "Pedro": "Reed (Español (México))",
    "Paula": "Paulina",
  ]
  let guiones: [(String, [(String, String)])] = [
    ("prueba-a", [
      ("Yo", "Partamos por el precio, que es lo que nos tiene atrasados."),
      ("Camila", "Ya, te cuento lo que conversamos con Pedro el martes en la oficina."),
      ("Pedro", "Ojo que el despacho a regiones va aparte y se cobra por bulto."),
      ("Camila", "Entonces cerramos el precio sin regiones y lo vemos la próxima semana."),
      ("Paula", "Perdón, me uno tarde. ¿Ya hablaron del despacho?"),
      ("Yo", "Sí, quedó fuera. Lo dejamos para el jueves."),
      ("Pedro", "Perfecto, yo mando la cotización corregida mañana temprano."),
    ]),
    ("prueba-b", [
      ("Paula", "Hola, ¿me escuchan bien? Tengo el informe de ventas del mes."),
      ("Yo", "Te escuchamos. Cuéntanos cómo nos fue en octubre."),
      ("Pedro", "Antes de eso, quiero revisar el atraso de los pedidos de Valparaíso."),
      ("Camila", "Los pedidos salieron ayer, el atraso fue de la transportista."),
      ("Paula", "Bien. En ventas subimos un doce por ciento contra septiembre."),
      ("Camila", "Buenísimo. Entonces mantenemos la campaña hasta fin de año."),
    ]),
  ]
  let fm = FileManager.default
  try fm.createDirectory(at: carpeta, withIntermediateDirectories: true)
  let tmp = fm.temporaryDirectory.appending(path: "dilo-banco-\(UUID().uuidString)")
  try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: tmp) }
  for (nombre, turnos) in guiones {
    var yo: [Float] = []
    var ellos: [Float] = []
    var etiquetas: [String] = ["# desde\thasta\thablante"]
    var cursor = 0.5
    for (i, (persona, frase)) in turnos.enumerated() {
      let archivo = tmp.appending(path: "\(nombre)-\(i).wav")
      let say = Process()
      say.executableURL = URL(filePath: "/usr/bin/say")
      say.arguments = ["-v", voces[persona] ?? "Mónica", "-o", archivo.path, "--data-format=LEI16@16000", frase]
      try say.run()
      say.waitUntilExit()
      let voz = try audio16k(archivo)
      // El cuarto turno pisa medio segundo al anterior: un solape de verdad.
      if i == 3 { cursor -= 0.8 }
      let desde = cursor
      let hasta = desde + Double(voz.count) / 16_000
      let a = Int(desde * 16_000)
      func pegar(_ pista: inout [Float]) {
        if pista.count < a + voz.count { pista += [Float](repeating: 0, count: a + voz.count - pista.count) }
        for (k, m) in voz.enumerated() { pista[a + k] = max(-1, min(1, pista[a + k] + m * 0.8)) }
      }
      if persona == "Yo" { pegar(&yo) } else { pegar(&ellos) }
      etiquetas.append(String(format: "%.2f\t%.2f\t%@", desde, hasta, persona))
      cursor = hasta + 0.4
    }
    let largo = max(yo.count, ellos.count) + 8_000
    yo += [Float](repeating: 0, count: largo - yo.count)
    ellos += [Float](repeating: 0, count: largo - ellos.count)
    try escribirWAV(yo, en: carpeta.appending(path: "\(nombre).yo.wav"))
    try escribirWAV(ellos, en: carpeta.appending(path: "\(nombre).ellos.wav"))
    try Data((etiquetas.joined(separator: "\n") + "\n").utf8).write(to: carpeta.appending(path: "\(nombre).etiquetas.tsv"))
    print("generado \(nombre): \(turnos.count) turnos, \(String(format: "%.1f", Double(largo) / 16_000)) s")
  }
}

let argumentos = Array(CommandLine.arguments.dropFirst())
guard argumentos.count >= 2 else {
  FileHandle.standardError.write(Data(uso.utf8))
  exit(2)
}
let comando = argumentos[0]
let carpeta = URL(filePath: argumentos[1], directoryHint: .isDirectory)
let salida = valor("--salida", argumentos).map { URL(filePath: $0, directoryHint: .isDirectory) }
  ?? carpeta.appending(path: "banco-resultados", directoryHint: .isDirectory)
let modelos = URL(filePath: valor("--modelos", argumentos) ?? "/Volumes/SSD2/dilo-modelos", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: salida, withIntermediateDirectories: true)

do {
  switch comando {
  case "generar":
    try generar(carpeta)
  case "transcribir":
    try await transcribir(carpeta, salida: salida)
  case "medir":
    guard let nombre = valor("--diarizador", argumentos), let diarizador = Diarizador(rawValue: nombre) else {
      error("Falta --diarizador: \(Diarizador.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    try await medir(carpeta, salida: salida, diarizador: diarizador, modelos: modelos)
  case "huellas":
    try await huellas(carpeta, salida: salida, modelos: modelos)
  case "resumen":
    try resumen(salida)
  default:
    FileHandle.standardError.write(Data(uso.utf8))
    exit(2)
  }
} catch {
  FileHandle.standardError.write(Data("falla: \(error.localizedDescription)\n".utf8))
  exit(1)
}

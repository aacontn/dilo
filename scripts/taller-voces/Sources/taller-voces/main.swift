import AVFAudio
import DiloEngines
import DiloText
import FluidAudio
import Foundation

// El banco de voces. Un motor por proceso, para que la RAM medida sea la de
// ese motor y no la suma de todos:
//
//   taller-voces sintetizar <motor> <salida> [voz,voz…]
//   taller-voces wer <salida>
//   taller-voces tabla <salida>
//
// Nada suena: todo se escribe a WAV.

let frases: [(id: String, texto: String)] = [
  ("1-casual", "Oye, el Pancho llegó atrasado otra vez a la pega y quedó la media embarrada, pero al final salió todo bacán, po."),
  ("2-formal", "Le informamos que el pago de $1.250.000 vence el 15/03/2026 y que el saldo pendiente de 3,5 UF se cobrará en la cuota de abril."),
  ("3-siglas", "La CMF y el SII revisaron el informe de Codelco; Javiera Fuentes, de la PDI, lo presentó en Valparaíso ante el BCI y la AFP Habitat."),
  ("4-larga", "Ayer en la tarde nos juntamos con el equipo para revisar cómo vamos con el proyecto. La verdad es que avanzamos harto: terminamos el diseño de la portada, dejamos lista la integración con el banco y probamos la aplicación con cinco clientes en Concepción y en Temuco. Lo que todavía nos complica es el tiempo de respuesta del servidor, que a veces se demora más de lo que debería, así que la próxima semana vamos a dedicarle dos días completos antes de mostrarle todo al directorio."),
  ("5-pregunta", "¿Te parece si nos juntamos mañana en la tarde a revisar la propuesta, o prefieres que lo dejemos para el lunes?"),
  ("6-numeros", "El 1° de octubre vendimos 2.348 unidades, un 12% más que el año pasado, y el envío número 47 salió a las 14:30 desde Avenida Providencia 1208."),
]

struct Medida: Codable {
  var motor: String
  var voz: String
  var frase: String
  var enviado: String
  var segundosDeAudio: Double
  var primerAudio: Double
  var total: Double
  var carga: Double
  var memoriaPicoMB: Double
  var archivo: String
}

struct Transcripcion: Codable {
  var motor: String
  var voz: String
  var frase: String
  var referencia: String
  var oido: String
  var errores: Int
  var palabras: Int
}

func ahora() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// El pico de memoria del proceso, en MB (lo mismo que mira Monitor de
/// Actividad: la huella física, no el RSS).
func memoriaPico() -> Double {
  var info = rusage_info_v4()
  let r = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
      proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
    }
  }
  guard r == 0 else { return 0 }
  return Double(info.ri_lifetime_max_phys_footprint) / 1_048_576
}

func escribirWAV(_ muestras: [Float], frecuencia: Int, en url: URL) throws {
  var datos = Data()
  func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { datos.append(contentsOf: $0) } }
  func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { datos.append(contentsOf: $0) } }
  let bytes = UInt32(muestras.count * 2)
  datos.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
  datos.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
  u32(UInt32(frecuencia)); u32(UInt32(frecuencia * 2)); u16(2); u16(16)
  datos.append(contentsOf: Array("data".utf8)); u32(bytes)
  for m in muestras {
    let v = Int16(max(-1, min(1, m)) * 32767)
    u16(UInt16(bitPattern: v))
  }
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try datos.write(to: url)
}

/// Lo que sale de un motor para una frase.
struct Sintesis {
  var muestras: [Float]
  var frecuencia: Int
  var primerAudio: Double
  var total: Double
  var enviado: String
}

protocol Motor {
  var nombre: String { get }
  func cargar() async throws
  func voces() async -> [String]
  func sintetizar(_ texto: String, voz: String) async throws -> Sintesis
}

/// Lo que la app le manda a una voz neural: el texto dicho y en trozos.
func paraLeer(_ texto: String) -> [String] {
  TrozosParaLeer.partir(TextoParaLeer.preparar(texto))
}

let modelos = URL(fileURLWithPath: "/Volumes/SSD2/dilo-voces/modelos")

final class MotorPocket: Motor, @unchecked Sendable {
  let nombre: String
  let idioma: PocketTtsLanguage
  let crudo: Bool
  var manager: PocketTtsManager!

  init(nombre: String, idioma: PocketTtsLanguage, crudo: Bool = false) {
    self.nombre = nombre
    self.idioma = idioma
    self.crudo = crudo
  }

  func cargar() async throws {
    let unidades: PocketTtsComputeUnits =
      ProcessInfo.processInfo.environment["POCKET_SIN_ANE"] == "1" ? .avoidNeuralEngine : .default
    manager = PocketTtsManager(
      defaultVoice: "lola", language: idioma,
      directory: modelos.appendingPathComponent("pocket"),
      precision: .int8, computeUnits: unidades
    )
    try await manager.initialize()
  }

  func voces() async -> [String] {
    [
      "lola", "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "cosette",
      "eponine", "estelle", "eve", "fantine", "george", "giovanni", "jane", "javert", "jean",
      "juergen", "marius", "mary", "michael", "paul", "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]
  }

  func sintetizar(_ texto: String, voz: String) async throws -> Sintesis {
    let trozos = crudo ? [texto] : paraLeer(texto)
    let inicio = ahora()
    // Como la app: una sesión por lectura, con la voz cargada una vez y los
    // trozos encolados.
    let sesion = try await manager.makeSession(voice: voz, seed: 42)
    for trozo in trozos { sesion.enqueue(trozo) }
    sesion.finish()
    var muestras: [Float] = []
    var primero: Double?
    for try await cuadro in sesion.frames {
      if primero == nil { primero = ahora() - inicio }
      muestras += cuadro.samples
    }
    return Sintesis(
      muestras: muestras, frecuencia: PocketTtsConstants.audioSampleRate,
      primerAudio: primero ?? 0, total: ahora() - inicio, enviado: trozos.joined(separator: " | ")
    )
  }
}

final class MotorSupertonic: Motor, @unchecked Sendable {
  let nombre = "supertonic3"
  var manager: Supertonic3Manager!
  var estilos: [String: Supertonic3VoiceStyle] = [:]
  let carpeta = modelos.appendingPathComponent("supertonic")

  func cargar() async throws {
    manager = Supertonic3Manager(directory: carpeta)
    try await manager.initialize()
  }

  func voces() async -> [String] { Supertonic3Voice.allCases.map(\.rawValue) }

  func sintetizar(_ texto: String, voz: String) async throws -> Sintesis {
    if estilos[voz] == nil {
      estilos[voz] = try await Supertonic3ResourceDownloader.loadVoiceStyle(
        Supertonic3Voice(name: voz)!, directory: carpeta)
    }
    let estilo = estilos[voz]!
    let trozos = paraLeer(texto)
    let inicio = ahora()
    var muestras: [Float] = []
    var primero: Double?
    // Sin streaming: el primer audio es el primer trozo entero.
    for trozo in trozos {
      let (s, _) = try await manager.synthesize(text: trozo, language: "es", style: estilo)
      if primero == nil { primero = ahora() - inicio }
      muestras += s
    }
    return Sintesis(
      muestras: muestras, frecuencia: Supertonic3Constants.sampleRate,
      primerAudio: primero ?? 0, total: ahora() - inicio, enviado: trozos.joined(separator: " | ")
    )
  }
}

/// Phonon por su CLI, `ptts`, en CPU: un proceso por trozo, que es como lo
/// usaría la app sin enlazar el runtime.
final class MotorPhonon: Motor, @unchecked Sendable {
  let nombre: String
  let modelo: URL
  let crudo: Bool
  let ptts = URL(fileURLWithPath: "/Volumes/SSD2/dilo-voces/ptts-cli/ptts-0.5.0-aarch64-apple-darwin/ptts")
  let hilos = ProcessInfo.processInfo.environment["PTTS_HILOS"] ?? "2"

  init(nombre: String, modelo: URL, crudo: Bool = false) {
    self.nombre = nombre
    self.modelo = modelo
    self.crudo = crudo
  }

  func cargar() async throws {}

  /// Las 25 voces en español del catálogo `gradium/phonon-voices`: 13 de
  /// España y 12 de México. Se piden por id: un nombre con tilde no siempre
  /// llega con la misma normalización Unicode que el catálogo.
  static let catalogo: [(nombre: String, id: String)] = [
    ("Noa", "b6FvJAiokjdqIti4"), ("Lucia-Sol", "3p0eIGbkmny71GlA"), ("Candela", "c9wqBDmQiBie5q6Y"),
    ("Celia", "rmLBOdHrfkFym9MM"), ("Alba", "u2UscyAnHilpiwmf"), ("Alicia", "4701YgRXjkBcg6sL"),
    ("Nerea", "EQcQFGkYfMn5YJgx"), ("Marcos", "jvPx8j8zLGQ3utZz"), ("Borja", "tIjCgP8v3RY8UpgM"),
    ("Iker", "t-_TS1e-0GzDAX02"), ("Nuno", "fghJGlv90qu8OJ36"), ("Izan", "Ejb29qHnSOK0cIHY"),
    ("Guillermo", "FaLVVqpFQcDOtq45"), ("Rebeca", "Sx8m6WdXBG06zwZT"), ("Regina", "s58clrg2fe0MO7Y-"),
    ("Danae", "evfxKSxpDIhmsNoq"), ("Azucena", "KJpIQlbYrZPA4aLq"), ("Jimena", "qG5BXOJYrKEnXLIX"),
    ("Ximena", "VDwnGxAo68C8U8vC"), ("Lalo", "F05gqkzX7WhKVpSL"), ("Aldo", "ax7dW1XB0eiMfHgO"),
    ("Yael", "ALczEazoF4n6PmGl"), ("Ulises", "G5HLUsQd659UtRe7"), ("Leonel", "BkuASiOJRrJEB5qA"),
    ("Nico", "PwgPEaweQILZdGc4"),
  ]

  func voces() async -> [String] { Self.catalogo.map(\.nombre) }

  func correr(_ texto: String, voz: String, salida: URL, reescrituras: String) throws {
    let p = Process()
    p.executableURL = ptts
    p.arguments = [
      "--model", modelo.path, "--lang", ProcessInfo.processInfo.environment["PTTS_LANG"] ?? "es",
      "--quant", ProcessInfo.processInfo.environment["PTTS_QUANT"] ?? "q8", "--threads", hilos,
      "--rewrites", reescrituras,
      "--voice", Self.catalogo.first { $0.nombre == voz }?.id ?? voz,
      // Como la app: la ñ escrita «ni» (`SintetizadorPhonon.paraPhonon`).
      crudo ? texto : SintetizadorPhonon.paraPhonon(texto), "-o", salida.path,
    ]
    var entorno = ProcessInfo.processInfo.environment
    entorno["RUST_LOG"] = "off"
    entorno["HF_HOME"] = "/Volumes/SSD2/dilo-voces/hf"
    entorno.removeValue(forKey: "HF_TOKEN")
    p.environment = entorno
    p.standardOutput = FileHandle.nullDevice
    let error = Pipe()
    p.standardError = error
    try p.run()
    let mensaje = error.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      throw NSError(
        domain: "ptts", code: Int(p.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: mensaje, as: UTF8.self)]
      )
    }
  }

  func sintetizar(_ texto: String, voz: String) async throws -> Sintesis {
    let trozos = crudo ? [texto] : paraLeer(texto)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ptts-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let inicio = ahora()
    var muestras: [Float] = []
    var primero: Double?
    for trozo in trozos {
      try correr(trozo, voz: voz, salida: tmp, reescrituras: crudo ? "all" : "default")
      if primero == nil { primero = ahora() - inicio }
      let archivo = try AVAudioFile(forReading: tmp)
      let buffer = AVAudioPCMBuffer(pcmFormat: archivo.processingFormat, frameCapacity: AVAudioFrameCount(archivo.length))!
      try archivo.read(into: buffer)
      muestras += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    return Sintesis(
      muestras: muestras, frecuencia: 24_000, primerAudio: primero ?? 0,
      total: ahora() - inicio, enviado: trozos.joined(separator: " | ")
    )
  }

  /// La memoria de los procesos hijos: el pico del más grande.
  static func memoriaDeLosHijos() -> Double {
    var uso = rusage()
    getrusage(RUSAGE_CHILDREN, &uso)
    return Double(uso.ru_maxrss) / 1_048_576
  }
}

/// Las voces de Apple, con el texto tal cual: traen su propio normalizador.
///
/// El fin se sabe por el delegado y no por el búfer vacío: con un párrafo
/// largo `write` manda búferes vacíos entre oraciones, y cortar en el
/// primero dejaba cuatro segundos de un párrafo de treinta.
final class MotorApple: NSObject, Motor, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  let nombre = "apple"
  let sintetizador = AVSpeechSynthesizer()
  var alTerminar: (() -> Void)?

  override init() {
    super.init()
    sintetizador.delegate = self
  }

  func cargar() async throws {}

  func voces() async -> [String] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("es") && !$0.identifier.contains("eloquence") && !$0.identifier.contains("super-compact") }
      .map(\.identifier)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // Los últimos búferes pueden llegar un pelo después del aviso.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.alTerminar?()
      self?.alTerminar = nil
    }
  }

  func sintetizar(_ texto: String, voz: String) async throws -> Sintesis {
    let enunciado = AVSpeechUtterance(string: texto)
    enunciado.voice = AVSpeechSynthesisVoice(identifier: voz)
    let inicio = ahora()
    final class Acumulado: @unchecked Sendable {
      var muestras: [Float] = []
      var frecuencia = 22_050
      var primero: Double?
      var fin: Double?
    }
    let a = Acumulado()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      alTerminar = { cont.resume() }
      sintetizador.write(enunciado) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
        if a.primero == nil { a.primero = ahora() - inicio }
        a.frecuencia = Int(pcm.format.sampleRate)
        let n = Int(pcm.frameLength)
        if let f = pcm.floatChannelData {
          a.muestras += Array(UnsafeBufferPointer(start: f[0], count: n))
        } else if let i = pcm.int16ChannelData {
          a.muestras += UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32768 }
        }
        a.fin = ahora() - inicio
      }
    }
    return Sintesis(
      muestras: a.muestras, frecuencia: a.frecuencia, primerAudio: a.primero ?? 0,
      total: a.fin ?? (ahora() - inicio), enviado: texto
    )
  }
}

func motor(_ nombre: String) -> any Motor {
  let hf = URL(fileURLWithPath: "/Volumes/SSD2/dilo-voces/hf/hub")
  func snapshot(_ repo: String) -> URL {
    let base = hf.appendingPathComponent("models--gradium--\(repo)/snapshots")
    let rev = (try? FileManager.default.contentsOfDirectory(atPath: base.path).first) ?? ""
    return base.appendingPathComponent(rev)
  }
  switch nombre {
  case "pocket-es": return MotorPocket(nombre: nombre, idioma: .spanish)
  case "pocket-es24": return MotorPocket(nombre: nombre, idioma: .spanish24L)
  case "pocket-es-crudo": return MotorPocket(nombre: nombre, idioma: .spanish, crudo: true)
  case "supertonic3": return MotorSupertonic()
  case "phonon40m-es": return MotorPhonon(nombre: nombre, modelo: snapshot("phonon-40m-es"))
  case "phonon40m-es-crudo": return MotorPhonon(nombre: nombre, modelo: snapshot("phonon-40m-es"), crudo: true)
  case "phonon40m-multi": return MotorPhonon(nombre: nombre, modelo: snapshot("phonon-40m-multilingual"))
  case "apple": return MotorApple()
  default: fatalError("motor desconocido: \(nombre)")
  }
}

func nombreDeCarpeta(_ motor: String, _ voz: String) -> String {
  let corta = voz.replacingOccurrences(of: "com.apple.", with: "")
    .folding(options: [.diacriticInsensitive], locale: nil)
    .lowercased()
    .replacingOccurrences(of: ".", with: "-")
    .replacingOccurrences(of: "_", with: "-")
  return "\(motor)-\(corta)"
}

func agregar<T: Encodable>(_ valor: T, a url: URL) throws {
  let linea = try JSONEncoder().encode(valor) + Data("\n".utf8)
  if let h = try? FileHandle(forWritingTo: url) {
    h.seekToEndOfFile(); h.write(linea); try h.close()
  } else {
    try linea.write(to: url)
  }
}

func sintetizar(_ nombre: String, salida: URL, soloVoces: [String]?) async throws {
  let m = motor(nombre)
  let t0 = ahora()
  try await m.cargar()
  let carga = ahora() - t0
  let todas = await m.voces()
  let voces = soloVoces ?? todas
  // Correr un motor otra vez reemplaza sus medidas.
  let archivo = salida.appendingPathComponent("medidas.jsonl")
  if let viejas = try? String(contentsOf: archivo, encoding: .utf8) {
    let otras = viejas.split(separator: "\n").filter {
      (try? JSONDecoder().decode(Medida.self, from: Data($0.utf8)))?.motor != nombre
        || !(soloVoces ?? todas).contains((try? JSONDecoder().decode(Medida.self, from: Data($0.utf8)))?.voz ?? "")
    }
    try otras.map { $0 + "\n" }.joined().write(to: archivo, atomically: true, encoding: .utf8)
  }
  print("\(nombre): cargado en \(String(format: "%.2f", carga)) s, \(voces.count) voces")
  // Una frase descartada para calentar: el primer uso compila y llena
  // cachés, y eso ya está medido en la carga.
  _ = try? await m.sintetizar("Hola.", voz: voces[0])
  for voz in voces {
    for frase in frases {
      let s = try await m.sintetizar(frase.texto, voz: voz)
      let carpeta = nombreDeCarpeta(nombre, voz)
      let url = salida.appendingPathComponent(carpeta).appendingPathComponent("\(frase.id).wav")
      try escribirWAV(s.muestras, frecuencia: s.frecuencia, en: url)
      let memoria = m is MotorPhonon ? MotorPhonon.memoriaDeLosHijos() : memoriaPico()
      let medida = Medida(
        motor: nombre, voz: voz, frase: frase.id, enviado: s.enviado,
        segundosDeAudio: Double(s.muestras.count) / Double(s.frecuencia),
        primerAudio: s.primerAudio, total: s.total, carga: carga,
        memoriaPicoMB: memoria, archivo: "\(carpeta)/\(frase.id).wav"
      )
      try agregar(medida, a: salida.appendingPathComponent("medidas.jsonl"))
      print(String(format: "  %@ %@ audio %.2fs primer %.3fs total %.2fs", voz, frase.id, medida.segundosDeAudio, s.primerAudio, s.total))
    }
  }
}

/// Minúsculas, sin tildes ni signos, con los números y siglas dichos igual en
/// los dos lados: el WER mide lo que se entiende, no cómo se escribe.
func plegar(_ texto: String) -> [String] {
  let plano = TextoParaLeer.preparar(texto)
    .lowercased()
    .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "es"))
  let limpio = String(plano.map { (c: Character) -> Character in c.isLetter || c.isNumber ? c : " " })
  return limpio.split(separator: " ").map(String.init)
}

func distancia(_ a: [String], _ b: [String]) -> Int {
  var fila = Array(0...b.count)
  for i in 1...max(a.count, 1) where !a.isEmpty {
    var anterior = fila[0]
    fila[0] = i
    for j in stride(from: 1, through: b.count, by: 1) {
      let actual = fila[j]
      fila[j] = min(fila[j] + 1, fila[j - 1] + 1, anterior + (a[i - 1] == b[j - 1] ? 0 : 1))
      anterior = actual
    }
  }
  return a.isEmpty ? b.count : fila[b.count]
}

func wer(salida: URL) async throws {
  let medidas = try String(contentsOf: salida.appendingPathComponent("medidas.jsonl"), encoding: .utf8)
    .split(separator: "\n").map { try JSONDecoder().decode(Medida.self, from: Data($0.utf8)) }
  let hechas = Set(
    ((try? String(contentsOf: salida.appendingPathComponent("wer.jsonl"), encoding: .utf8)) ?? "")
      .split(separator: "\n")
      .compactMap { try? JSONDecoder().decode(Transcripcion.self, from: Data($0.utf8)) }
      .map { "\($0.motor)|\($0.voz)|\($0.frase)" }
  )
  // El Parakeet v3 que ya tiene Dilo, sólo leído.
  let carpeta = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Dilo/models/parakeet-tdt-0.6b-v3")
  let modelos = try await AsrModels.load(from: carpeta, version: .v3, encoderPrecision: .int8)
  let asr = AsrManager(config: .default)
  try await asr.loadModels(modelos)
  let conversor = AudioConverter()
  for m in medidas where !hechas.contains("\(m.motor)|\(m.voz)|\(m.frase)") {
    let muestras = try conversor.resampleAudioFile(salida.appendingPathComponent(m.archivo))
    var estado = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let r = try await asr.transcribe(muestras, decoderState: &estado, language: .spanish)
    let original = frases.first { $0.id == m.frase }!.texto
    let ref = plegar(original), oido = plegar(r.text)
    let t = Transcripcion(
      motor: m.motor, voz: m.voz, frase: m.frase, referencia: ref.joined(separator: " "),
      oido: r.text, errores: distancia(ref, oido), palabras: ref.count
    )
    try agregar(t, a: salida.appendingPathComponent("wer.jsonl"))
    print(String(format: "%@ %@ %@ WER %.1f%%  «%@»", m.motor, m.voz, m.frase, 100 * Double(t.errores) / Double(t.palabras), r.text))
  }
}

/// La instalación y el sintetizador de la app, de punta a punta, en una
/// carpeta aparte: baja el runtime y una voz de verdad (con sus hashes), copia
/// el modelo de la caché del taller, lee una frase y prueba que detener corta
/// al tiro.
func probarLaApp(carpeta: URL, salida: URL) async throws {
  InstalacionDePhonon.raiz = carpeta
  let fm = FileManager.default
  let cache = URL(fileURLWithPath: "/Volumes/SSD2/dilo-voces/hf/hub/models--gradium--phonon-40m-es/snapshots")
  let snapshot = cache.appendingPathComponent(try fm.contentsOfDirectory(atPath: cache.path).first!)
  try fm.createDirectory(at: InstalacionDePhonon.carpetaDelModelo, withIntermediateDirectories: true)
  for archivo in InstalacionDePhonon.archivosDelModelo {
    let destino = InstalacionDePhonon.carpetaDelModelo.appendingPathComponent(archivo.nombre)
    if !fm.fileExists(atPath: destino.path) {
      try fm.copyItem(at: snapshot.appendingPathComponent(archivo.nombre).resolvingSymlinksInPath(), to: destino)
    }
  }
  let voz = VocesDePhonon.voz(VocesDePhonon.deFabrica)
  print("antes:", InstalacionDePhonon.estado(voz: voz))
  let instalacion = InstalacionDePhonon()
  let t0 = ahora()
  try await instalacion.preparar(voz: voz) { avance in
    print(String(format: "  %.0f%% %@", avance.fraccion * 100, avance.fase))
  }
  print(String(format: "preparado en %.1f s:", ahora() - t0), InstalacionDePhonon.estado(voz: voz))

  let sintetizador = SintetizadorPhonon(instalacion: instalacion)
  let trozos = TrozosParaLeer.partir(TextoParaLeer.preparar(frases[1].texto))
  var muestras: [Float] = []
  for trozo in trozos {
    let t = ahora()
    let s = try await sintetizador.sintetizar(trozo, voz: voz)
    print(String(format: "  trozo %.2f s de audio en %.2f s: %@", Double(s.count) / 24_000, ahora() - t, trozo))
    muestras += s
  }
  try escribirWAV(muestras, frecuencia: 24_000, en: salida)

  let larga = TextoParaLeer.preparar(frases[3].texto)
  let tarea = Task { try await sintetizador.sintetizar(larga, voz: voz) }
  try await Task.sleep(for: .milliseconds(80))
  let t = ahora()
  tarea.cancel()
  let resultado = await tarea.result
  print(String(format: "detener: volvió en %.0f ms (%@)", (ahora() - t) * 1000, String("\(resultado)".prefix(60))))
}

/// Las medidas y el WER, juntos: una fila por motor y otra por voz, en
/// Markdown, para el README de la carpeta de los WAV.
func tabla(salida: URL) throws {
  func leer<T: Decodable>(_ nombre: String, _ tipo: T.Type) -> [T] {
    ((try? String(contentsOf: salida.appendingPathComponent(nombre), encoding: .utf8)) ?? "")
      .split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
  }
  let medidas = leer("medidas.jsonl", Medida.self)
  let wers = leer("wer.jsonl", Transcripcion.self)
  func mediana(_ v: [Double]) -> Double {
    let o = v.sorted()
    return o.isEmpty ? 0 : o.count % 2 == 1 ? o[o.count / 2] : (o[o.count / 2 - 1] + o[o.count / 2]) / 2
  }
  func fila(_ ms: [Medida], _ ws: [Transcripcion]) -> String {
    // La primera frase de cada voz paga cachés frías: el primer audio se
    // mide como mediana, que la deja afuera sin esconderla.
    let primer = mediana(ms.map(\.primerAudio))
    let rtf = ms.map(\.segundosDeAudio).reduce(0, +) / max(ms.map(\.total).reduce(0, +), 0.001)
    let memoria = ms.map(\.memoriaPicoMB).max() ?? 0
    let errores = ws.map(\.errores).reduce(0, +), palabras = ws.map(\.palabras).reduce(0, +)
    let wer = palabras > 0 ? String(format: "%.1f %%", 100 * Double(errores) / Double(palabras)) : "—"
    return String(format: "%.2f s | %.1f× | %.0f MB | %@", primer, rtf, memoria, wer)
  }
  var texto = "| Motor | Voces | Primer audio (mediana) | Tiempo real | RAM pico | WER |\n| --- | --- | --- | --- | --- | --- |\n"
  let motores = Array(Set(medidas.map(\.motor))).sorted()
  for m in motores {
    let ms = medidas.filter { $0.motor == m }
    let ws = wers.filter { $0.motor == m }
    texto += "| \(m) | \(Set(ms.map(\.voz)).count) | \(fila(ms, ws)) |\n"
  }
  texto += "\n| Motor | Voz | Primer audio (mediana) | Tiempo real | RAM pico | WER | Carpeta |\n| --- | --- | --- | --- | --- | --- | --- |\n"
  var filas: [(Double, String)] = []
  for m in motores {
    for v in Array(Set(medidas.filter { $0.motor == m }.map(\.voz))).sorted() {
      let ms = medidas.filter { $0.motor == m && $0.voz == v }
      let ws = wers.filter { $0.motor == m && $0.voz == v }
      let e = Double(ws.map(\.errores).reduce(0, +)) / Double(max(ws.map(\.palabras).reduce(0, +), 1))
      filas.append((e, "| \(m) | \(v) | \(fila(ms, ws)) | `\(nombreDeCarpeta(m, v))/` |"))
    }
  }
  texto += filas.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n") + "\n"
  texto += "\n| Motor | Voz | Frase | Lo que oyó Parakeet |\n| --- | --- | --- | --- |\n"
  for w in wers.sorted(by: { ($0.motor, $0.voz, $0.frase) < ($1.motor, $1.voz, $1.frase) }) where w.errores > 0 {
    texto += "| \(w.motor) | \(w.voz) | \(w.frase) (\(w.errores)/\(w.palabras)) | \(w.oido.replacingOccurrences(of: "|", with: "/")) |\n"
  }
  try texto.write(to: salida.appendingPathComponent("tabla.md"), atomically: true, encoding: .utf8)
  print(texto.split(separator: "\n").prefix(14).joined(separator: "\n"))
}

/// Una frase cualquiera por varios motores y de vuelta por Parakeet, para
/// mirar un sonido puntual (la ñ, por ejemplo) sin rehacer el banco.
func probarFrase(_ texto: String, motores: [(String, String)], salida: URL) async throws {
  let carpeta = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Dilo/models/parakeet-tdt-0.6b-v3")
  let asr = AsrManager(config: .default)
  try await asr.loadModels(try await AsrModels.load(from: carpeta, version: .v3, encoderPrecision: .int8))
  let conversor = AudioConverter()
  for (nombre, voz) in motores {
    let m = motor(nombre)
    try await m.cargar()
    let s = try await m.sintetizar(texto, voz: voz)
    let url = salida.appendingPathComponent("\(nombreDeCarpeta(nombre, voz)).wav")
    try escribirWAV(s.muestras, frecuencia: s.frecuencia, en: url)
    var estado = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let r = try await asr.transcribe(try conversor.resampleAudioFile(url), decoderState: &estado, language: .spanish)
    print("\(nombre) \(voz): «\(r.text)»")
  }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "sintetizar":
  let voces = args.count > 4 ? args[4].split(separator: ",").map(String.init) : nil
  try await sintetizar(args[2], salida: URL(fileURLWithPath: args[3]), soloVoces: voces)
case "app":
  try await probarLaApp(carpeta: URL(fileURLWithPath: args[2]), salida: URL(fileURLWithPath: args[3]))
case "frase":
  // taller-voces frase "<texto>" <salida> motor:voz motor:voz…
  let motores = args.dropFirst(4).map { a -> (String, String) in
    let p = a.split(separator: ":", maxSplits: 1).map(String.init)
    return (p[0], p[1])
  }
  try await probarFrase(args[2], motores: motores, salida: URL(fileURLWithPath: args[3]))
case "oir":
  // taller-voces oir <archivo…>: lo que Parakeet oye en cada uno.
  let carpeta = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Dilo/models/parakeet-tdt-0.6b-v3")
  let asr = AsrManager(config: .default)
  try await asr.loadModels(try await AsrModels.load(from: carpeta, version: .v3, encoderPrecision: .int8))
  for archivo in args.dropFirst(2) {
    var estado = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let muestras = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: archivo))
    let r = try await asr.transcribe(muestras, decoderState: &estado, language: .spanish)
    print("\((archivo as NSString).lastPathComponent): «\(r.text)»")
  }
case "tabla":
  try tabla(salida: URL(fileURLWithPath: args[2]))
case "wer":
  try await wer(salida: URL(fileURLWithPath: args[2]))
default:
  print("uso: taller-voces sintetizar <motor> <salida> [voces] | wer <salida>")
  exit(64)
}

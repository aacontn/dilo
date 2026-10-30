import DiloEngines
import DiloMetrics
import FluidAudio
import Foundation

// El banco de comparación de motores: transcribe cada WAV de una carpeta con
// cada motor pedido, con el mismo código que dicta en la app, y dice cuánto
// tardó y —si hay un `.txt` con la referencia al lado— cuántas palabras erró.
// Es de taller, como `dilo-metrics`: la app no lo enlaza. Se corre con
// `scripts/comparar-motores.sh`, que lo construye.
//
// Los motores:
// - `v3` y `ultra`: `ParakeetEngine.transcribirSinSesion`, que es el camino
//   del reintento de la app —recorte de bordes, la pasada final y la costura
//   de trozos—. Es lo mismo que pasa al soltar, sin micrófono.
// - `nemotron`: Nemotron Unified ASR 0.6B multilingüe con el prompt de
//   español (FluidAudio 0.18), sólo para medir; la app no lo ofrece. Lleva
//   el mismo recorte de bordes para que la comparación sea pareja.
// Bark 3.0 no está: es sólo inglés.
//
// Con `--tus-palabras "Decameron,Andes Flags"` cada Parakeet corre dos veces:
// sin y con la segunda pasada de Tus palabras (`v3+tp`), para medir cuánto
// suma al soltar→texto y si acierta. El CTC vive en la carpeta de FluidAudio
// dentro de Application Support; para bajarlo fuera del disco interno, correr
// con `CFFIXED_USER_HOME=/Volumes/SSD2/…`.

func valor(de bandera: String, en argumentos: [String]) -> String? {
  guard let indice = argumentos.firstIndex(of: bandera), indice + 1 < argumentos.count else {
    return nil
  }
  return argumentos[indice + 1]
}

func salir(_ mensaje: String, codigo: Int32 = 2) -> Never {
  FileHandle.standardError.write(Data((mensaje + "\n").utf8))
  exit(codigo)
}

let argumentos = Array(CommandLine.arguments.dropFirst())
let uso = """
  uso: dilo-comparar-motores <carpeta con WAV> [--motores v3,ultra[,nemotron]]
                             [--modelos <carpeta>] [--bajar] [--csv <archivo>] [--sin-textos]
                             [--tus-palabras "Término,Otro término"]
  """

guard let rutaDeLaCarpeta = argumentos.first, !rutaDeLaCarpeta.hasPrefix("--") else { salir(uso) }
let carpeta = URL(filePath: rutaDeLaCarpeta)
let motores = (valor(de: "--motores", en: argumentos) ?? "v3,ultra")
  .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
let modelos = valor(de: "--modelos", en: argumentos).map { URL(filePath: $0) } ?? ParakeetModelStore.carpeta
let bajar = argumentos.contains("--bajar")
let conTextos = !argumentos.contains("--sin-textos")
let rutaDelCSV = valor(de: "--csv", en: argumentos)
let tusPalabras = valor(de: "--tus-palabras", en: argumentos).map {
  $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
}

for motor in motores where !["v3", "ultra", "nemotron"].contains(motor) {
  salir("motor desconocido: \(motor) (son v3, ultra y nemotron)\n\(uso)")
}

// Lo dicho no va al log, tampoco desde el taller.
RegistroDeFluidAudio.callar()

struct Archivo {
  let nombre: String
  let muestras: [Float]
  let referencia: String?
  var segundos: Double { Double(muestras.count) / 16_000 }
}

let wavs = ((try? FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)) ?? [])
  .filter { $0.pathExtension.lowercased() == "wav" }
  .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
guard !wavs.isEmpty else { salir("no hay ningún .wav en \(carpeta.path)") }

let conversor = AudioConverter()
var archivos: [Archivo] = []
for wav in wavs {
  do {
    let muestras = try conversor.resampleAudioFile(wav)
    let txt = wav.deletingPathExtension().appendingPathExtension("txt")
    let referencia = try? String(contentsOf: txt, encoding: .utf8)
    archivos.append(Archivo(nombre: wav.lastPathComponent, muestras: muestras, referencia: referencia))
  } catch {
    FileHandle.standardError.write(Data("no se pudo leer \(wav.lastPathComponent): \(error.localizedDescription)\n".utf8))
  }
}
let conReferencia = archivos.filter { $0.referencia != nil }.count
print("\(archivos.count) archivos, \(conReferencia) con referencia; modelos en \(modelos.path)")

/// Un micrófono que no existe: el banco transcribe audio que ya está en RAM.
struct SinMicrofono: AudioCapture {
  func iniciar(
    sampleRate: Double,
    muestras: @escaping @Sendable ([Float]) -> Void,
    nivel: @escaping @Sendable (Float) -> Void,
    falla: @escaping @Sendable (String) -> Void
  ) throws {}
  func detener() {}
}

typealias Transcribir = @Sendable ([Float]) async throws -> String

func prepararParakeet(_ variante: VarianteDeParakeet, tusPalabras: [String]? = nil) async throws -> Transcribir? {
  let almacen = ParakeetModelStore(variante: variante, carpeta: modelos)
  if !almacen.estaDescargado {
    guard bajar else {
      print("· \(variante.nombre) no está en \(modelos.path): se salta (usa --bajar)")
      return nil
    }
    print("· bajando \(variante.nombre)…")
    try await almacen.descargar { _ in }
  }
  let mb = Double(ParakeetModelStore.tamanoEnDisco(variante, en: modelos)) / 1_048_576
  print("· \(variante.nombre): \(Int(mb.rounded())) MB en disco")
  if let tusPalabras {
    if !ModeloDeTusPalabras.estaDescargado {
      guard bajar else {
        print("· el CTC de Tus palabras no está en \(ModeloDeTusPalabras.carpeta.path): se salta (usa --bajar)")
        return nil
      }
      print("· bajando el CTC de Tus palabras…")
      try await ModeloDeTusPalabras().descargar()
    }
    print("· Tus palabras: \(RefuerzoDeTusPalabras.terminos(de: tusPalabras).count) términos")
  }
  let motor = ParakeetEngine(
    captura: SinMicrofono(),
    cargador: CargadorDeParakeet(carpeta: modelos, elegida: { variante }, tusPalabras: { tusPalabras }),
    reposo: nil
  )
  return { try await motor.transcribirSinSesion($0) }
}

func prepararNemotron() async throws -> Transcribir? {
  let config = UnifiedConfig(family: .nemotronMultilingual(.es))
  let carpetaDelModelo = modelos.appendingPathComponent(config.family.repo.folderName, isDirectory: true)
  if !FileManager.default.fileExists(atPath: carpetaDelModelo.path), !bajar {
    print("· Nemotron no está en \(modelos.path): se salta (usa --bajar)")
    return nil
  }
  let manager = UnifiedAsrManager(config: config)
  try await manager.loadModels(to: modelos)
  return { muestras in
    var audio = muestras
    guard let tramo = RecorteDeBordes.preparar(&audio) else { return "" }
    return try await manager.transcribe(Array(audio[tramo]))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct Resultado {
  let archivo: String
  let motor: String
  let segundos: Double
  let ms: Double
  let error: ErrorDePalabras?
  let texto: String
}

func ms(_ duracion: Duration) -> Double {
  Double(duracion.components.seconds) * 1_000 + Double(duracion.components.attoseconds) / 1e15
}

var resultados: [Resultado] = []
let reloj = ContinuousClock()

// Con Tus palabras, cada Parakeet corre también con la segunda pasada.
let corridas = motores.flatMap { motor in
  tusPalabras != nil && motor != "nemotron" ? [motor, motor + "+tp"] : [motor]
}

for motor in corridas {
  let transcribir: Transcribir?
  do {
    switch motor {
    case "v3": transcribir = try await prepararParakeet(.v3)
    case "ultra": transcribir = try await prepararParakeet(.ultra)
    case "v3+tp": transcribir = try await prepararParakeet(.v3, tusPalabras: tusPalabras)
    case "ultra+tp": transcribir = try await prepararParakeet(.ultra, tusPalabras: tusPalabras)
    default: transcribir = try await prepararNemotron()
    }
  } catch {
    print("· \(motor) no se pudo preparar: \(error.localizedDescription)")
    continue
  }
  guard let transcribir else { continue }

  // La carga y la primera predicción —Core ML compilando el grafo— no las
  // mide nadie con la tecla en la mano: se pagan antes de medir.
  let carga = try await reloj.measure { _ = try await transcribir(archivos[0].muestras) }
  print("· \(motor): carga y primera pasada \(Int(ms(carga))) ms")

  for archivo in archivos {
    var texto = ""
    do {
      let duracion = try await reloj.measure { texto = try await transcribir(archivo.muestras) }
      let error = archivo.referencia.map { ErrorDePalabras.medir(referencia: $0, hipotesis: texto) }
      resultados.append(
        Resultado(archivo: archivo.nombre, motor: motor, segundos: archivo.segundos, ms: ms(duracion), error: error, texto: texto)
      )
      let wer = error.map { String(format: "%5.1f %%", $0.tasa * 100) } ?? "   — "
      print(String(format: "%@\t%@\t%5.1f s\t%5.0f ms\t%@", archivo.nombre, motor, archivo.segundos, ms(duracion), wer)
        + (conTextos ? "\t\(texto)" : ""))
    } catch {
      print("\(archivo.nombre)\t\(motor)\tfalló: \(error.localizedDescription)")
    }
  }
}

print("\nmotor\tarchivos\taudio\tp50\tp95\tmáx\tWER del corpus")
for motor in corridas {
  let deEste = resultados.filter { $0.motor == motor }
  guard !deEste.isEmpty else { continue }
  let tiempos = deEste.map(\.ms).sorted()
  let p50 = tiempos[tiempos.count / 2]
  let p95 = tiempos[min(tiempos.count - 1, Int(Double(tiempos.count) * 0.95))]
  let audio = deEste.map(\.segundos).reduce(0, +)
  let errores = deEste.compactMap(\.error)
  let corpus = errores.reduce(ErrorDePalabras.cero, +)
  let wer = errores.isEmpty ? "—" : String(format: "%.2f %% (%d/%d)", corpus.tasa * 100, corpus.ediciones, corpus.palabras)
  print(String(format: "%@\t%d\t%.0f s\t%.0f ms\t%.0f ms\t%.0f ms\t%@", motor, deEste.count, audio, p50, p95, tiempos.last ?? 0, wer))
}

if let rutaDelCSV {
  func campo(_ texto: String) -> String { "\"" + texto.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
  var csv = "archivo,motor,segundos,ms,ediciones,palabras,texto\n"
  for r in resultados {
    csv += [campo(r.archivo), r.motor, String(format: "%.2f", r.segundos), String(format: "%.0f", r.ms),
            r.error.map { "\($0.ediciones)" } ?? "", r.error.map { "\($0.palabras)" } ?? "", campo(r.texto)]
      .joined(separator: ",") + "\n"
  }
  try csv.write(toFile: rutaDelCSV, atomically: true, encoding: .utf8)
  print("\nCSV en \(rutaDelCSV)")
}

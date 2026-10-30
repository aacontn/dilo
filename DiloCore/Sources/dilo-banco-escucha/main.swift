import DiloEngines
import DiloModes
import FluidAudio
import Foundation

// La espiga de la escucha de nombres (2026-10-30): ¿con qué se oye «Dilo, …»
// sin gastar un núcleo? Todo con archivos: el corpus lo arma
// `/Volumes/SSD 1/Dilo/taller/escucha/generar-corpus.py` con `say -o`, y acá
// nada abre el micrófono ni suena. Es de taller, como `dilo-banco-reuniones`:
// la app no lo enlaza.
//
// Compara, sobre los mismos audios:
// - detector de voz: Silero (FluidAudio) o una puerta de energía sin modelo;
// - quién decide si hay nombre: (a) Parakeet + `NombreQueDespierta`, (b) el
//   CTC de FluidAudio buscando «dilo», (c) `SpeechTranscriber` de Apple (sólo
//   sobre los clips: correrlo de fondo ocupa un análisis del tope que ya usa
//   el dictado).
// La ventana —qué tramo se transcribe y cuándo— es `VentanaDeEscucha`, la
// misma de la app.

func valor(_ bandera: String) -> String? {
  let a = CommandLine.arguments
  guard let i = a.firstIndex(of: bandera), i + 1 < a.count else { return nil }
  return a[i + 1]
}

let taller = URL(filePath: valor("--taller") ?? "/Volumes/SSD 1/Dilo/taller/escucha")
let audios = taller.appendingPathComponent("audios")
let salida = taller.appendingPathComponent("resultados")
let modelos = URL(filePath: valor("--modelos") ?? "/Volumes/SSD2/dilo-taller/modelos")
let carpetaVAD = URL(filePath: valor("--vad") ?? "/Volumes/SSD2/dilo-taller/vad")
let carpetaCTC = URL(
  filePath: valor("--ctc")
    ?? "/Volumes/SSD2/dilo-taller/home/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml"
)
let conApple = CommandLine.arguments.contains("--apple")
let soloClips = CommandLine.arguments.contains("--solo-clips")
let umbralCTCPedido = valor("--umbral-ctc").flatMap(Float.init)
// `--solo silero+parakeet` corre sólo esa combinación sobre los audios largos
// y deja el informe en `--informe` (por defecto `resultados.md`).
let solo = valor("--solo")
let nombreDelInforme = valor("--informe") ?? "resultados.md"

RegistroDeFluidAudio.callar()
try FileManager.default.createDirectory(at: salida, withIntermediateDirectories: true)

func linea(_ s: String) {
  print(s)
  fflush(stdout)
}

// Los clips.
var clips: [Clip.Categoria: [Clip]] = [:]
for categoria in Clip.Categoria.allCases {
  clips[categoria] = try Corpus.leer(audios, categoria: categoria)
  let total = clips[categoria]!.reduce(0) { $0 + $1.segundos }
  linea("· \(categoria.rawValue): \(clips[categoria]!.count) audios, \(String(format: "%.1f", total / 60)) min")
}

// Los modelos, con lo que suma cada uno a la RAM.
var ram: [(String, Double)] = [("base", Medida.ramMB())]
let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5), modelDirectory: carpetaVAD)
_ = try await vad.process([Float](repeating: 0, count: 4_096))
ram.append(("+ Silero", Medida.ramMB()))
let asr = AsrManager(config: .default)
try await asr.loadModels(
  try await AsrModels.load(
    from: ParakeetModelStore.carpetaDelModelo(.ultra, en: modelos), version: .ultra, encoderPrecision: .int8
  )
)
// Dos reglas: sólo «Dilo» escrito así (R0) y con lo que el motor escribe en
// su lugar (R1, `comoLoOyeElMotor`). Las dos exigen el nombre apartado.
let reglaR0 = NombreQueDespierta(agentes: Agente.deFabrica, variantes: { [SenalesDelTurno.plegar($0.nombre)] })
let reglaDilo = NombreQueDespierta(agentes: Agente.deFabrica)
let parakeet = DecisorParakeet(manager: asr, regla: reglaDilo)
let parakeetR0 = DecisorParakeet(manager: asr, regla: reglaR0, nombre: "parakeet R0")
_ = try await parakeet.buscar(clips[.positivos]![0].muestras)
ram.append(("+ Parakeet Ultra", Medida.ramMB()))
let ctcModelos = try await CtcModels.loadDirect(from: carpetaCTC)
let ctcTokenizer = try await CtcTokenizer.load(from: carpetaCTC)
let ctc = DecisorCTC(modelos: ctcModelos, tokenizer: ctcTokenizer, umbral: umbralCTCPedido ?? -7)
_ = try await ctc.buscar(clips[.positivos]![0].muestras)
ram.append(("+ CTC 110M", Medida.ramMB()))
for (que, mb) in ram { linea(String(format: "· RAM %@: %.0f MB", que, mb)) }

// Fase 1: cada clip entero, por cada camino.
struct FilaDeClip {
  let clip: Clip
  let parakeet: Busqueda
  let parakeetVentana: Busqueda
  let ctc: Busqueda
  let ctcPuntaje: Float?
  let apple: String?
  let appleMs: Double?
}

var filas: [FilaDeClip] = []
let reloj = ContinuousClock()
for categoria in [Clip.Categoria.positivos, .duros, .verbo] {
  for clip in clips[categoria]! {
    let p = try await parakeet.buscar(clip.muestras)
    let ventana = Array(clip.muestras.prefix(24_000))
    let pv = try await parakeet.buscar(ventana)
    let c = try await ctc.buscar(ventana)
    let puntaje = try await ctc.puntaje(ventana)?.0
    var apple: String?
    var appleMs: Double?
    if conApple {
      var texto = ""
      let d = try await reloj.measure {
        texto = try await TranscriptorDeApple.transcribir(clip.muestras, locale: Locale(identifier: "es_CL"))
      }
      apple = texto
      appleMs = Medida.ms(d)
    }
    filas.append(FilaDeClip(clip: clip, parakeet: p, parakeetVentana: pv, ctc: c, ctcPuntaje: puntaje, apple: apple, appleMs: appleMs))
  }
  linea("· clips \(categoria.rawValue) listos")
}

func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
var textoCSV = "categoria,archivo,dicho,parakeet,parakeet_ms,parakeet_1.5s,primera,confianza,ctc_puntaje,apple,apple_ms\n"
for f in filas {
  textoCSV += [
    f.clip.categoria.rawValue, f.clip.nombre, csv(f.clip.texto), csv(f.parakeet.texto), String(format: "%.0f", f.parakeet.ms),
    csv(f.parakeetVentana.texto), csv(f.parakeetVentana.primera?.0 ?? ""),
    f.parakeetVentana.primera.map { String(format: "%.3f", $0.1) } ?? "", f.ctcPuntaje.map { String(format: "%.2f", $0) } ?? "", csv(f.apple ?? ""),
    f.appleMs.map { String(format: "%.0f", $0) } ?? "",
  ].joined(separator: ",") + "\n"
}
if solo == nil {
  try textoCSV.write(to: salida.appendingPathComponent("clips.csv"), atomically: true, encoding: .utf8)
}

@MainActor func tasa(_ categoria: Clip.Categoria, _ acierta: (FilaDeClip) -> Bool) -> String {
  let de = filas.filter { $0.clip.categoria == categoria }
  let n = de.filter(acierta).count
  return "\(n)/\(de.count) (\(String(format: "%.0f", 100 * Double(n) / Double(max(1, de.count))))%)"
}

// El CTC: sus puntajes no separan positivos de negativos (ver la tabla); -7
// deja pasar ~40 % de los positivos y ~20 % de lo demás.
let puntajesPositivos = filas.filter { $0.clip.categoria == .positivos }.map { $0.ctcPuntaje ?? -.infinity }.sorted()
let umbralCTC = umbralCTCPedido ?? -7
_ = puntajesPositivos

var informe = "# Espiga de la escucha de nombres — resultados\n\n"
informe += "Generado por `dilo-banco-escucha` el \(Date().formatted(.iso8601)).\n\n"
informe += "## RAM (huella física del proceso)\n\n| | MB |\n| --- | --- |\n"
for (que, mb) in ram { informe += "| \(que) | \(String(format: "%.0f", mb)) |\n" }
informe += "\n## Clips sueltos\n\n"
informe += "Positivos: cuántos despiertan. Duros y verbo: cuántos despiertan (falsas alarmas).\n\n"
informe += "| Camino | Positivos | Duros | Verbo «dilo» | ms por clip (mediana) |\n| --- | --- | --- | --- | --- |\n"
func mediana(_ xs: [Double]) -> Double {
  let o = xs.sorted()
  return o.isEmpty ? 0 : o[o.count / 2]
}
informe += "| (a) Parakeet, clip entero | \(tasa(.positivos) { $0.parakeet.hayNombre }) | \(tasa(.duros) { $0.parakeet.hayNombre }) | \(tasa(.verbo) { $0.parakeet.hayNombre }) | \(String(format: "%.0f", mediana(filas.map(\.parakeet.ms)))) |\n"
func r0(_ b: Busqueda) -> Bool { reglaR0.oir(b.texto) != nil }
informe += "| (a) Parakeet R0 (sólo «dilo»), clip entero | \(tasa(.positivos) { r0($0.parakeet) }) | \(tasa(.duros) { r0($0.parakeet) }) | \(tasa(.verbo) { r0($0.parakeet) }) | |\n"
informe += "| (a) Parakeet R0 (sólo «dilo»), primer 1,5 s | \(tasa(.positivos) { r0($0.parakeetVentana) }) | \(tasa(.duros) { r0($0.parakeetVentana) }) | \(tasa(.verbo) { r0($0.parakeetVentana) }) | |\n"
informe += "| (a) Parakeet, primer 1,5 s | \(tasa(.positivos) { $0.parakeetVentana.hayNombre }) | \(tasa(.duros) { $0.parakeetVentana.hayNombre }) | \(tasa(.verbo) { $0.parakeetVentana.hayNombre }) | \(String(format: "%.0f", mediana(filas.map(\.parakeetVentana.ms)))) |\n"
func ctcPasa(_ f: FilaDeClip) -> Bool { (f.ctcPuntaje ?? -.infinity) >= umbralCTC }
informe += "| (b) CTC «dilo» ≥ \(String(format: "%.2f", umbralCTC)), primer 1,5 s | \(tasa(.positivos, ctcPasa)) | \(tasa(.duros, ctcPasa)) | \(tasa(.verbo, ctcPasa)) | \(String(format: "%.0f", mediana(filas.map(\.ctc.ms)))) |\n"
if conApple {
  func applePasa(_ f: FilaDeClip) -> Bool { reglaDilo.oir(f.apple ?? "") != nil }
  informe += "| (c) Apple SpeechTranscriber, clip entero | \(tasa(.positivos, applePasa)) | \(tasa(.duros, applePasa)) | \(tasa(.verbo, applePasa)) | \(String(format: "%.0f", mediana(filas.compactMap(\.appleMs)))) |\n"
}
informe += "\nLos textos de cada clip están en `clips.csv`.\n"

// Lo que se perdió y lo que despertó de más, para leer.
informe += "\n### Parakeet, primer 1,5 s: lo que falló\n\n"
for f in filas where (f.clip.categoria == .positivos) != f.parakeetVentana.hayNombre {
  informe += "- \(f.clip.categoria.rawValue)/\(f.clip.nombre): «\(f.clip.texto)» → «\(f.parakeetVentana.texto)»\n"
}

try informe.write(to: salida.appendingPathComponent(nombreDelInforme), atomically: true, encoding: .utf8)
linea(informe)
if soloClips { exit(0) }

// Fase 2: audios largos por la ventana de la app.
let mezclables = (clips[.positivos]! + clips[.duros]! + clips[.verbo]!)
var azarMezcla = Azar(11)
let mezcla = Corrida.armar(
  "mezcla", clips: mezclables.shuffled(using: &azarMezcla), pausa: 1.5...4,
  fondos: [(.silencio, 0), (.blanco, -55), (.ventilador, -38), (.rosa, -45)], conRuido: true, semilla: 12
)
let prosa = Corrida.armar(
  "prosa", clips: clips[.prosa]!, pausa: 0.4...2, fondos: [(.silencio, 0), (.blanco, -55), (.ventilador, -40)],
  conRuido: false, semilla: 13
)
let ruido = Corrida.soloRuido(minutos: 10, semilla: 14)
try mezcla.escribir(en: audios.appendingPathComponent("largos"))
try ruido.escribir(en: audios.appendingPathComponent("largos"))
linea(String(format: "· largos: mezcla %.1f min, prosa %.1f min, ruido %.1f min", mezcla.segundos / 60, prosa.segundos / 60, ruido.segundos / 60))

/// Dónde termina el nombre en cada positivo, según Parakeet sobre el clip
/// entero: desde ahí se mide la latencia.
var finDelNombre: [String: Double] = [:]
for f in filas where f.clip.categoria == .positivos {
  if let fin = f.parakeet.finDelNombre { finDelNombre[f.clip.nombre] = fin }
}

struct ResultadoDeCorrida {
  var busquedas = 0
  var llamados = 0
  var aciertos = Set<String>()
  var falsas: [String] = []
  var latenciasNombre: [Double] = []
  var latenciasAviso: [Double] = []
  var primerosTurnos: [(String, String?)] = []
  var cpu = 0.0
  var segundos = 0.0
  var msInferencia = 0.0
}

@MainActor func correr(_ corrida: Corrida, detector: any DetectorDeVoz, decisor: any Decisor) async throws -> ResultadoDeCorrida {
  await detector.reiniciar()
  var r = ResultadoDeCorrida()
  r.segundos = corrida.segundos
  var ventana = VentanaDeEscucha()
  var bufer = BuferDeEscucha()
  let paso = VadManager.chunkSize
  var ultimaBusqueda: (rango: Range<Int>, b: Busqueda)?
  let cpu0 = Medida.cpu()

  func tramo(en muestra: Int) -> Corrida.Tramo? {
    corrida.tramos.first { muestra >= $0.inicio - 8_000 && muestra < $0.fin }
  }

  func anotar(_ rango: Range<Int>, texto: String?, listoEn: Double, busqueda: String) {
    r.llamados += 1
    guard let t = tramo(en: rango.lowerBound + 6_000) ?? tramo(en: rango.lowerBound) else {
      r.falsas.append("\(corrida.nombre)@\(String(format: "%.1f", Double(rango.lowerBound) / 16_000)) «\(texto ?? "")»")
      return
    }
    guard t.clip.categoria == .positivos else {
      r.falsas.append("\(t.clip.categoria.rawValue)/\(t.clip.nombre) «\(texto ?? "")»")
      return
    }
    r.aciertos.insert(t.clip.nombre)
    r.latenciasAviso.append(listoEn - Double(t.fin) / 16_000)
    // Lo mismo que hace la app (`OidoDeLaEscucha.llamar`): el nombre ya se
    // oyó en la búsqueda, y el tramo entero puede traerlo pegado o cambiado.
    let turno = texto.flatMap { reglaDilo.oir($0, exigirApartado: false)?.primerTurno ?? NombreQueDespierta.limpiar($0) }
      ?? reglaDilo.oir(busqueda)?.primerTurno
    r.primerosTurnos.append((t.clip.texto, turno))
  }

  var i = 0
  while i + paso <= corrida.muestras.count {
    let trozo = Array(corrida.muestras[i..<(i + paso)])
    bufer.agregar(trozo)
    let p = try await detector.probabilidad(trozo)
    var accion = ventana.trozo(probabilidad: p, inicio: i, fin: i + paso)
    while accion != .nada {
      switch accion {
      case let .buscarNombre(rango):
        let b = try await decisor.buscar(bufer.tramo(rango))
        r.busquedas += 1
        r.msInferencia += b.ms
        ultimaBusqueda = (rango, b)
        if b.hayNombre, let t = tramo(en: rango.lowerBound + 6_000), t.clip.categoria == .positivos,
          let fin = finDelNombre[t.clip.nombre]
        {
          // Desde el fin del nombre hasta que se sabe: el audio que faltaba
          // por llegar —hasta el trozo que disparó la búsqueda— y lo que
          // tardó el motor.
          r.latenciasNombre.append(Double(i + paso - t.inicio) / 16_000 - fin + b.ms / 1_000)
        }
        accion = ventana.resolver(hayNombre: b.hayNombre)
      case let .transcribirLlamado(rango):
        let reloj = ContinuousClock()
        var texto = ""
        let d = try await reloj.measure { texto = try await parakeet.transcribir(bufer.tramo(rango)).0 }
        // Se sabe en el trozo que cerró el silencio, más lo que tardó el motor.
        anotar(rango, texto: texto, listoEn: Double(i + paso) / 16_000 + Medida.ms(d) / 1_000, busqueda: ultimaBusqueda?.b.texto ?? "")
        accion = .nada
      case .llamarConLoBuscado:
        guard let (rango, b) = ultimaBusqueda else { accion = .nada; break }
        var texto = b.texto
        if !(decisor is DecisorParakeet) { texto = try await parakeet.transcribir(bufer.tramo(rango)).0 }
        anotar(rango, texto: texto, listoEn: Double(i + paso) / 16_000 + b.ms / 1_000, busqueda: b.texto)
        accion = .nada
      case .nada:
        break
      }
    }
    i += paso
  }
  r.cpu = Medida.cpu() - cpu0
  return r
}

let silero = DetectorSilero(manager: vad)
let energia = DetectorDeEnergia()
var tabla = "\n## Audios largos, por la ventana de la app\n\n"
tabla += "Mezcla: \(mezclables.count) clips (\(clips[.positivos]!.count) positivos) con pausas de 1,5–4 s sobre silencio, ruido blanco, ventilador y rosa; uno de cada cuatro con ventilador a 10 dB de la voz. Prosa: \(String(format: "%.0f", prosa.segundos / 60)) min sin el nombre. Ruido: 10 min de fondos y golpes, sin voz.\n\n"
tabla += "CPU: segundos de núcleo del proceso sobre la duración del audio, corriendo más rápido que el tiempo real (el trabajo por segundo de audio es el mismo). No incluye el `AVAudioEngine` del micrófono.\n\n"
tabla += "| Detector | Decide | Aciertos | Falsas en mezcla | Falsas en prosa (por hora) | Falsas en ruido | Búsquedas por hora de prosa | Latencia nombre→se sabe (mediana / p90) | Fin de lo dicho→aviso (mediana) | CPU prosa | CPU ruido |\n"
tabla += "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
var detalle = "\n## Detalle de las falsas alarmas y los primeros turnos\n\n"

func p90(_ xs: [Double]) -> Double {
  let o = xs.sorted()
  return o.isEmpty ? 0 : o[min(o.count - 1, Int(Double(o.count) * 0.9))]
}

let combinaciones: [(any DetectorDeVoz, any Decisor)] = [
  (silero, parakeet), (energia, parakeet), (silero, parakeetR0), (silero, ctc),
].filter { solo == nil || "\($0.0.nombre)+\($0.1.nombre)" == solo }
for (detector, decisor) in combinaciones {
  do {
    let m = try await correr(mezcla, detector: detector, decisor: decisor)
    let p = try await correr(prosa, detector: detector, decisor: decisor)
    let n = try await correr(ruido, detector: detector, decisor: decisor)
    let positivos = clips[.positivos]!.count
    let horas = p.segundos / 3_600
    tabla += "| \(detector.nombre) | \(decisor.nombre) | \(m.aciertos.count)/\(positivos) (\(String(format: "%.0f", 100 * Double(m.aciertos.count) / Double(positivos)))%) | \(m.falsas.count) | \(p.falsas.count) (\(String(format: "%.1f", Double(p.falsas.count) / horas))) | \(n.falsas.count) | \(String(format: "%.0f", Double(p.busquedas) / horas)) | \(String(format: "%.2f / %.2f s", mediana(m.latenciasNombre), p90(m.latenciasNombre))) | \(String(format: "%.2f s", mediana(m.latenciasAviso))) | \(String(format: "%.2f %%", 100 * p.cpu / p.segundos)) | \(String(format: "%.2f %%", 100 * n.cpu / n.segundos)) |\n"
    detalle += "### \(detector.nombre) + \(decisor.nombre)\n\n"
    detalle += "Falsas: " + (m.falsas + p.falsas + n.falsas).prefix(40).map { "`\($0)`" }.joined(separator: ", ") + "\n\n"
    let malos = m.primerosTurnos.filter { esperado, oido in
      let resto = reglaDilo.oir(esperado)?.primerTurno
      return SenalesDelTurno.plegar(resto ?? "") != SenalesDelTurno.plegar(oido ?? "")
    }
    detalle += "Primeros turnos distintos de lo dicho: \(malos.count) de \(m.primerosTurnos.count).\n\n"
    for (esperado, oido) in malos.prefix(8) { detalle += "- «\(esperado)» → «\(oido ?? "—")»\n" }
    detalle += "\n"
    linea("· \(detector.nombre)+\(decisor.nombre): \(m.aciertos.count)/\(positivos), falsas \(m.falsas.count)/\(p.falsas.count)/\(n.falsas.count), CPU prosa \(String(format: "%.2f", 100 * p.cpu / p.segundos)) %")
  }
}
ram.append(("al terminar", Medida.ramMB()))
informe += tabla + detalle
informe += "\nRAM al terminar: \(String(format: "%.0f", Medida.ramMB())) MB.\n"
try informe.write(to: salida.appendingPathComponent(nombreDelInforme), atomically: true, encoding: .utf8)
linea(tabla)

import AppKit
import DiloMetrics
import Foundation

// Mide los cinco números del spec §3 contra un `.app` ya compilado y deja el
// reporte escrito. No se llama a mano: `scripts/metrics.sh` lo construye, lo
// corre y devuelve su código de salida.

func valor(de bandera: String, en argumentos: [String]) -> String? {
  guard let indice = argumentos.firstIndex(of: bandera), indice + 1 < argumentos.count else {
    return nil
  }
  return argumentos[indice + 1]
}

let argumentos = Array(CommandLine.arguments.dropFirst())

guard let rutaDelApp = valor(de: "--app", en: argumentos) else {
  FileHandle.standardError.write(
    Data(
      """
      uso: dilo-metrics --app <ruta.app> [--salida <json>] [--tamano-de <ruta.app>]
                        [--sin-latencia] [--ci] [--reposo <s>] [--arranques <n>]

      """.utf8
    )
  )
  exit(2)
}

let ventanaDeReposo = Double(valor(de: "--reposo", en: argumentos) ?? "") ?? 60
let arranques = Int(valor(de: "--arranques", en: argumentos) ?? "") ?? 5
let mideLatencia = !argumentos.contains("--sin-latencia")
// El tamaño es el del `.app` que la gente descarga, y ése es el de Release.
// La latencia, en cambio, sólo se puede medir en Debug, porque el gancho
// DILO_METRICS_WAV no existe fuera de `#if DEBUG`. Sin esta bandera había que
// elegir cuál de los dos números decir la verdad: se mide el resto sobre el
// Debug y el tamaño sobre su gemelo Release del mismo commit.
let rutaDelTamano = valor(de: "--tamano-de", en: argumentos)
let rutaDeSalida = valor(de: "--salida", en: argumentos)
// En CI lo que el entorno no deja medir no tumba la corrida: se anota con su
// razón y se sigue. En un Mac de verdad una métrica sin medir sigue siendo un
// fallo —si no, el archivo versionado se vuelve una lista de excusas—.
let enCI = argumentos.contains("--ci") || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"

func avisar(_ texto: String) {
  FileHandle.standardError.write(Data((texto + "\n").utf8))
}

func maquina() -> String {
  let modelo = (try? Concha.correr("/usr/sbin/sysctl", ["-n", "hw.model"]).salida)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
  let so = ProcessInfo.processInfo.operatingSystemVersionString
  return "\(modelo) · \(so)"
}

do {
  let app = try Aplicacion(ruta: URL(fileURLWithPath: rutaDelApp).standardizedFileURL)
  var valores: [Metrica: Double] = [:]
  var sinMedir: [Metrica: String] = [:]
  var notas: [String] = []

  avisar("→ tamaño del bundle")
  let appDelTamano = try rutaDelTamano
    .map { try Aplicacion(ruta: URL(fileURLWithPath: $0).standardizedFileURL) } ?? app
  if appDelTamano.esBuildDebug {
    // Sin `--tamano-de` y con un Debug adelante, el número que saldría sería
    // el de un bundle que nadie descarga. Mejor no medirlo y decirlo.
    sinMedir[.tamanoDelApp] =
      "el .app es un build Debug y carga un .debug.dylib que no viaja en la descarga; "
      + "compila Release y pásalo con --tamano-de"
    notas.append("Tamaño: no se midió, el bundle es Debug.")
  } else {
    valores[.tamanoDelApp] = Double(try appDelTamano.tamanoEnBytes()) / Umbrales.bytesPorMB
    if rutaDelTamano != nil {
      notas.append(
        "Tamaño: medido sobre \(appDelTamano.ruta.path), el gemelo Release del mismo commit."
      )
    }
  }

  avisar("→ arranque en frío (\(arranques) lanzamientos)")
  var tiempos: [TimeInterval] = []
  for _ in 0..<arranques {
    app.matar()
    dormir(1)
    let (_, segundos) = try app.lanzar()
    tiempos.append(segundos)
    app.matar()
  }
  tiempos.sort()
  valores[.arranqueEnFrio] = tiempos[tiempos.count / 2]
  notas.append(
    "Arranque: mediana de \(arranques) lanzamientos "
      + "(\(tiempos.map { String(format: "%.0f", $0 * 1_000) }.joined(separator: "/")) ms). "
      + "El caché de archivos está caliente: vaciarlo exige sudo purge o un reinicio."
  )

  avisar("→ reposo: \(Int(ventanaDeReposo)) s sin dictar")
  app.matar()
  dormir(1)
  let (proceso, _) = try app.lanzar()
  let pid = proceso.processIdentifier
  valores[.cpuEnReposo] = try Reposo.cpuEnPorcentaje(pid: pid, ventana: ventanaDeReposo)
  valores[.ramEnReposo] = try Reposo.ramEnMB(pid: pid)
  app.matar()

  if mideLatencia {
    avisar("→ latencia soltar → texto (WAV inyectado)")
    let carpeta = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "dilo-metrics")
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    let wav = carpeta.appending(path: "frase-es.wav")
    let duracion = try Latencia.generarWAV(en: wav)

    dormir(1)
    let (conGancho, _) = try app.lanzar(ambiente: ["DILO_METRICS_WAV": wav.path])
    let pidConGancho = conGancho.processIdentifier
    // Arrancar no es estar listo: la app pide micrófono y reconocimiento de voz
    // y recién entonces prepara el idioma. Antes de eso el ítem del menú no
    // hace nada.
    dormir(8)
    // La primera sesión de SpeechAnalyzer carga el modelo del idioma; medir esa
    // carga sería medir el disco, no a Dilo. La primera pasada calienta.
    _ = try? Latencia.medir(pid: pidConGancho, wav: wav, duracionDelWav: duracion)
    let resultado = try Latencia.medir(pid: pidConGancho, wav: wav, duracionDelWav: duracion)
    valores[.latenciaSoltarTexto] = resultado.segundos
    notas.append("Latencia: segunda pasada, con el modelo ya cargado. Transcrito: “\(resultado.texto)”.")
    app.matar()
  } else {
    sinMedir[.latenciaSoltarTexto] =
      "disparar el dictado pide Accesibilidad y una sesión gráfica, que un runner no tiene; "
      + "se mide a mano en un Mac antes de cortar un release"
    notas.append("Latencia: no se midió (--sin-latencia).")
  }

  let reporte = Reporte(
    app: app.ruta.path,
    maquina: maquina(),
    nota: notas.joined(separator: " "),
    valores: valores,
    sinMedirEnEsteEntorno: enCI ? sinMedir : [:]
  )

  if let rutaDeSalida {
    try reporte.escribir(en: URL(fileURLWithPath: rutaDeSalida))
    avisar("→ reporte en \(rutaDeSalida)")
  }

  print("")
  print(reporte.tabla())
  print("")
  for problema in reporte.problemas { print("✗ \(problema)") }
  for (metrica, razon) in reporte.sinMedirEnEsteEntorno.sorted(by: { $0.key.titulo < $1.key.titulo }) {
    print("· \(metrica.titulo): no medible acá — \(razon). El umbral sigue vigente en un Mac.")
  }
  if !enCI {
    for (metrica, razon) in sinMedir.sorted(by: { $0.key.titulo < $1.key.titulo }) {
      print("  \(metrica.titulo): \(razon).")
    }
  }
  if reporte.cumple {
    print(
      enCI && !reporte.sinMedirEnEsteEntorno.isEmpty
        ? "Los números que este entorno puede medir se cumplen."
        : "Los cinco números del spec §3 se cumplen."
    )
    exit(0)
  }
  exit(1)
} catch {
  avisar("✗ \(error.localizedDescription)")
  exit(1)
}

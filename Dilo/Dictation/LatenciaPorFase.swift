import DiloCapabilities
import Foundation
import os

/// Los hitos de un dictado, en el orden en que pasan.
///
/// La idea de medir por hitos y fases, y no un solo número, viene de cómo lo
/// hacen otras apps de dictado (sólo la técnica). El número del spec §3
/// —soltar→texto, < 300 ms— se sigue midiendo desde afuera con
/// `scripts/metrics.sh`; esto dice **dónde** se van esos milisegundos en cada
/// dictado de verdad, sin un WAV de prueba.
enum Hito: String, Codable, CaseIterable, Sendable {
  case gatillo
  case microfonoAbierto
  case primerAudio
  case primerParcial
  case soltar
  /// El motor devolvió su texto. Se deduce de `revisado` menos lo que tardó
  /// la revisión de la toma, que la mide `MotorConRespaldo`.
  case textoDelMotor
  /// Lo que salió de `RevisionDeToma`, con la segunda opinión si hizo falta.
  case revisado
  case limpio
  case modo
  case traducido
  /// El ⌘V salió.
  case atajoEnviado
  /// La entrega contestó: con el acuse de la app de destino, o sin él.
  case entregado
}

/// Las fases que se reportan: cada una es el tramo entre dos hitos.
enum Fase: String, Codable, CaseIterable, Sendable {
  /// Gatillo → micrófono abierto.
  case activacion
  /// Micrófono abierto → primer búfer de audio.
  case primerAudio
  /// Primer búfer → primer texto en la muesca.
  case primerParcial
  /// Micrófono abierto → soltar: lo que habló la persona. No es latencia, pero
  /// sin ella los demás números no se pueden leer.
  case habla
  /// Soltar → texto del motor: la pasada final.
  case motor
  /// La revisión de la toma: tokens, fantasmas, bucles y, si no quedó texto,
  /// el otro motor.
  case revision
  case limpieza
  /// El Modelo de texto, si hubo modo; cero si no.
  case modo
  case traduccion
  /// De tener el texto final a mandar el ⌘V: la foto del portapapeles, el
  /// teclado libre, el foco.
  case pegado
  /// ⌘V → la app de destino lo leyó o el campo lo mostró.
  case acuse
  /// Soltar → entregado, con el acuse incluido.
  case total
}

/// Cómo terminó la sesión medida. Un conjunto cerrado, para poder contar
/// cuántas veces cae al portapapeles sin guardar nada del texto.
enum ResultadoMedido: String, Codable, Sendable {
  case pegado
  case sinConfirmar
  case copiado
  case retenido
  case sinTexto
  case cancelado
  /// Terminó por otro camino: una nota, una traducción que falló, un error.
  case otro

  init(_ entrega: ResultadoDeEntrega) {
    switch entrega {
    case .pegado: self = .pegado
    case .pegadoSinConfirmar: self = .sinConfirmar
    case .copiado: self = .copiado
    case .retenido: self = .retenido
    case .nadaQueEntregar: self = .sinTexto
    }
  }
}

/// Una sesión medida. **Sin texto y sin app**: el motor, si hubo modo o
/// traducción y los milisegundos por fase —cuánto se habló es la fase
/// `habla`—. La misma regla que las métricas de Actividad.
struct MedicionDeSesion: Codable, Equatable, Sendable {
  var fecha: Date
  var motor: String
  var conModo: Bool
  var traducido: Bool
  var resultado: ResultadoMedido
  /// Por `Fase.rawValue`. Una fase que no se pudo medir no está.
  var milisegundos: [String: Int]

  func ms(_ fase: Fase) -> Int? { milisegundos[fase.rawValue] }
}

/// Anota los hitos de una sesión con el reloj monótono.
///
/// Un hito marcado dos veces conserva el primero: el primer búfer es el
/// primero aunque lleguen cuarenta por segundo. Los que no pasaron se
/// rellenan para que su fase mida cero y la suma cuadre (`medicion`).
struct RelojDeFases: Sendable {
  private(set) var marcas: [Hito: ContinuousClock.Instant] = [:]
  /// Cómo terminó, si quien lo sabe lo anotó.
  var resultado: ResultadoMedido?
  var conModo = false
  var traducido = false

  private static let firmas = OSSignposter(subsystem: "cl.espaciodigital.dilo", category: "latencia")

  func instante(de hito: Hito) -> ContinuousClock.Instant? { marcas[hito] }

  mutating func marcar(_ hito: Hito, en instante: ContinuousClock.Instant = .now) {
    guard marcas[hito] == nil else { return }
    marcas[hito] = instante
    // En Instruments → os_signpost cada hito aparece sobre la línea de tiempo.
    Self.firmas.emitEvent("hito", "\(hito.rawValue, privacy: .public)")
  }

  /// Los milisegundos de cada fase que se pudo medir.
  ///
  /// Los pasos del final que no corrieron —sin modo, sin traducción— miden
  /// cero: se rellenan con el anterior. El texto del motor sin la revisión
  /// medida se rellena con el revisado, para que la revisión mida cero y no
  /// se lleve la pasada del motor. Sin ⌘V (copiar al portapapeles) no hay
  /// acuse: el pegado va hasta el final y el acuse no se reporta.
  func milisegundos() -> [Fase: Int] {
    var m = marcas
    if m[.textoDelMotor] == nil { m[.textoDelMotor] = m[.revisado] }
    var anterior = m[.revisado]
    for hito in [Hito.limpio, .modo, .traducido] {
      if m[hito] == nil { m[hito] = anterior }
      anterior = m[hito]
    }
    let huboAtajo = m[.atajoEnviado] != nil
    if !huboAtajo { m[.atajoEnviado] = m[.entregado] }

    let tramos: [(Fase, Hito, Hito)] = [
      (.activacion, .gatillo, .microfonoAbierto),
      (.primerAudio, .microfonoAbierto, .primerAudio),
      (.primerParcial, .primerAudio, .primerParcial),
      (.habla, .microfonoAbierto, .soltar),
      (.motor, .soltar, .textoDelMotor),
      (.revision, .textoDelMotor, .revisado),
      (.limpieza, .revisado, .limpio),
      (.modo, .limpio, .modo),
      (.traduccion, .modo, .traducido),
      (.pegado, .traducido, .atajoEnviado),
      (.acuse, .atajoEnviado, .entregado),
      (.total, .soltar, .entregado),
    ]
    var resultado: [Fase: Int] = [:]
    for (fase, desde, hasta) in tramos {
      if fase == .acuse, !huboAtajo { continue }
      guard let a = m[desde], let b = m[hasta] else { continue }
      resultado[fase] = max(0, Self.milisegundos(a.duration(to: b)))
    }
    return resultado
  }

  /// Si hay algo que guardar: una sesión que no llegó a abrir el micrófono
  /// no midió nada que diga algo.
  var valeLaPena: Bool { marcas[.gatillo] != nil && marcas[.microfonoAbierto] != nil }

  func medicion(motor: String, fecha: Date = .now) -> MedicionDeSesion {
    let ms = milisegundos()
    return MedicionDeSesion(
      fecha: fecha,
      motor: motor,
      conModo: conModo,
      traducido: traducido,
      resultado: resultado ?? (marcas[.soltar] == nil ? .cancelado : .otro),
      milisegundos: Dictionary(uniqueKeysWithValues: ms.map { ($0.key.rawValue, $0.value) })
    )
  }

  static func milisegundos(_ duracion: Duration) -> Int {
    let c = duracion.components
    return Int(c.seconds) * 1_000 + Int(c.attoseconds / 1_000_000_000_000_000)
  }
}

/// Las últimas sesiones medidas, y lo que se dice de ellas.
struct RegistroDeLatencias: Codable, Equatable, Sendable {
  var sesiones: [MedicionDeSesion] = []

  /// Quinientas: unas semanas de uso normal, y un archivo de unos cien KB.
  /// Más no dice nada nuevo y crece para siempre.
  static let tope = 500

  mutating func agregar(_ medicion: MedicionDeSesion) {
    sesiones.append(medicion)
    if sesiones.count > Self.tope { sesiones.removeFirst(sesiones.count - Self.tope) }
  }

  /// p50 y p95 de una fase, de las sesiones que la midieron. Con menos de
  /// cinco no se dice nada: un percentil de dos datos es un dato.
  ///
  /// El modo y la traducción, sólo de las sesiones donde corrieron: en las
  /// demás miden cero, y una mediana de ceros esconde lo que tarda un modo.
  func percentiles(_ fase: Fase, motor: String? = nil) -> (p50: Int, p95: Int)? {
    let valores = sesiones
      .filter { motor == nil || $0.motor == motor }
      .filter { fase == .modo ? $0.conModo : fase == .traduccion ? $0.traducido : true }
      .compactMap { $0.ms(fase) }
      .sorted()
    guard valores.count >= Self.minimoParaPercentiles else { return nil }
    func p(_ q: Double) -> Int {
      valores[min(valores.count - 1, Int((Double(valores.count) * q).rounded(.down)))]
    }
    return (p(0.5), p(0.95))
  }

  static let minimoParaPercentiles = 5

  /// «Exportar latencias…»: un CSV que se abre en Numbers o se adjunta a un
  /// reporte. Es lo único que sale de esta compu, y sale porque la persona lo
  /// guarda donde quiere.
  func csv() -> String {
    let columnas = Fase.allCases.map(\.rawValue)
    // Las fases llevan `_ms`: así ninguna choca con una columna de la sesión
    // —hay una fase `motor` y una fase `modo`— y la unidad viaja en el nombre.
    let cabecera = (["fecha", "motor_de_voz", "con_modo", "con_traduccion", "resultado"]
      + columnas.map { "\($0)_ms" })
      .joined(separator: ",")
    let fechas = ISO8601DateFormatter()
    let filas = sesiones.map { s in
      ([
        fechas.string(from: s.fecha),
        Self.campo(s.motor),
        s.conModo ? "si" : "no",
        s.traducido ? "si" : "no",
        s.resultado.rawValue,
      ] + columnas.map { s.milisegundos[$0].map(String.init) ?? "" })
        .joined(separator: ",")
    }
    return ([cabecera] + filas).joined(separator: "\n") + "\n"
  }

  /// Un campo de texto del CSV. El motor es un nombre conocido, pero una
  /// coma en él correría todas las columnas.
  private static func campo(_ texto: String) -> String {
    guard texto.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return texto }
    return "\"" + texto.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// Dónde vive el registro: `Application Support/Dilo/latencias.json`, al lado
/// de las métricas de Actividad. Sólo en esta compu; nada de esto se manda a
/// ningún lado. Un actor para que escribir el archivo no ocupe el main actor
/// al final de un dictado.
actor AlmacenDeLatencias {
  static var archivoPorDefecto: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Dilo", directoryHint: .isDirectory)
      .appending(path: "latencias.json")
  }

  private let archivo: URL
  private var cargado: RegistroDeLatencias?

  init(archivo: URL = AlmacenDeLatencias.archivoPorDefecto) {
    self.archivo = archivo
  }

  func registro() -> RegistroDeLatencias {
    if let cargado { return cargado }
    // Un archivo ilegible —de otra versión, o a medio escribir— se empieza
    // de cero: son mediciones, no el dictado de nadie.
    let leido = (try? Data(contentsOf: archivo))
      .flatMap { try? Self.decodificador().decode(RegistroDeLatencias.self, from: $0) }
      ?? RegistroDeLatencias()
    cargado = leido
    return leido
  }

  func agregar(_ medicion: MedicionDeSesion) {
    var registro = registro()
    registro.agregar(medicion)
    cargado = registro
    do {
      try FileManager.default.createDirectory(
        at: archivo.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try Self.codificador().encode(registro).write(to: archivo, options: .atomic)
    } catch {
      // Una medición que no se guarda no le cuesta nada al dictado.
      Logger(subsystem: "cl.espaciodigital.dilo", category: "latencia")
        .error("no se pudo guardar la latencia: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func codificador() -> JSONEncoder {
    let codificador = JSONEncoder()
    codificador.dateEncodingStrategy = .iso8601
    return codificador
  }

  private static func decodificador() -> JSONDecoder {
    let decodificador = JSONDecoder()
    decodificador.dateDecodingStrategy = .iso8601
    return decodificador
  }
}

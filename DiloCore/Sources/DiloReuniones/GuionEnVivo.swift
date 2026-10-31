import Foundation

/// Una línea del guion en vivo: lo que una **Pista** dijo en un tramo. Sin
/// hablante: en vivo sólo se sabe de qué pista vino, quién fue dentro de
/// `ellos` lo decide la pasada final.
public struct LineaEnVivo: Sendable, Equatable, Identifiable {
  public var id: Int
  public var pista: Pista
  /// Segundos desde que empezó la reunión.
  public var desde: Double
  public var hasta: Double
  public var texto: String
  /// Todavía se está diciendo: el texto puede cambiar.
  public var abierta: Bool

  public init(id: Int, pista: Pista, desde: Double, hasta: Double, texto: String, abierta: Bool) {
    self.id = id
    self.pista = pista
    self.desde = desde
    self.hasta = hasta
    self.texto = texto
    self.abierta = abierta
  }
}

/// Lo que `TranscripcionEnVivo` cuenta.
public enum NovedadEnVivo: Sendable, Equatable {
  case linea(LineaEnVivo)
  /// La línea era ruido o quedó sin texto.
  case quitar(id: Int)
  /// La reunión terminó con esta línea abierta.
  case cerrar(id: Int)
  /// No hay modelo de voz: el vivo no va a salir, el audio sigue grabándose.
  case sinMotor
}

/// El guion en vivo, ordenado por cuándo empezó cada línea: las dos pistas se
/// intercalan aunque un tramo largo de una termine después de que la otra
/// contestó. Vive en RAM mientras dura la reunión; el registro es `guion.jsonl`.
public struct GuionEnVivo: Sendable, Equatable {
  public private(set) var lineas: [LineaEnVivo] = []
  public private(set) var sinMotor = false

  public init() {}

  public mutating func aplicar(_ novedad: NovedadEnVivo) {
    switch novedad {
    case let .linea(linea): poner(linea)
    case let .quitar(id): lineas.removeAll { $0.id == id }
    case let .cerrar(id):
      if let i = lineas.firstIndex(where: { $0.id == id }) { lineas[i].abierta = false }
    case .sinMotor: sinMotor = true
    }
  }

  private mutating func poner(_ linea: LineaEnVivo) {
    if let i = lineas.firstIndex(where: { $0.id == linea.id }) {
      // Los avisos saltan de hilo uno por uno: un parcial atrasado no reabre
      // una línea que ya quedó firme.
      guard lineas[i].abierta else { return }
      lineas[i] = linea
      return
    }
    let posicion = lineas.lastIndex { $0.desde <= linea.desde }.map { $0 + 1 } ?? 0
    lineas.insert(linea, at: posicion)
  }
}

/// Lo que la ventana muestra mientras graba: lo dicho y tus notas, en orden.
public enum ElementoEnVivo: Sendable, Equatable, Identifiable {
  /// `conCabecera`: dice quién habla. La misma pista seguida no lo repite.
  case linea(LineaEnVivo, conCabecera: Bool)
  case nota(NotaDeLaReunion)

  public var id: String {
    switch self {
    case let .linea(linea, _): "l\(linea.id)"
    case let .nota(nota): "n\(nota.en)"
    }
  }

  public static func armar(lineas: [LineaEnVivo], notas: [NotaDeLaReunion]) -> [ElementoEnVivo] {
    var salida: [ElementoEnVivo] = []
    var deLinea = lineas[...]
    var deNota = notas.sorted { $0.en < $1.en }[...]
    var anterior: LineaEnVivo?
    while let linea = deLinea.first {
      if let nota = deNota.first, nota.en < linea.desde {
        salida.append(.nota(nota))
        deNota = deNota.dropFirst()
        anterior = nil
        continue
      }
      let seguida = anterior.map {
        $0.pista == linea.pista && linea.desde - $0.hasta <= LineasDelGuion.pausaQueParte
      } ?? false
      salida.append(.linea(linea, conCabecera: !seguida))
      deLinea = deLinea.dropFirst()
      anterior = linea
    }
    return salida + deNota.map(ElementoEnVivo.nota)
  }
}

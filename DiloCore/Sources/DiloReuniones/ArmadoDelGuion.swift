import Foundation

/// Una palabra como la devuelve el **Motor de voz** sobre el WAV de una pista:
/// segundos locales, contados desde la primera muestra de la pista.
public struct PalabraDeLaPista: Sendable, Equatable {
  public var texto: String
  public var desde: Double
  public var hasta: Double

  public init(texto: String, desde: Double, hasta: Double) {
    self.texto = texto
    self.desde = desde
    self.hasta = hasta
  }
}

/// Junta lo que salió de la pasada final en las palabras del guion y sus
/// hablantes (spec, «Pipeline»):
///
/// 1. `ellos`: a cada palabra, el hablante con más actividad en su tramo.
/// 2. Los hablantes se numeran por orden de llegada: «Hablante 2», «3»…
/// 3. `yo` es Yo, sin modelo.
/// 4. Todo pasa al reloj de la reunión por las anclas, y se intercala.
/// 5. Se marca lo dictado y, con parlantes, el eco.
///
/// Puro: lo prueban `swift test` y el banco de la Fase 0 con el mismo código.
public enum ArmadoDelGuion {
  public struct Resultado: Sendable, Equatable {
    public var palabras: [PalabraDelGuion]
    public var hablantes: [Hablante]
  }

  /// Hasta dónde se le presta el hablante de la palabra vecina a una palabra
  /// de `ellos` que quedó sin nadie: una palabra suelta en una pausa del
  /// diarizador casi siempre es de quien venía hablando.
  public static let prestamoMaximo: Double = 3

  public static func armar(
    yo: [PalabraDeLaPista],
    ellos: [PalabraDeLaPista],
    actividad: ActividadDeHablantes?,
    relojes: [AnclaDeReloj],
    reunion: Reunion
  ) -> Resultado {
    // Antes que nada: un bucle del modelo no es habla de nadie.
    let yo = BuclesDeLaPista.colapsar(yo)
    let ellos = BuclesDeLaPista.colapsar(ellos)
    let alineacion = AlineacionDeRelojes(relojes)
    let atribuidas = atribuir(ellos, actividad: actividad)
    let numeros = numerarPorLlegada(atribuidas.map(\.indice))

    var palabras: [PalabraDelGuion] = []
    palabras.reserveCapacity(yo.count + ellos.count)
    for palabra in yo {
      palabras.append(
        PalabraDelGuion(
          pista: .yo, hablante: Hablante.yo.id,
          desde: alineacion.segundos(local: palabra.desde, pista: .yo),
          hasta: alineacion.segundos(local: palabra.hasta, pista: .yo),
          texto: palabra.texto
        )
      )
    }
    for (palabra, atribucion) in zip(ellos, atribuidas) {
      var nueva = PalabraDelGuion(
        pista: .ellos,
        hablante: atribucion.indice.flatMap { numeros[$0] }.map(Hablante.id(numero:)),
        desde: alineacion.segundos(local: palabra.desde, pista: .ellos),
        hasta: alineacion.segundos(local: palabra.hasta, pista: .ellos),
        texto: palabra.texto
      )
      if atribucion.solape { nueva.marcar(.solape) }
      palabras.append(nueva)
    }
    palabras.sort { $0.desde == $1.desde ? $0.pista == .yo && $1.pista == .ellos : $0.desde < $1.desde }

    LimpiezaDelGuion.marcarDictado(&palabras, tramos: reunion.dictados)
    if reunion.salida.pideFiltroDeEco { LimpiezaDelGuion.marcarEco(&palabras) }

    return Resultado(palabras: palabras, hablantes: hablantes(numeros: numeros, reunion: reunion))
  }

  /// El hablante de una palabra de `ellos`, por índice del diarizador.
  public struct Atribucion: Sendable, Equatable {
    public var indice: Int?
    public var solape: Bool
  }

  /// El hablante de cada palabra de `ellos`, por índice del diarizador. Sin
  /// diarizador —falló, o no había modelo— todas son de una misma voz: el
  /// guion sigue saliendo, con «Hablante 2» para todo lo de la llamada. Es
  /// público para que el banco de la Fase 0 mida exactamente esto.
  public static func atribuir(_ ellos: [PalabraDeLaPista], actividad: ActividadDeHablantes?) -> [Atribucion] {
    guard let actividad else { return ellos.map { _ in Atribucion(indice: 0, solape: false) } }
    var salida = ellos.map { palabra in
      let r = AtribucionDeHablantes.hablante(desde: palabra.desde, hasta: palabra.hasta, en: actividad)
      return Atribucion(indice: r.hablante, solape: r.solape)
    }
    // Las que quedaron sin nadie toman a la vecina más cercana en el tiempo,
    // si está a menos de `prestamoMaximo`.
    let conHablante = salida.indices.filter { salida[$0].indice != nil }
    guard !conHablante.isEmpty else {
      // El diarizador no vio a nadie en toda la pista: una sola voz.
      return ellos.map { _ in Atribucion(indice: 0, solape: false) }
    }
    for i in salida.indices where salida[i].indice == nil {
      let antes = conHablante.last { $0 < i }
      let despues = conHablante.first { $0 > i }
      let distanciaAntes = antes.map { ellos[i].desde - ellos[$0].hasta } ?? .infinity
      let distanciaDespues = despues.map { ellos[$0].desde - ellos[i].hasta } ?? .infinity
      if distanciaAntes <= distanciaDespues, distanciaAntes <= prestamoMaximo, let antes {
        salida[i].indice = salida[antes].indice
      } else if distanciaDespues <= prestamoMaximo, let despues {
        salida[i].indice = salida[despues].indice
      }
    }
    return salida
  }

  /// Índice del diarizador → número de hablante, por orden de primera
  /// palabra. Nemotron ya ordena por llegada, pero un índice que no se quedó
  /// con ninguna palabra no debe gastar un número.
  static func numerarPorLlegada(_ indices: [Int?]) -> [Int: Int] {
    var numeros: [Int: Int] = [:]
    for case let indice? in indices where numeros[indice] == nil {
      numeros[indice] = numeros.count + 2
    }
    return numeros
  }

  /// Yo y los de `ellos`, con los nombres que ya tenían. En 1:1 confirmado por
  /// el calendario —un solo otro asistente y una sola voz— el otro sale con
  /// su nombre sin que nadie toque nada (spec, «Quién habló»).
  static func hablantes(numeros: [Int: Int], reunion: Reunion) -> [Hablante] {
    var hablantes = [reunion.hablante(Hablante.yo.id) ?? .yo]
    for numero in numeros.values.sorted() {
      let id = Hablante.id(numero: numero)
      hablantes.append(reunion.hablante(id) ?? Hablante(id: id, pista: .ellos))
    }
    let deEllos = hablantes.filter { $0.pista == .ellos }
    if deEllos.count == 1, deEllos[0].nombre == nil,
      let asistentes = reunion.evento?.asistentes, asistentes.count == 1,
      let indice = hablantes.firstIndex(where: { $0.pista == .ellos })
    {
      hablantes[indice].nombre = asistentes[0]
    }
    return hablantes
  }
}

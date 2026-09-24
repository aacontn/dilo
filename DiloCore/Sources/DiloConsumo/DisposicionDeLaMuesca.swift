/// A cuál de los dos costados de la muesca va un dato.
///
/// El `rawValue` es lo que se guarda en Ajustes: no se renombra.
public enum CostadoDeLaMuesca: String, CaseIterable, Sendable {
  case izquierdo
  case derecho

  public var otro: CostadoDeLaMuesca {
    self == .izquierdo ? .derecho : .izquierdo
  }
}

/// Qué fuentes están encendidas y a qué costado va cada una.
///
/// Nace de la sección «Datos en la muesca» de Ajustes (2026-09-23): una
/// tarjeta por fuente, cada una con su interruptor y su costado. Antes eran
/// dos pickers —izquierda, derecha—, que no decían de dónde salía cada dato
/// ni dejaban encender uno sin pisar otro.
///
/// **Lo que no cabe se dice, no se recorta en silencio.** Cada costado lleva
/// `porCostado` datos —lo que admite `HUDNotchGeometry.anchoDeUnLado`—, y las
/// elecciones se guardan en el orden en que se encendieron: el que llegó
/// primero a un costado se queda, y el que llega después queda esperando con
/// un aviso en su tarjeta. Si el primero se apaga, el que esperaba pasa a
/// verse solo, sin volver a tocar nada.
public struct DisposicionDeLaMuesca: Equatable, Sendable {
  public struct Eleccion: Equatable, Sendable {
    public var dato: DatoDeLaMuesca
    public var costado: CostadoDeLaMuesca

    public init(dato: DatoDeLaMuesca, costado: CostadoDeLaMuesca) {
      self.dato = dato
      self.costado = costado
    }
  }

  /// Cuántos datos caben en un costado. Uno: una etiqueta y un número
  /// («Codex 35%») en los 72 puntos que la muesca se alarga a cada lado.
  public static let porCostado = 1

  /// Lo encendido, en el orden en que se encendió.
  public private(set) var elecciones: [Eleccion]

  public init(elecciones: [Eleccion] = []) {
    var vistas = Set<DatoDeLaMuesca>()
    self.elecciones = elecciones.filter { $0.dato != .ninguno && vistas.insert($0.dato).inserted }
  }

  // MARK: Guardar

  /// Lo que se guarda en `UserDefaults`: «claude:izquierdo,cpu:derecho».
  public var guardado: String {
    elecciones.map { "\($0.dato.rawValue):\($0.costado.rawValue)" }.joined(separator: ",")
  }

  /// Lee lo guardado. Un pedazo que no se entiende —un dato que ya no existe,
  /// un costado mal escrito— se salta y el resto se conserva.
  public init(guardado: String) {
    let elecciones = guardado.split(separator: ",").compactMap { pedazo -> Eleccion? in
      let partes = pedazo.split(separator: ":")
      guard partes.count == 2,
        let dato = DatoDeLaMuesca(rawValue: String(partes[0])),
        let costado = CostadoDeLaMuesca(rawValue: String(partes[1]))
      else { return nil }
      return Eleccion(dato: dato, costado: costado)
    }
    self.init(elecciones: elecciones)
  }

  /// La elección de antes de la sección propia: un picker por costado.
  /// Se lee una vez, al arrancar, para que nadie pierda lo que ya tenía.
  public static func migrada(izquierdo: DatoDeLaMuesca, derecho: DatoDeLaMuesca) -> Self {
    DisposicionDeLaMuesca(elecciones: [
      Eleccion(dato: izquierdo, costado: .izquierdo),
      Eleccion(dato: derecho, costado: .derecho),
    ])
  }

  // MARK: Cambiar

  /// El costado de un dato encendido, o nil si está apagado.
  public func costado(de dato: DatoDeLaMuesca) -> CostadoDeLaMuesca? {
    elecciones.first { $0.dato == dato }?.costado
  }

  /// Enciende un dato. Sin costado elegido va al primero que tenga lugar
  /// —el izquierdo si los dos lo tienen, o si ninguno—.
  public mutating func encender(
    _ dato: DatoDeLaMuesca,
    en costado: CostadoDeLaMuesca? = nil,
    disponible: (DatoDeLaMuesca) -> Bool = { _ in true }
  ) {
    guard dato != .ninguno, self.costado(de: dato) == nil else { return }
    let destino = costado
      ?? CostadoDeLaMuesca.allCases.first { visibles(en: $0, disponible: disponible).count < Self.porCostado }
      ?? .izquierdo
    elecciones.append(Eleccion(dato: dato, costado: destino))
  }

  public mutating func apagar(_ dato: DatoDeLaMuesca) {
    elecciones.removeAll { $0.dato == dato }
  }

  /// Cambia un dato de costado. Entra **al final** de la fila de ese costado:
  /// lo que ya estaba ahí no se desplaza por mover otra cosa.
  public mutating func mover(_ dato: DatoDeLaMuesca, a costado: CostadoDeLaMuesca) {
    guard let actual = self.costado(de: dato), actual != costado else { return }
    apagar(dato)
    elecciones.append(Eleccion(dato: dato, costado: costado))
  }

  // MARK: Qué se ve

  /// Lo que se ve en un costado: los primeros `porCostado` encendidos que este
  /// anfitrión puede leer. Un dato que el anfitrión no admite —Claude o Codex
  /// en App Store— no ocupa lugar.
  public func visibles(
    en costado: CostadoDeLaMuesca,
    disponible: (DatoDeLaMuesca) -> Bool = { _ in true }
  ) -> [DatoDeLaMuesca] {
    Array(
      elecciones
        .filter { $0.costado == costado && disponible($0.dato) }
        .map(\.dato)
        .prefix(Self.porCostado)
    )
  }

  /// El dato de un costado, o `.ninguno`: lo que la muesca dibuja.
  public func dato(
    en costado: CostadoDeLaMuesca,
    disponible: (DatoDeLaMuesca) -> Bool = { _ in true }
  ) -> DatoDeLaMuesca {
    visibles(en: costado, disponible: disponible).first ?? .ninguno
  }

  /// Si un dato encendido no cabe, quién le ocupa el lugar. Nil si cabe o si
  /// está apagado.
  public func quienOcupa(
    elLugarDe dato: DatoDeLaMuesca,
    disponible: (DatoDeLaMuesca) -> Bool = { _ in true }
  ) -> DatoDeLaMuesca? {
    guard let costado = costado(de: dato), disponible(dato) else { return nil }
    let visibles = visibles(en: costado, disponible: disponible)
    guard !visibles.contains(dato) else { return nil }
    return visibles.first
  }
}

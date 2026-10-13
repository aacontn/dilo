import CoreGraphics
import DiloCapabilities

/// Teclear un dictado, para el reintento cuando el ⌘V no entró.
///
/// Los eventos los arma `AtajoSimulado`, como toda tecla que Dilo aprieta:
/// llevan la marca de Dilo y dejan los modificadores como los encontraron.
enum TecleoSimulado {
  /// Crea todos los eventos antes de publicar el primero, por la misma razón
  /// que `AtajoSimulado.publicar`: si uno falla a mitad de camino, mejor no
  /// haber escrito nada que haber escrito la mitad.
  ///
  /// - Returns: false si no se tecleó nada.
  @MainActor
  static func teclear(
    _ pedazos: [TecleoDelDictado.Pedazo],
    crear: (AtajoSimulado.Pulsacion) -> CGEvent?,
    publicar: (CGEvent) -> Void,
    dormir: (Duration) async throws -> Void
  ) async -> Bool {
    var grupos: [[CGEvent]] = []
    for pedazo in pedazos {
      var eventos: [CGEvent] = []
      for pulsacion in AtajoSimulado.pulsaciones(deTecleo: pedazo) {
        guard let evento = crear(pulsacion) else { return false }
        eventos.append(evento)
      }
      grupos.append(eventos)
    }
    guard !grupos.isEmpty else { return false }
    for (indice, grupo) in grupos.enumerated() {
      grupo.forEach(publicar)
      guard indice < grupos.count - 1 else { break }
      // Cancelado a mitad: lo ya tecleado se queda, y se informa como
      // tecleado para que el veredicto del campo diga qué entró.
      do { try await dormir(TecleoDelDictado.pausa) } catch { return true }
    }
    return true
  }

  /// Los eventos de verdad, desde la fuente del teclado físico, como los del
  /// atajo.
  @MainActor
  static func teclear(_ pedazos: [TecleoDelDictado.Pedazo], por canal: CanalDelAtajo) async -> Bool {
    let fuente = CGEventSource(stateID: .hidSystemState)
    return await teclear(
      pedazos,
      crear: { AtajoSimulado.evento($0, fuente: fuente) },
      publicar: canal.publicar,
      dormir: { try await Task.sleep(for: $0) }
    )
  }
}

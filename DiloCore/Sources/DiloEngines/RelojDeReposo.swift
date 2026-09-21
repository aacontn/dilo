import Foundation

/// El reloj con el que un motor cuenta el reposo antes de soltar su modelo.
///
/// Es una costura y no un `Task.sleep` suelto para que la regla —cinco
/// minutos sin dictar y el modelo se va de la RAM— se pruebe en milisegundos
/// en vez de en cinco minutos.
public protocol RelojDeReposo: Sendable {
  /// Espera `intervalo`. Lanza si la espera se cancela.
  func dormir(_ intervalo: Duration) async throws
}

/// El reloj de verdad. Cuenta en tiempo continuo a propósito: una siesta del
/// Mac no le regala al modelo cinco minutos más de RAM.
public struct RelojDelSistema: RelojDeReposo {
  public init() {}

  public func dormir(_ intervalo: Duration) async throws {
    try await Task.sleep(for: intervalo, clock: .continuous)
  }
}

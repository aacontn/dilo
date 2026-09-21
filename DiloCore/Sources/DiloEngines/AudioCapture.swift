import Foundation

/// De dónde saca el audio un motor que no trae el suyo.
///
/// Existe para que `ParakeetEngine` no vuelva a escribir la captura de
/// micrófono que Talkify ya tiene resuelta —con la recuperación de cambio de
/// ruta de los audífonos Bluetooth, que costó cara— y para que los tests
/// puedan alimentarlo con un WAV en vez de una sala.
public protocol AudioCapture: Sendable {
  /// Arranca la captura en `sampleRate` Hz, mono, Float32.
  ///
  /// `muestras` llega desde el hilo de audio: lo que se haga adentro tiene
  /// que ser barato.
  func iniciar(
    sampleRate: Double,
    muestras: @escaping @Sendable ([Float]) -> Void,
    nivel: @escaping @Sendable (Float) -> Void,
    falla: @escaping @Sendable (String) -> Void
  ) throws

  func detener()
}

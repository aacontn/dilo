import Foundation
import Synchronization
import os

/// Cuándo un ping al hilo principal cuenta como cuelgue. Puro, para que la
/// regla se pruebe sin colgar nada.
///
/// Un ping sale cada `cadencia` desde otro hilo y anota cuánto tardó el
/// principal en atenderlo. Más de `umbral` es un cuelgue que se nota: la
/// ventana no responde un tercio de segundo. Mientras un ping espera no sale
/// otro, así que un cuelgue de dos segundos deja **una** línea que dice dos
/// segundos, no ocho que dicen 250 ms.
struct UmbralDeCuelgue: Equatable {
  var cadencia: Duration = .milliseconds(250)
  var umbral: Duration = .milliseconds(300)

  func esCuelgue(_ demora: Duration) -> Bool {
    demora > umbral
  }

  /// Los milisegundos que van al log, redondeados: el log se lee de un
  /// vistazo y los decimales no dicen nada a esta escala.
  static func milisegundos(_ demora: Duration) -> Int {
    let (segundos, atto) = demora.components
    return Int(segundos) * 1000 + Int(atto / 1_000_000_000_000_000)
  }
}

#if DEBUG
  /// El vigilante de cuelgues de Ajustes, sólo en Debug.
  ///
  /// Nace del congelamiento del 2026-10-19: leyendo el código se encontraron
  /// el Llavero en el `body` de Modos, las voces de Leer en voz alta y la HAL
  /// en el hilo principal, pero lo que no se ve leyendo sólo se caza
  /// midiendo. Con Ajustes abierto, un hilo de fondo le manda un ping al
  /// principal cada 250 ms; si tarda más de 300 ms, una línea en
  /// `log stream --predicate 'subsystem == "cl.espaciodigital.dilo" &&
  /// category == "ajustes"'` dice cuánto y en qué sección estaba la ventana.
  /// Con la ventana cerrada no corre.
  final class VigiaDeCuelgues: Sendable {
    let regla: UmbralDeCuelgue
    /// La sección a la vista cuando el ping vuelve. Se pregunta en el hilo
    /// principal, que es donde vive.
    private let seccion: @MainActor @Sendable () -> String
    private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.vigia-de-cuelgues", qos: .utility)
    private let estado = Mutex<(reloj: DispatchSourceTimer?, enCamino: Bool)>((nil, false))

    init(
      regla: UmbralDeCuelgue = UmbralDeCuelgue(),
      seccion: @escaping @MainActor @Sendable () -> String
    ) {
      self.regla = regla
      self.seccion = seccion
    }

    func empezar() {
      let reloj = DispatchSource.makeTimerSource(queue: cola)
      let cadencia = UmbralDeCuelgue.milisegundos(regla.cadencia)
      reloj.schedule(deadline: .now() + .milliseconds(cadencia), repeating: .milliseconds(cadencia))
      reloj.setEventHandler { [weak self] in self?.ping() }
      let anterior = estado.withLock { estado in
        defer { estado.reloj = reloj }
        return estado.reloj
      }
      anterior?.cancel()
      reloj.resume()
    }

    func parar() {
      estado.withLock { estado in
        estado.reloj?.cancel()
        estado.reloj = nil
      }
    }

    deinit { parar() }

    private func ping() {
      let yaHayUno = estado.withLock { estado in
        defer { estado.enCamino = true }
        return estado.enCamino
      }
      guard !yaHayUno else { return }
      let salida = ContinuousClock.now
      DispatchQueue.main.async { [self] in
        let demora = ContinuousClock.now - salida
        estado.withLock { $0.enCamino = false }
        guard regla.esCuelgue(demora) else { return }
        let donde = MainActor.assumeIsolated { seccion() }
        let ms = UmbralDeCuelgue.milisegundos(demora)
        AppLog.ajustes.notice(
          "cuelgue del hilo principal: \(ms, privacy: .public) ms con Ajustes en \(donde, privacy: .public)"
        )
      }
    }
  }
#endif

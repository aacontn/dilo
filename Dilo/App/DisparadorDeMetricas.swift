#if DEBUG
import Foundation
import os

/// Cómo `scripts/metrics.sh` empieza y para un dictado para medir
/// «soltar → texto», ahora que el ícono de la barra no tiene menú.
///
/// Hasta la 0.4.8 la medición apretaba «Empezar a dictar» en el menú de la
/// barra por AppleScript y leía el nombre de ese ítem para saber si había
/// sesión. Desde que el menú es un panel de SwiftUI (2026-10-15) ese ítem no
/// existe, y apuntar un AppleScript a los botones de una vista es apostar a
/// cómo SwiftUI los expone a Accesibilidad. Esto lo reemplaza por algo que no
/// depende de la interfaz: una notificación distribuida para alternar el
/// dictado —la misma puerta que el menú, `toggleFromMenu`— y un archivo al
/// lado del WAV que dice si hay sesión.
///
/// **Sólo existe en Debug y sólo escucha con `DILO_METRICS_WAV` puesto**,
/// igual que el gancho del micrófono (`EntradaWAVDeMetricas`): una copia de
/// Release no tiene este archivo, y una Debug abierta a mano no escucha.
/// De paso, el terminal que corre la medición ya no necesita Accesibilidad
/// para disparar.
///
/// El nombre de la notificación y la ruta del archivo tienen que coincidir
/// con `Latencia` en `DiloMetrics`.
@MainActor
final class DisparadorDeMetricas {
  /// Lo que hace la notificación. Lo cablea `AppDelegate`.
  var alternar: (() -> Void)?

  private let marcaDeEstado: URL?
  private var observador: (any NSObjectProtocol)?
  private static let log = Logger(subsystem: "cl.espaciodigital.dilo", category: "metricas")

  nonisolated static func nombre(paraElBundle id: String?) -> Notification.Name {
    Notification.Name("\(id ?? "cl.espaciodigital.dilo").debug.metricas")
  }

  /// Lo que la notificación lleva como objeto para alternar el dictado.
  nonisolated static let ordenDeAlternar = "alternar"

  init(ambiente: [String: String] = ProcessInfo.processInfo.environment) {
    marcaDeEstado = ambiente[EntradaWAVDeMetricas.variable].map {
      URL(fileURLWithPath: $0 + ".estado")
    }
  }

  func escuchar(bundle: String? = Bundle.main.bundleIdentifier) {
    guard let marcaDeEstado else { return }
    anotar(dictando: false)
    let nombre = Self.nombre(paraElBundle: bundle)
    observador = DistributedNotificationCenter.default().addObserver(
      forName: nombre, object: nil, queue: .main
    ) { [weak self] aviso in
      guard aviso.object as? String == Self.ordenDeAlternar else { return }
      MainActor.assumeIsolated { self?.alternar?() }
    }
    Self.log.notice(
      "Métricas: escuchando en \(nombre.rawValue, privacy: .public); estado en \(marcaDeEstado.lastPathComponent, privacy: .public)"
    )
  }

  /// Deja escrito si hay sesión: «dictando» o «listo».
  func anotar(dictando: Bool) {
    guard let marcaDeEstado else { return }
    try? (dictando ? "dictando" : "listo").write(to: marcaDeEstado, atomically: true, encoding: .utf8)
  }
}
#endif

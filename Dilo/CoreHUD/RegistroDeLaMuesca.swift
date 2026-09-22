import CoreGraphics
import Foundation
import os

/// Qué tamaño tiene la forma, en qué ventana está y en qué pantalla, cada vez
/// que la muesca cambia de estado.
///
/// Existe porque la muesca se rompió justo donde nadie podía mirarla. El
/// render fuera de pantalla dibujaba la silueta suelta y salía impecable
/// mientras la app real la estiraba al alto de la ventana anfitriona, y la
/// única forma de verlo era pedirle a Alfonso que mirara su monitor. Una línea
/// por cambio de estado con los dos tamaños al lado convierte eso en un dato
/// que se lee sin tocar la GUI:
///
///     log show --predicate 'subsystem == "cl.espaciodigital.dilo"' --last 5m
///
/// En Debug siempre; en Release sólo con `DILO_LOG_MUESCA=1`. El escenario es
/// permanente y cambia de estado cuatro veces por dictado: una línea por
/// cambio no se le cobra a quien nada más está usando la app.
///
/// Nada de lo que se dicta pasa por acá (regla de `AppLog`): números, un
/// nombre de estado y el nombre que macOS le da al monitor.
enum RegistroDeLaMuesca {
  private static let log = Logger(subsystem: "cl.espaciodigital.dilo", category: "muesca")

  /// Si estas líneas se escriben en esta ejecución.
  static let activo: Bool = {
    #if DEBUG
      return true
    #else
      return ProcessInfo.processInfo.environment["DILO_LOG_MUESCA"] == "1"
    #endif
  }()

  /// La línea, armada aparte de escribirla: así un test la puede afirmar sin
  /// leer el log del sistema.
  static func linea(
    estado: EstadoDelNotch,
    ventana: CGSize,
    forma: CGSize,
    pantalla: String,
    notchReal: Bool
  ) -> String {
    "estado=\(estado.nombreEnElLog)"
      + " ventana=\(medida(ventana))"
      + " forma=\(medida(forma))"
      + " pantalla=\(pantalla.isEmpty ? "?" : pantalla)"
      + " notchReal=\(notchReal)"
  }

  static func anotar(
    estado: EstadoDelNotch,
    ventana: CGSize,
    forma: CGSize,
    pantalla: String,
    notchReal: Bool
  ) {
    guard activo else { return }
    let linea = linea(
      estado: estado,
      ventana: ventana,
      forma: forma,
      pantalla: pantalla,
      notchReal: notchReal
    )
    // `notice` y no `info`: los `info` no se persisten salvo que alguien haya
    // encendido el nivel a mano, así que `log show --last 5m` volvía vacío y
    // el registro no servía para lo único que existe —diagnosticar la forma
    // sin mirar la pantalla de nadie—. El gasto lo acota `activo`: cuatro
    // líneas por dictado, y en Release sólo con `DILO_LOG_MUESCA=1`.
    //
    // Público entero: es lo que hace que `log show` lo muestre en vez de
    // `<private>`, y no hay nada acá que no se pueda leer.
    log.notice("\(linea, privacy: .public)")
  }

  /// `488x190`, en puntos enteros. La `x` es una equis y no un `×`: un
  /// predicado de `log show` se escribe a mano en un terminal.
  private static func medida(_ tamaño: CGSize) -> String {
    "\(Int(tamaño.width.rounded()))x\(Int(tamaño.height.rounded()))"
  }
}

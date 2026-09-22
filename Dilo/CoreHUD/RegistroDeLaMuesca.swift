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
/// En Debug siempre; en Release hay que encenderlo, y **cómo** se enciende es
/// media razón por la que este registro salió mudo la primera vez. La
/// condición era sólo `DILO_LOG_MUESCA=1` en el entorno del proceso, y una app
/// que se abre desde el Finder, desde el Dock o con `open -a` no hereda el
/// entorno de ningún terminal: la variable se exportaba, la app arrancaba sin
/// ella y `log show` volvía vacío para siempre. Por eso el interruptor de
/// verdad es un ajuste, que sí llega a una app de escritorio:
///
///     defaults write cl.espaciodigital.dilo DILO_LOG_MUESCA -bool YES
///
/// La variable de entorno se acepta igual, para el build que se lanza desde
/// Xcode o desde el terminal.
///
/// El escenario es permanente y cambia de estado cuatro veces por dictado: una
/// línea por cambio, más una al arrancar, no se le cobra a quien nada más está
/// usando la app.
///
/// Nada de lo que se dicta pasa por acá (regla de `AppLog`): números, un
/// nombre de estado y el nombre que macOS le da al monitor.
enum RegistroDeLaMuesca {
  private static let log = Logger(subsystem: "cl.espaciodigital.dilo", category: "muesca")

  /// El nombre del interruptor, uno solo para la variable de entorno y para el
  /// ajuste: dos nombres para lo mismo es el que no está escrito en la página
  /// que uno leyó.
  static let interruptor = "DILO_LOG_MUESCA"

  /// Si este build lleva el registro encendido de fábrica.
  static let enDebug: Bool = {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }()

  /// Si estas líneas se escriben, dado cómo se compiló y cómo se lanzó.
  ///
  /// Puro y con las tres entradas afuera para poder afirmarlo: el gating es
  /// exactamente lo que dejó el registro mudo, y con la decisión adentro de un
  /// `static let` no había forma de probar la rama de Release sin compilar
  /// dos veces.
  static func dejaPasar(
    debug: Bool,
    entorno: [String: String],
    ajustes: UserDefaults?
  ) -> Bool {
    if debug { return true }
    if let valor = entorno[interruptor], encendido(valor) { return true }
    return ajustes?.bool(forKey: interruptor) ?? false
  }

  /// Qué cuenta como encendido en la variable de entorno. Más de una forma a
  /// propósito: quien escribe `DILO_LOG_MUESCA=true` no está pidiendo otra
  /// cosa que quien escribe `1`, y descubrir que no era la palabra correcta
  /// cuesta la misma tarde que descubrir que la variable no llegaba.
  private static func encendido(_ valor: String) -> Bool {
    ["1", "true", "yes", "si", "sí"].contains(
      valor.trimmingCharacters(in: .whitespaces).lowercased()
    )
  }

  /// Si estas líneas se escriben en esta ejecución.
  static let activo = dejaPasar(
    debug: enDebug,
    entorno: ProcessInfo.processInfo.environment,
    ajustes: .standard
  )

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

  /// La línea del arranque: qué muesca quedó montada al despertar, antes de
  /// que nadie dicte. Se distingue de las demás por el prefijo, que es lo que
  /// deja preguntarle al log «¿llegó a montarse?» sin leerlo entero.
  static func lineaDelArranque(
    estado: EstadoDelNotch,
    ventana: CGSize,
    forma: CGSize,
    pantalla: String,
    notchReal: Bool
  ) -> String {
    "arranque "
      + linea(
        estado: estado,
        ventana: ventana,
        forma: forma,
        pantalla: pantalla,
        notchReal: notchReal
      )
  }

  static func anotarElArranque(
    estado: EstadoDelNotch,
    ventana: CGSize,
    forma: CGSize,
    pantalla: String,
    notchReal: Bool
  ) {
    guard activo else { return }
    log.notice(
      "\(lineaDelArranque(estado: estado, ventana: ventana, forma: forma, pantalla: pantalla, notchReal: notchReal), privacy: .public)"
    )
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
    // líneas por dictado, y en Release sólo encendido a mano.
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

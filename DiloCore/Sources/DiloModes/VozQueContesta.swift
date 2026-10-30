import Foundation

/// La voz que dice la respuesta de la **Conversación**, en streaming.
///
/// Un contrato chico a propósito: hoy lo cumple `VozDelSistema`
/// (`AVSpeechSynthesizer`, en `Dilo/Conversacion/`), y cuando «Leer en voz
/// alta» tenga su voz neural local se enchufa esa sin tocar la conversación.
/// Lo que pide:
///
/// - `decir(_:)` recibe **una oración por vez**, a medida que llegan, y
///   empieza a hablar con la primera sin esperar las demás. Las encola en
///   orden y no corta la que está sonando.
/// - `cerrarElTurno()` avisa que no viene más texto: cuando termine lo
///   encolado, llama a `alTerminar` **una vez**. Si ya no quedaba nada,
///   llama en el acto.
/// - `detener()` calla ahora y descarta lo encolado, sin llamar a
///   `alTerminar`: es la interrupción, y quien interrumpe ya sabe que paró.
/// - `alEmpezar` se llama cuando suena la primera oración del turno, para
///   que la barra pase de «pensando» a «hablando» cuando de verdad suena.
///
/// Todo en el actor principal: lo llama el controlador de la conversación,
/// que vive ahí, y los avisos vuelven ahí.
@MainActor
public protocol VozQueContesta: AnyObject {
  func decir(_ oracion: String)
  func cerrarElTurno()
  func detener()
  /// Cambia la voz y la velocidad para lo que se diga desde ahora.
  func ajustar(_ ajustes: AjustesDeLaVoz)
  var alEmpezar: (@MainActor () -> Void)? { get set }
  var alTerminar: (@MainActor () -> Void)? { get set }
  /// Qué tan fuerte está sonando, de 0 a 1 en la escala de la muesca, desde
  /// cualquier hilo. Devuelve nil si no se sabe: sin esto no se puede separar
  /// a la persona del eco, y hablarle encima no interrumpe.
  var nivelDeSalida: (@Sendable () -> Float?)? { get }
}

extension VozQueContesta {
  public var nivelDeSalida: (@Sendable () -> Float?)? { nil }
}

/// Con qué voz y a qué velocidad contesta la conversación.
public struct AjustesDeLaVoz: Equatable, Sendable {
  /// El identificador de la voz, o nil para la de fábrica del idioma.
  public var voz: String?
  /// Sobre la velocidad normal de la voz: 1 es la de siempre.
  public var velocidad: Double

  public static let velocidades: [Double] = [0.85, 1, 1.15, 1.3]
  public static let deFabrica = AjustesDeLaVoz(voz: nil, velocidad: 1)

  public init(voz: String?, velocidad: Double) {
    self.voz = voz
    self.velocidad = min(max(velocidad, 0.5), 2)
  }
}

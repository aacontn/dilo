import ApplicationServices
import CoreGraphics
import Foundation

/// Lo que el elemento con el foco está ofreciendo para leer, aplanado a
/// valores simples para que la decisión de Leer en voz alta se pueda probar
/// sin un elemento vivo.
public struct FocoLegible: Equatable, Sendable {
  public var subrol: String?
  public var textoSeleccionado: String?

  public init(subrol: String? = nil, textoSeleccionado: String? = nil) {
    self.subrol = subrol
    self.textoSeleccionado = textoSeleccionado
  }
}

/// Lo que Dilo puede hacer hacia afuera de sí mismo, detrás de un contrato.
///
/// Hay dos implementaciones y se eligen solas: `FullHost` en el target de
/// venta directa y `SandboxedHost` en el de App Store, donde la API de
/// Accesibilidad hacia otra app está cortada de raíz. Todo el árbol de
/// Talkify que tocaba Accesibilidad pasa por acá, para que el sandbox no
/// se caiga en ejecución sino que **esconda** lo que no puede hacer.
///
/// El contrato no representa permisos de TCC: Accesibilidad e Input
/// Monitoring son un estado que concede una persona y que cambia en caliente.
/// Acá está lo que es posible en este anfitrión, que no cambia nunca.
public protocol HostCapabilities: Sendable {
  /// Para los logs y el panel Acerca de. No es copy visible traducible.
  var nombre: String { get }

  /// Se consulta **antes** de dibujar una opción. Lo que no se puede, se
  /// esconde: un menú que falla al apretarlo es peor que un menú sin la
  /// opción.
  func admite(_ capacidad: Capacidad) -> Bool

  /// Si este proceso tiene Accesibilidad concedida. Vale en los dos
  /// anfitriones: en sandbox sigue siendo la compuerta del Cmd+V sintético,
  /// aunque leer otra app ya no sea posible.
  var tieneAccesibilidad: Bool { get }

  /// Muestra el diálogo del sistema. Quien llama se encarga de hacerlo una
  /// sola vez por lanzamiento.
  @discardableResult
  func pedirAccesibilidad() -> Bool

  /// El elemento que tenía el foco en todo el sistema, o nil cuando este
  /// anfitrión no puede mirar dentro de otra app.
  func elementoEnfocado() -> AXUIElement?

  /// Un atributo que debería contener otro elemento.
  func elemento(_ duenno: AXUIElement, atributo: String) -> AXUIElement?

  /// De qué proceso es este elemento.
  func pid(de elemento: AXUIElement) -> pid_t

  /// Si el destino es un campo de contraseña. `false` también significa
  /// "no se pudo saber": quien pregunta debe mirar antes
  /// `admite(.focoAntesDePegar)` si la respuesta lo compromete.
  func esCampoSeguro(_ elemento: AXUIElement) -> Bool

  /// El rectángulo del elemento en coordenadas de pantalla. Sirve para
  /// elegir en qué pantalla baja el HUD.
  func marco(de elemento: AXUIElement) -> CGRect?

  /// Si el foco sigue donde estaba cuando arrancó el dictado.
  ///
  /// Con Accesibilidad se compara el elemento exacto. Sin ella lo más fino
  /// que se puede saber es que la misma app siga al frente, que es la misma
  /// respuesta que Talkify ya daba para las apps sin elemento enfocado.
  func sigueSiendoElFoco(elemento: AXUIElement?, pid: pid_t) -> Bool

  /// Lo que la app al frente tiene seleccionado, o nil si no se puede leer.
  func focoParaLeer() -> FocoLegible?

  /// El título de la ventana al frente, o nil si no se puede leer.
  func tituloDeVentanaActiva() -> String?
}

/// El anfitrión de esta ejecución, resuelto una vez.
public enum Anfitrion {
  /// La variable la pone el propio sandbox: si existe, estamos dentro de un
  /// contenedor. Es más honesto que un `#if` de compilación porque describe
  /// dónde corre la app y no con qué bandera se compiló — el mismo binario
  /// puesto en un contenedor se comporta como lo que es.
  public static let variableDeSandbox = "APP_SANDBOX_CONTAINER_ID"

  public static let actual: any HostCapabilities = resolver()

  /// Expuesto con el entorno por parámetro para poder probar la detección
  /// sin volver a lanzar el proceso.
  public static func resolver(
    entorno: [String: String] = ProcessInfo.processInfo.environment,
    lector: any LectorDeAccesibilidad = AccesibilidadDelSistema()
  ) -> any HostCapabilities {
    entorno[variableDeSandbox] == nil
      ? FullHost(lector: lector)
      : SandboxedHost(lector: lector)
  }
}

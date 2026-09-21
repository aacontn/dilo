import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// El anfitrión del target de App Store.
///
/// El App Sandbox corta la API de Accesibilidad **hacia otra app** sin
/// importar lo que TCC haya concedido: medido el 2026-09-20, la misma lectura
/// devuelve `-25204 CannotComplete` desde el sandbox y `-25211 APIDisabled`
/// desde el target directo. No dice "falta permiso", dice "no puedo". Por eso
/// acá no se intenta: cada respuesta es la negativa, y **el lector de
/// Accesibilidad no se llama ni una vez** — un test lo comprueba con un
/// espía en lugar de confiar en este párrafo.
///
/// Lo que sí queda en pie, y es todo el dictado:
///
/// - el portapapeles funciona dentro del sandbox, escribe y relee;
/// - el Cmd+V sintético es legal (precedente: TypeMeIt, dos builds), cuelga
///   de Accesibilidad concedida como en cualquier app;
/// - el tap de teclado del gatillo es legal, cuelga de Input Monitoring;
/// - el tap de audio del sistema entrega audio real con `device.audio-input`.
///
/// El precio es el foco: sin poder mirar dentro de otra app, el pegado no
/// apunta al campo exacto sino a la app que esté al frente, y no hay manera
/// de saber si ese campo es una contraseña. Se pega igual —un Cmd+V pedido
/// por quien acaba de dictar es el mismo Cmd+V que teclearía— pero lo que
/// dependía de leer el destino (Leer en voz alta, el arrastre al notch) no se
/// ofrece.
public struct SandboxedHost: HostCapabilities {
  /// Guardado aunque no se use: lo recibe para que `Anfitrion.resolver` arme
  /// los dos anfitriones igual, y para que un espía pueda demostrar que
  /// teniéndolo a mano no lo llama.
  private let lector: any LectorDeAccesibilidad

  public init(lector: any LectorDeAccesibilidad = AccesibilidadDelSistema()) {
    self.lector = lector
  }

  public var nombre: String { "sandbox" }

  public func admite(_ capacidad: Capacidad) -> Bool {
    switch capacidad {
    case .pegadoDirecto, .atajoGlobal, .tapDeAudioDelSistema:
      true
    case .focoAntesDePegar, .relecturaDelFoco, .tituloDeVentanaActiva,
      .arrastreDeArchivosAlNotch:
      false
    }
  }

  /// Sigue siendo la compuerta del Cmd+V sintético y del tap del gatillo:
  /// preguntarlo no es leer otra app, es preguntar por uno mismo.
  public var tieneAccesibilidad: Bool { lector.estaAutorizado }

  @discardableResult
  public func pedirAccesibilidad() -> Bool { lector.pedirAutorizacion() }

  public func elementoEnfocado() -> AXUIElement? { nil }

  public func elemento(_ duenno: AXUIElement, atributo: String) -> AXUIElement? { nil }

  /// Sin elemento no hay proceso que averiguar. Quien captura el foco cae al
  /// camino de "la app al frente", que no necesita Accesibilidad.
  public func pid(de elemento: AXUIElement) -> pid_t { 0 }

  /// `false` acá significa "no se pudo saber", no "no es una contraseña".
  /// Por eso `admite(.focoAntesDePegar)` es lo que hay que mirar antes de
  /// apoyar una decisión en esta respuesta.
  public func esCampoSeguro(_ elemento: AXUIElement) -> Bool { false }

  /// El HUD cae a la pantalla del puntero, que es cosmético y ya era el
  /// respaldo de Talkify.
  public func marco(de elemento: AXUIElement) -> CGRect? { nil }

  /// Lo más fino que se puede saber sin Accesibilidad: que la misma app siga
  /// al frente. Alcanza para no pegarle a la ventana equivocada, que es de lo
  /// que protege esta pregunta.
  public func sigueSiendoElFoco(elemento: AXUIElement?, pid: pid_t) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  }

  public func focoParaLeer() -> FocoLegible? { nil }

  public func tituloDeVentanaActiva() -> String? { nil }
}

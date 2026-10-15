import Foundation
import DiloEngines

/// Reintentar o botar la toma que quedó en RAM cuando un dictado no sacó
/// texto, tal como las ofrece el panel de la barra.
///
/// Viven en la barra y no sólo en la muesca porque el estado Resultado dura
/// lo que dura un aviso, y una toma guardada dura diez minutos. Sin toma no
/// aparecen: una fila apagada que nunca se prendió no explica nada (la misma
/// regla de «Copiar el último dictado»). Hasta la 0.4.8 eran dos ítems del
/// menú gris; desde que el menú es un panel (2026-10-15), son una tarjeta
/// arriba de todo (`PanelDeLaBarra.Contenido.toma`).
@MainActor
final class EntradasDeTomaFallida {
  /// Lo cablea `AppDelegate` hacia el controlador de dictado.
  var reintentar: (() -> Void)?
  var descartar: (() -> Void)?
  /// El reloj de la toma («0:12»), o nil si se fue. Lo escucha el
  /// `StatusItemController` para el panel.
  var alCambiar: ((String?) -> Void)?

  /// La duración de la toma guardada, o nil para esconderla.
  func mostrar(_ duracion: TimeInterval?) {
    alCambiar?(duracion.map(PoliticaDeGrabacion.reloj))
  }
}

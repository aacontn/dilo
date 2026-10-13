import AppKit
import DiloEngines

/// Las dos entradas del menú de la barra para una toma que quedó en RAM:
/// reintentarla y botarla.
///
/// Viven en el menú y no en la muesca porque el estado Resultado sólo dura
/// lo que dura un aviso, y una toma guardada dura diez minutos. Escondidas
/// mientras no hay toma: un ítem apagado que nunca se prendió no explica
/// nada (la misma regla de «Copiar el último dictado»).
@MainActor
final class EntradasDeTomaFallida: NSObject {
  /// Lo cablea `AppDelegate` hacia el controlador de dictado.
  var reintentar: (() -> Void)?
  var descartar: (() -> Void)?

  let reintentarItem = NSMenuItem(
    title: String(localized: "Reintentar el dictado que no salió"), action: nil, keyEquivalent: ""
  )
  let descartarItem = NSMenuItem(
    title: String(localized: "Descartar la grabación"), action: nil, keyEquivalent: ""
  )

  override init() {
    super.init()
    reintentarItem.action = #selector(reintentarElegido)
    reintentarItem.target = self
    reintentarItem.isHidden = true
    descartarItem.action = #selector(descartarElegido)
    descartarItem.target = self
    descartarItem.isHidden = true
  }

  func agregar(a menu: NSMenu) {
    menu.addItem(reintentarItem)
    menu.addItem(descartarItem)
  }

  /// La duración de la toma guardada, o nil para esconder las dos.
  func mostrar(_ duracion: TimeInterval?) {
    reintentarItem.isHidden = duracion == nil
    descartarItem.isHidden = duracion == nil
    reintentarItem.badge = duracion.map { NSMenuItemBadge(string: PoliticaDeGrabacion.reloj($0)) }
  }

  @objc private func reintentarElegido() {
    reintentar?()
  }

  @objc private func descartarElegido() {
    descartar?()
  }
}

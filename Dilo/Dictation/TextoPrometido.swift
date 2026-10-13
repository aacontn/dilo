// Técnica observada en AeriVoice 0.2.5 (promesa en el portapapeles con acuse
// de lectura) y Spokenly 2.31 (proveedor de datos sólo para `.string`);
// implementación propia.
import AppKit
import DiloCapabilities
import os

/// El dictado ofrecido como promesa en el portapapeles: el texto sale recién
/// cuando una app lo pide, y así Dilo sabe **cuándo** lo leyó la app de
/// destino. Es la única confirmación de pegado que existe en todas las apps y
/// en los dos targets: no pide Accesibilidad.
///
/// Qué lectura cuenta lo decide `AcuseDeLectura`; esto es sólo la puerta que
/// AppKit llama.
final class TextoPrometido: NSObject, NSPasteboardItemDataProvider, Sendable {
  let texto: String
  private let ahora: @Sendable () -> Duration
  private let estado = OSAllocatedUnfairLock(initialState: AcuseDeLectura())

  /// - Parameters:
  ///   - texto: El dictado que se entrega a quien lo pida.
  ///   - ahora: El reloj del servicio, para que un test maneje el tiempo en
  ///     vez de esperarlo.
  init(texto: String, ahora: @escaping @Sendable () -> Duration) {
    self.texto = texto
    self.ahora = ahora
    super.init()
  }

  /// Se llama en el actor principal **sin ningún `await`** entre esto y el
  /// ⌘V: lo que se lea antes no es el pegado.
  func marcarDespachado() {
    estado.withLock { $0.despachar() }
  }

  /// Deja de anotar lecturas. Lo ya anotado se conserva.
  func detener() {
    estado.withLock { $0.detener() }
  }

  /// Una copia del estado, para el log.
  var acuse: AcuseDeLectura { estado.withLock { $0 } }

  /// La lectura que confirma el pegado, o nil si todavía no hubo.
  var lecturaValida: Duration? { estado.withLock { $0.primeraLectura } }

  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    guard type == .string else { return }
    // Entregar siempre, también a quien no cuenta: negarle el texto a una
    // lectura dudosa gasta la promesa y deja al pegado de verdad sin nada.
    item.setString(texto, forType: .string)
    let instante = ahora()
    estado.withLock { $0.anotarLectura(en: instante) }
  }

  /// El portapapeles ya no necesita esta promesa: alguien escribió encima.
  /// No hay nada que hacer; el vigilante lo nota por `changeCount`.
  func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

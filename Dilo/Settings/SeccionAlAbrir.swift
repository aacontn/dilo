import Foundation

/// En qué sección abre la ventana de Ajustes. Puro, con el reloj por
/// parámetro.
///
/// Alfonso, 2026-10-19: que Ajustes recuerde la última sección y que el clic
/// en el ícono abra la portada. Las dos cosas a la vez se resuelven por el
/// tiempo: quien cerró Ajustes para probar algo en otra app y vuelve al rato
/// quiere seguir donde estaba; quien vuelve mañana quiere la portada.
enum SeccionAlAbrir {
  /// Cuánto se recuerda la última sección después de cerrar la ventana.
  static let memoria: TimeInterval = 10 * 60

  /// - Parameters:
  ///   - pedida: la que alguien pidió de afuera (Novedades al actualizar,
  ///     elegir un idioma de traducción desde la muesca). Siempre gana.
  ///   - ultima: el `rawValue` guardado de la última sección a la vista.
  ///   - cerradaEn: cuándo se cerró la ventana por última vez.
  static func decidir(
    pedida: SettingsSection?,
    ultima: String,
    cerradaEn: Date?,
    ahora: Date
  ) -> SettingsSection {
    if let pedida { return pedida }
    guard let cerradaEn,
      ahora.timeIntervalSince(cerradaEn) < memoria,
      let seccion = SettingsSection(rawValue: ultima),
      seccion.esNavegable
    else { return .portada }
    return seccion
  }
}

extension SettingsSection {
  /// Si la barra lateral la ofrece: una sección guardada que ya no está en
  /// ningún grupo (Sonidos, que vive dentro de Apariencia) no se abre sola.
  var esNavegable: Bool {
    SettingsSectionGroup.allCases.contains { $0.sections.contains(self) }
  }
}

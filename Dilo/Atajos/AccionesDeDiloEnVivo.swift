import AppIntents
import DiloModes
import DiloPlataforma
import Foundation

/// Las acciones de los App Intents contra la app de verdad. Cada una es una
/// línea hacia lo que ya existe —el controlador de dictado, los ajustes, el
/// menú de la barra, el escenario—, para que un atajo y un clic nunca hagan
/// cosas distintas.
@MainActor
final class AccionesDeDiloEnVivo: AccionesParaAtajos {
  private let settings: AppSettings
  private let dictado: DirectDictationController
  private let copiarAlPortapapeles: (String) -> Void
  private let aviso: AvisoDeAtajoEnLaMuesca
  private let transcripcion = FileTranscriptionService()

  init(
    settings: AppSettings,
    dictado: DirectDictationController,
    copiarAlPortapapeles: @escaping (String) -> Void,
    aviso: AvisoDeAtajoEnLaMuesca
  ) {
    self.settings = settings
    self.dictado = dictado
    self.copiarAlPortapapeles = copiarAlPortapapeles
    self.aviso = aviso
    observarLosModos()
  }

  func dictar(_ pedido: DirectDictationController.ModoPedido) -> DirectDictationController.RespuestaAlDictar {
    dictado.dictarDesdeUnAtajo(pedido)
  }

  func dictarNota() {
    dictado.dictarNota()
  }

  var modos: [Modo] { settings.modos }

  var modoDelAtajoGeneral: String? {
    get { settings.hudModoDelAtajoGeneral }
    set { settings.hudModoDelAtajoGeneral = newValue }
  }

  var ultimoDictado: UltimoDictado? { dictado.ultimoDictado }

  func copiar(_ texto: String) {
    copiarAlPortapapeles(texto)
  }

  var historialEncendido: Bool { settings.dictationHistoryEnabled }

  func buscarEnHistorial(_ consulta: String) async throws -> [String] {
    let carpeta = settings.resolvedHistoryFolder
    return try await DictationHistoryStore().buscar(consulta, in: carpeta).map(\.texto)
  }

  /// Con el idioma principal, como el arrastre al notch sin modificador.
  func transcribir(_ archivo: URL) async throws -> String {
    let idioma = settings.localeIdentifierForDrop(languageIndex: 0)
    return try await transcripcion.transcribe(url: archivo, localeIdentifier: idioma) { _ in }.text
  }

  func mostrarEnLaMuesca(_ aviso: AvisoDeAfuera) {
    self.aviso.mostrar(aviso)
  }

  /// Siri entiende «Usar Correo en Dilo» por los nombres de los modos, que
  /// cambian en Ajustes: cada cambio le avisa al sistema que vuelva a
  /// preguntar (`ConsultaDeModos.suggestedEntities`).
  private func observarLosModos() {
    withObservationTracking {
      _ = settings.modos.map(\.nombre)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        AtajosDeDilo.updateAppShortcutParameters()
        self?.observarLosModos()
      }
    }
  }
}

/// «Mostrar en la muesca»: un segmento al costado por unos segundos. Uno a
/// la vez —un aviso nuevo reemplaza al anterior y vuelve a decir su
/// palabra— y un clic lo quita.
@MainActor
final class AvisoDeAtajoEnLaMuesca {
  static let actividad = ActividadDeLaMuesca(id: "atajo", prioridad: .normal, puedeSerPrincipal: false)

  private let publicar: (ActividadDeLaMuesca, ContenidoDelSegmento) -> Void
  private let retirar: (String) -> Void
  private var vencimiento: Task<Void, Never>?

  init(
    publicar: @escaping (ActividadDeLaMuesca, ContenidoDelSegmento) -> Void,
    retirar: @escaping (String) -> Void
  ) {
    self.publicar = publicar
    self.retirar = retirar
  }

  static func contenido(_ aviso: AvisoDeAfuera) -> ContenidoDelSegmento {
    ContenidoDelSegmento(
      id: actividad.id,
      simbolo: aviso.simbolo,
      texto: aviso.texto,
      destacada: false,
      accesibilidad: String(localized: "\(aviso.texto). Un clic lo quita de la muesca.")
    )
  }

  func mostrar(_ aviso: AvisoDeAfuera) {
    publicar(Self.actividad, Self.contenido(aviso))
    vencimiento?.cancel()
    vencimiento = Task { [weak self] in
      try? await Task.sleep(for: .seconds(aviso.segundos))
      guard !Task.isCancelled else { return }
      self?.quitar()
    }
  }

  func quitar() {
    vencimiento?.cancel()
    vencimiento = nil
    retirar(Self.actividad.id)
  }
}

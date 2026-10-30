import DiloCapabilities
import DiloModes
import DiloReuniones
import Foundation
import Observation

/// Live app state the Settings surface reflects but does not own: whether a
/// Direct Dictation session is active (drives the changes-apply-next-session
/// notice). The composition root updates it from the dictation controller.
@MainActor
@Observable
final class SettingsRuntimeState {
  var isDictating: Bool

  /// Si hay clave de cada proveedor, leída una vez por apertura y fuera del
  /// hilo principal (`ClavesDeLosProveedores`). La comparten Inicio, Claude,
  /// Modos, Idioma y Tus palabras: antes cada una le preguntaba al Llavero
  /// por su cuenta, en el hilo principal, y Modos lo hacía en cada `body`.
  let claves: ClavesDeLosProveedores

  /// Si la ventana de Ajustes está a la vista. Con la ventana cerrada el
  /// contenido no se dibuja: una ventana cerrada con `orderOut` no cancela
  /// las `.task` de sus vistas, y la vista previa de Apariencia seguía
  /// animando la muesca a 14 cuadros por segundo con Ajustes cerrado.
  var ventanaAbierta = false

  /// La sección a la vista, la escribe la ventana. La lee el vigilante de
  /// cuelgues para decir dónde estaba la persona cuando el hilo se trabó.
  var seccionActual: SettingsSection?

  /// Lo último dictado, para Inicio: en RAM, como en el panel de la barra.
  /// Nunca se escribe en ningún lado desde acá.
  var ultimoDictado: UltimoDictado?

  /// Para los renders: qué permisos faltan, en vez de preguntarle a TCC.
  /// Nil en la app.
  var permisosQueFaltanFijos: Set<Permiso>?

  /// La sección que alguien de afuera pidió abrir —el panel de la barra, o el
  /// arranque después de actualizar, que abre Novedades—. La ventana de
  /// Ajustes la consume y la deja en nil: es una orden, no un estado.
  var seccionPedida: SettingsSection?

  /// La fila que alguien pidió mostrar: «Abrir Claude» desde Idioma, una
  /// tarjeta de Inicio. Como `seccionPedida`, la ventana la consume.
  var filaPedida: AjusteID?

  /// «Probar» de la tarjeta de agentes: pone «Claude te espera» en la
  /// muesca sin pasar por LaunchServices (`AgentesEnLaMuesca.probar`).
  @ObservationIgnored var probarAgente: () -> Void = {}

  /// Quien ordena Tus palabras con Claude: «Ordenar ahora» y el deshacer
  /// del registro, en Ajustes → Tus palabras. Nil en las vistas previas.
  var ordenador: OrdenadorDelDiccionario?

  /// Reuniones: el control que la lista y los ajustes miran. Nil en las
  /// vistas previas y en los renders.
  var reuniones: ControlDeReuniones?
  /// Para los renders: la lista fija, sin leer el disco.
  var reunionesFijas: [ReunionEnDisco]?
  /// Abre la ventana de una reunión, en una línea si viene de la búsqueda.
  @ObservationIgnored var abrirReunion: (String, Int?) -> Void = { _, _ in }
  /// Dónde se leen y escriben las preferencias de reuniones: las del Mac en
  /// la app, un dominio de `/private/tmp` en los renders.
  @ObservationIgnored var defaultsDeReuniones: UserDefaults = .standard
  /// Para los renders: cómo está el separador de voces, sin mirar el disco.
  var separadorFijo = ControlDeReuniones.EstadoDelSeparador.sinRevisar

  /// Language models currently downloading, as locale identifier to progress
  /// (0…1). A language picked before its model exists downloads in the
  /// background, and the Language section says so rather than looking idle.
  var languageDownloads: [String: Double] = [:]

  /// Every language the chosen source can translate into, with what this Mac
  /// can do about each. Probed when the languages change, because the answer
  /// depends on which models are installed.
  var translationTargets: [TranslationTarget] = []

  /// What the chosen target can do right now, for the row under the picker.
  var translationModelState: TranslationModelState = .none

  /// The language the targets above are measured from, which Settings needs
  /// in hand to name a pair. Installing a model is something only Settings can
  /// do, because only Settings has a window.
  var translationSource: Locale.Language?

  /// Waits for a model to install and loads it, answering how that ended.
  /// Held here rather than threaded through four constructors: this object
  /// already exists to carry what Settings reflects but does not own.
  var installTranslationModel: (TranslationPair) async -> TranslationCoordinator.InstallOutcome
    = { _ in .unavailable }

  /// One attempt at installing a model: which pair, and which try at it.
  ///
  /// Two attempts at the same pair happen whenever the user switches away and
  /// back before the first is cancelled, and the pair alone cannot tell them
  /// apart, so a superseded attempt would clear the state its replacement owns.
  struct TranslationInstall: Equatable {
    let pair: TranslationPair
    let attempt: Int
  }

  /// The install in flight, or nil when nothing is. Held here because the view
  /// that starts one is replaced whenever the user changes Settings section,
  /// and the modifier that drives Apple's download has to outlive that.
  private(set) var installingTranslation: TranslationInstall?
  private var attempts = 0

  /// Claims the install state for a new attempt, and says which one it is.
  func beginTranslationInstall(_ pair: TranslationPair) -> TranslationInstall {
    attempts += 1
    let install = TranslationInstall(pair: pair, attempt: attempts)
    installingTranslation = install
    return install
  }

  /// Releases the install state, but only for the attempt that still owns it.
  func endTranslationInstall(_ install: TranslationInstall) {
    guard installingTranslation == install else { return }
    installingTranslation = nil
  }

  /// The language whose model never arrived, until it is dismissed or another
  /// is chosen. Held here rather than in the Language view: leaving that
  /// section replaces the view, and a revert nobody explained is worse than
  /// the failure itself.
  var translationInstallFailure: String?

  /// Abandons a wait for a model. Reachable whether or not the view that
  /// started it still exists.
  var stopInstallingTranslationModel: () -> Void = {}

  /// La cuenta del Llavero de la clave de Anthropic: una sola, la del
  /// proveedor Anthropic de Modos, que sirve también para traducir y aprender.
  static var cuentaDeAnthropic: String { Proveedor.anthropicDeFabrica.cuentaEnElLlavero }

  var hayClaveDeAnthropic: Bool { claves.hay(Self.cuentaDeAnthropic) }

  init(isDictating: Bool = false, claves: ClavesDeLosProveedores? = nil) {
    self.isDictating = isDictating
    self.claves = claves ?? ClavesDeLosProveedores(almacen: Llavero())
  }

  func setDownload(identifier: String, fraction: Double?) {
    if let fraction {
      languageDownloads[identifier] = fraction
    } else {
      languageDownloads[identifier] = nil
    }
  }
}

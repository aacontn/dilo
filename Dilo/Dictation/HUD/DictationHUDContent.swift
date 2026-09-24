import Foundation
import Observation

/// What the HUD currently says — the one mutable model shared between the
/// AppKit controller (which writes it) and the SwiftUI shell and visuals
/// (which observe it).
@MainActor
@Observable
final class DictationHUDContent {
  var text = ""
  /// The recognizer's current guess, not yet finalized. Drawn lighter so
  /// new words can show before they commit (CONTEXT.md: volatile results
  /// render immediately).
  var volatileText = ""
  /// Drives the reveal/dismiss animation.
  var isRevealed = false
  /// True only while listening — the visuals react to the microphone, so
  /// they leave when it stops.
  var showsVoiceVisual = false
  /// Smoothed microphone level, 0–1.
  var audioLevel: Double = 0
  /// Raw recent levels, newest last, one per waveform bar.
  var levelHistory = [Float](repeating: 0, count: HUDWaveformView.barCount)
  /// False once levels stop arriving while listening: a dead microphone
  /// must look different from silence (CONTEXT.md).
  var isAudioAlive = true
  /// The session's language as a short tag ("DE"), or nil when only one
  /// language is set up. Recognition in the wrong language returns confident
  /// nonsense rather than an error, so a two-key setup says which is live.
  var languageTag: String?
  /// True from the moment the HUD starts retracting until it is off screen.
  /// The layout is pinned to whatever it was showing: the voice visual stops
  /// reacting so a glow can drain, but the bands must not resize underneath a
  /// shape that is already sliding away.
  var isDismissing = false
  /// Bumped once per session start; one-shot effects (the ripple) trigger
  /// on the change rather than on the listening state, so they never
  /// re-fire mid-session.
  var sessionEpoch = 0
  /// The prompt name the finished words are being shaped with, or nil while
  /// no shaping phase is running. Non-nil swaps the band's cycling carousel
  /// for the shaping caption.
  var shapingName: String?
  /// The session's shaping pick by name, drawn as a shoulder tag, or nil when
  /// this session cannot cycle.
  var shapingChoiceLabel: String?

  /// En cuál de los cinco estados del contrato está el escenario
  /// (`EstadoDelNotch`). Arranca en reposo, que es donde pasa la mayor parte
  /// del día: el HUD ya no aparece y desaparece, cambia de tamaño.
  var estado = EstadoDelNotch.reposo

  /// El modo que usaría el próximo dictado, o nil mientras no hay ninguno.
  ///
  /// Sobrevive a la sesión a propósito: es el único dato que la muesca en
  /// reposo puede llegar a decir, y sólo si la persona encendió
  /// `hudModoEnReposo`. Lo escribe el controlador de dictado, que es quien
  /// resuelve el modo; la forma sólo lo dibuja.
  var modoActivo: String?

  /// Si la sesión en curso es una nota rápida (`DirectDictationController.dictarNota`).
  var esNota = false

  /// Si ahora mismo se está dictando una nota: la línea lleva su etiqueta.
  var notaEnCurso: Bool { esNota && estado == .dictando }

  /// Si el dictado en curso está trabado: se abrió sin tecla sostenida —con
  /// un clic en «Nota» o en «Traducir», desde el menú, o con el doble toque—
  /// y sigue escuchando hasta que alguien lo cierre.
  var trabada = false

  /// Si hay un dictado trabado escuchando ahora mismo. La línea lleva un ✓ al
  /// final y un clic en la muesca lo termina
  /// (`HUDStage.vigilarElClicDeLaSesionTrabada`): lo que se abrió sin tecla
  /// tiene que poder cerrarse sin tecla. Empezó con la nota —«aprieto Nota y
  /// se queda andando» (2026-09-24)— y vale para todos.
  var sesionTrabadaEnCurso: Bool { trabada && estado == .dictando }
  /// Un clic en la muesca con un dictado trabado: lo termina.
  @ObservationIgnored var alTerminarSesionTrabada: (() -> Void)?

  /// Lo que va a cada costado de la muesca en reposo, o nil. Lo escribe
  /// `DatosDeLaMuesca` desde el escenario; la forma sólo lo dibuja.
  var datoIzquierdo: LadoDeLaMuesca?
  var datoDerecho: LadoDeLaMuesca?

  // MARK: El panel del hover

  /// Lo reciente que se puede volver a copiar, lo más nuevo primero
  /// (`agregarReciente`).
  var recientes: [ElementoReciente] = []
  /// La reunión que viene, si se pidió leer el calendario y hay una pronto.
  var proximaReunion: ProximaReunion?
  /// Los modos de la biblioteca, y el que usa el atajo general.
  var modosDelPanel: [ModoDelPanel] = []
  var modoDelPanelID: String?
  /// El reciente que se acaba de copiar: su fila dice «Copiado» un momento.
  var recienteCopiadoID: UUID?
  @ObservationIgnored var alCopiarReciente: ((ElementoReciente) -> Void)?
  @ObservationIgnored var alElegirModo: ((String?) -> Void)?
  @ObservationIgnored var alAbrirReunion: (() -> Void)?
  /// Si el panel ofrece «Traducir», y a qué idioma: nil lo esconde,
  /// `sinDestino` lo muestra apagado y lleva a elegir el idioma en Ajustes.
  var traduccionDelPanel: TraduccionDelPanel?
  @ObservationIgnored var alDictarTraduciendo: (() -> Void)?
  @ObservationIgnored var alElegirIdiomaDeTraduccion: (() -> Void)?

  /// Si el panel ofrece «Nota» al final de la fila de los modos, y qué hace.
  var ofreceNota = false
  @ObservationIgnored var alDictarNota: (() -> Void)?

  /// Lo que el hover revela: el modo activo, o lo último que se dictó. Lo
  /// escribe quien sabe (el controlador de dictado); la forma sólo lo dibuja.
  var contexto: String?

  /// True mientras el puntero lleva parado encima lo suficiente
  /// (`HUDStage.toleranciaDelHover`). Es sólo presentación: un hover no
  /// arranca nunca una captura.
  var punteroEncima = false

  /// Lo que el hover revela cuando todavía no hay nada que contar: el nombre.
  ///
  /// Existe porque sin él el hover no revelaba **nada** en una instalación
  /// recién hecha: `contexto` sólo se escribe al terminar el primer dictado
  /// (`AppDelegate.onUltimoDictadoChange`), así que hasta entonces posarse
  /// sobre la muesca no hacía absolutamente nada y no había cómo saber si
  /// estaba rota o si era así (reporte del 2026-09-22). Una muesca que
  /// responde al puntero diciendo quién es sigue siendo una respuesta.
  static let contextoDeFabrica = String(localized: "Dilo")

  /// El contexto que corresponde dibujar ahora mismo, o nil.
  ///
  /// Con el puntero encima **siempre** hay algo: lo último que se dictó, el
  /// modo activo, o el nombre. El hover es la promesa de que la muesca está
  /// viva; una que a veces no abre se lee como una que no funciona.
  var contextoVisible: String? {
    guard punteroEncima else { return nil }
    if let contexto, !contexto.isEmpty { return contexto }
    if let modoActivo, !modoActivo.isEmpty { return modoActivo }
    return Self.contextoDeFabrica
  }

  /// Si hay un dictado anterior que copiar.
  ///
  /// Es lo que convierte el panel del hover en una acción y no sólo en una
  /// etiqueta: desde que el estado Resultado salió del camino feliz
  /// (2026-09-22), «copiar el último dictado» vive en el menú de la barra y
  /// acá. Se deduce de `contexto`, que es justamente lo que el controlador
  /// escribe al terminar un dictado; una segunda bandera sería un segundo
  /// lugar del que desviarse.
  var puedeCopiar: Bool {
    guard let contexto else { return false }
    return !contexto.isEmpty
  }

  /// Un clic en la silueta: con el panel del hover abierto y algo que copiar,
  /// copia; si no, abre el menú de acciones. Lo cablea `HUDStage`.
  @ObservationIgnored var alHacerClic: (() -> Void)?
}

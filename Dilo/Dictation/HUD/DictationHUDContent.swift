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

  /// Lo que el hover revela: el modo activo, o lo último que se dictó. Lo
  /// escribe quien sabe (el controlador de dictado); la forma sólo lo dibuja.
  var contexto: String?

  /// True mientras el puntero lleva parado encima lo suficiente
  /// (`HUDStage.toleranciaDelHover`). Es sólo presentación: un hover no
  /// arranca nunca una captura.
  var punteroEncima = false

  /// El contexto que corresponde dibujar ahora mismo, o nil.
  var contextoVisible: String? {
    guard punteroEncima, let contexto, !contexto.isEmpty else { return nil }
    return contexto
  }

  /// Avisa que el puntero entró o salió de la silueta. Lo cablea `HUDStage`,
  /// que es quien aplica la tolerancia.
  @ObservationIgnored var alEntrarElPuntero: ((Bool) -> Void)?

  /// Un clic en la silueta: abre el menú de acciones en reposo, copia en
  /// resultado. Lo cablea `HUDStage`.
  @ObservationIgnored var alHacerClic: (() -> Void)?
}

import AppKit
import DiloAgentes
import DiloConsumo
import DiloEngines
import DiloModes
import DiloText
import Foundation
import Observation

/// The application settings: every user-facing preference in one observable,
/// UserDefaults-backed store. Settings binds to it, the HUD observes it, and
/// nothing else touches UserDefaults for these keys.
///
/// The key strings predate this module and must not change — they are what
/// existing users' picks are stored under (and, for sounds, the rawValue also
/// prefixes the bundled asset names).
@MainActor
@Observable
final class AppSettings {
  private enum Keys {
    static let soundSet = "dictationSoundSet"
    static let soundsEnabled = "dictationSoundsEnabled"
    static let duckOtherAudio = "duckOtherAudioWhileDictating"
    static let microfonoElegidoUID = "diloMicrofonoElegidoUID"
    static let microfonoElegidoNombre = "diloMicrofonoElegidoNombre"
    static let motorDeAudioTibio = "diloMotorDeAudioTibio"
    static let soundVolume = "dictationSoundVolume"
    static let voiceVisual = "hudVoiceVisual"
    static let waveformStyle = "hudWaveformStyle"
    static let revealStyle = "hudRevealStyle"
    static let longDraftStyle = "hudLongDraftStyle"
    static let glowPalette = "hudGlowPalette"
    static let glowCenter = "hudGlowCenter"
    static let hudScale = "hudScale"
    static let readAloudVoice = "readAloudVoice"
    static let readAloudTranslates = "readAloudTranslates"
    static let readAloudMotor = "readAloudMotor"
    static let readAloudVozPhonon = "readAloudVozPhonon"
    static let dictationTriggerBinding = "dictationTriggerBinding"
    static let readAloudBinding = "readAloudBinding"
    static let recognitionLocale = "recognitionLocale"
    static let secondaryRecognitionLocale = "recognitionLocaleSecondary"
    static let secondaryTriggerBinding = "dictationTriggerBindingSecondary"
    static let translateTriggerBinding = "dictationTriggerBindingTranslate"
    static let translationTarget = "translationTargetLanguage"
    static let motorDeTraduccion = "diloMotorDeTraduccion"
    static let transcriptDestination = "transcriptDestination"
    static let transcriptFolder = "transcriptFolder"
    static let insertionDestination = "dictationInsertionDestination"
    /// La clave vieja, de cuando esto era un interruptor. Se lee una sola
    /// vez para no borrarle la elección a quien ya la había cambiado.
    static let hudClearsMenuBar = "hudClearsMenuBar"
    static let hudEstiloSinNotch = "hudEstiloSinNotch"
    static let paleta = "diloPaleta"
    static let hudPanelDeVidrio = "hudPanelDeVidrio"
    static let hudRetardoDeHover = "hudRetardoDeHover"
    static let hudPantalla = "hudPantalla"
    static let hudModoEnReposo = "hudModoEnReposo"
    static let hudOcultarAlCompartir = "hudOcultarAlCompartir"
    static let hudDatosDeLaMuesca = "hudDatosDeLaMuesca"
    // Las dos claves de antes de la sección propia: un picker por costado.
    // Sólo se leen, una vez, para migrar (`DisposicionDeLaMuesca.migrada`).
    static let hudDatoIzquierdo = "hudDatoIzquierdo"
    static let hudDatoDerecho = "hudDatoDerecho"
    static let hudPorcentajeDeClaude = "hudPorcentajeDeClaude"
    static let hudAvisosDeLimite = "hudAvisosDeLimite"
    static let hudAgentes = "hudAgentes"
    static let hudRecientesDelPortapapeles = "hudRecientesDelPortapapeles"
    static let hudModosEnElPanel = "hudModosEnElPanel"
    static let hudModoDelAtajoGeneral = "hudModoDelAtajoGeneral"
    static let hudProximaReunion = "hudProximaReunion"
    static let hudNotaRapida = "hudNotaRapida"
    static let hudTraducirEnElPanel = "hudTraducirEnElPanel"
    static let historyEnabled = "dictationHistoryEnabled"
    static let historyFolder = "dictationHistoryFolder"
    // Las tres claves de "Transformar", el sistema heredado del árbol de origen. Ya no
    // se escriben: se leen una vez para migrar a modos y se dejan en disco una
    // versión más, por si hay que reconstruir a mano la biblioteca de alguien.
    static let promptShapingEnabled = "dictationPromptShapingEnabled"
    static let promptShapingPrompt = "dictationPromptShapingPrompt"
    static let shapingPrompts = "dictationShapingPrompts"
    static let migracionDeModos = "diloMigracionDeModos"
    static let modos = "diloModos"
    static let proveedores = "diloProveedores"
    static let proveedorGeneral = "diloProveedorGeneral"
    /// Que el general ya se decidió desde que Haiku 5.5 es el de fábrica
    /// (`MigracionDeProveedores.generalConClave`).
    static let proveedorGeneralDecidido = "diloProveedorGeneralDecidido"
    static let migracionModeloDeAnthropic = "diloMigracionModeloDeAnthropic"
    static let unAtajoDiloDecide = "diloUnAtajoDiloDecide"
    static let palabrasPropias = "diloPalabrasPropias"
    static let mayusculaSegunElCursor = "diloMayusculaSegunElCursor"
    static let envioHablado = "diloEnvioHablado"
    static let frasesDeEnvio = "diloFrasesDeEnvio"
    static let limpiarMuletillas = "diloLimpiarMuletillas"
    static let muletillasPropias = "diloMuletillasPropias"
    static let comandosDeFormato = "diloComandosDeFormato"
    static let reemplazos = "diloReemplazos"
    static let fuentesDeContexto = "diloFuentesDeContexto"
    static let migracionDeSenales = "diloMigracionDeSenales"
    static let aprenderDeCorrecciones = "diloAprenderDeCorrecciones"
    static let aprenderConClaude = "diloAprenderConClaude"
    static let modeloParaRevisar = "diloModeloParaRevisar"
    static let modeloParaOrdenar = "diloModeloParaOrdenar"
    static let palabrasAprendidas = "diloPalabrasAprendidas"
    static let aprendidasDesdeElOrden = "diloAprendidasDesdeElOrden"
    static let ultimaPasadaDelOrden = "diloUltimaPasadaDelOrden"
    static let ultimoIntentoDelOrden = "diloUltimoIntentoDelOrden"
    static let firmaDelOrden = "diloFirmaDelOrden"
    static let registroDelOrden = "diloRegistroDelOrden"
    static let onboardingVisto = "diloOnboardingVisto"
    static let versionVista = "diloVersionVista"
    static let ultimaSeccionDeAjustes = "diloAjustesUltimaSeccion"
    static let ajustesCerradosEn = "diloAjustesCerradosEn"
    // La Conversación (2026-10-29).
    static let conversacionGatillo = "diloConversacionGatillo"
    static let conversacionModelo = "diloConversacionModelo"
    static let conversacionVoz = "diloConversacionVoz"
    static let conversacionVelocidad = "diloConversacionVelocidad"
    static let conversacionMicrofonoUID = "diloConversacionMicrofonoUID"
    static let conversacionMicrofonoNombre = "diloConversacionMicrofonoNombre"
    static let conversacionTope = "diloConversacionTopeMensual"
    static let conversacionGasto = "diloConversacionGasto"
    static let conversacionAgentes = "diloConversacionAgentes"
    static let servidoresMCP = "diloServidoresMCP"
    // Claude Code por voz (2026-10-30).
    static let claudeCodeProyectos = "diloClaudeCodeProyectos"
    static let claudeCodeIncluirDeveloper = "diloClaudeCodeIncluirDeveloper"
    static let claudeCodeUltimoProyecto = "diloClaudeCodeUltimoProyecto"
    static let claudeCodeModelo = "diloClaudeCodeModelo"
    static let claudeCodeRuta = "diloClaudeCodeRuta"
  }

  /// La clave de Tus palabras, para quien las lee fuera del actor principal:
  /// el cargador de Parakeet, en cada carga del modelo.
  nonisolated static let claveDePalabrasPropias = Keys.palabrasPropias

  @ObservationIgnored
  private let defaults: UserDefaults

  var soundSet: DictationSoundSet {
    didSet { defaults.set(soundSet.rawValue, forKey: Keys.soundSet) }
  }

  /// Lowers the system output while a session listens. Off by default: it
  /// moves a system-wide control, which is not something to start doing to
  /// someone who did not ask for it.
  var duckOtherAudioWhileDictating: Bool {
    didSet { defaults.set(duckOtherAudioWhileDictating, forKey: Keys.duckOtherAudio) }
  }

  var dictationSoundsEnabled: Bool {
    didSet { defaults.set(dictationSoundsEnabled, forKey: Keys.soundsEnabled) }
  }

  /// Con qué micrófono escucha el dictado. **Automático de fábrica**: la
  /// entrada del sistema, salvo que sea Bluetooth y haya uno con cable
  /// (`PlanDeMicrofono`). Se guarda por UID, con el nombre de respaldo —un USB
  /// en otro puerto cambia de UID—, nunca por `AudioDeviceID`, que se reparte
  /// de nuevo al reconectar. Sólo aplica al motor de Dilo: la entrada del
  /// sistema no se toca.
  var microfonoDeDictado: EleccionDeMicrofono {
    didSet {
      defaults.set(microfonoDeDictado.uidGuardado, forKey: Keys.microfonoElegidoUID)
      defaults.set(microfonoDeDictado.nombreGuardado, forKey: Keys.microfonoElegidoNombre)
    }
  }

  /// Dejar el micrófono preparado entre dictados (`ReservaDeMotorTibio`).
  /// **Apagado de fábrica**: lo que cuesta en reposo y lo que ahorra en el
  /// gatillo todavía no se midieron con el permiso de micrófono.
  var motorDeAudioTibio: Bool {
    didSet { defaults.set(motorDeAudioTibio, forKey: Keys.motorDeAudioTibio) }
  }

  private var storedDictationSoundVolume: Double

  var dictationSoundVolume: Double {
    get { storedDictationSoundVolume }
    set {
      storedDictationSoundVolume = DictationSoundSettings.normalizedVolume(newValue)
      defaults.set(storedDictationSoundVolume, forKey: Keys.soundVolume)
    }
  }

  /// Where a Drop Transcription writes its transcript. The chosen folder is
  /// kept even while the pick is `besideSource`, so switching back and forth
  /// does not lose it.
  var transcriptDestination: TranscriptDestination.Preference {
    didSet { defaults.set(transcriptDestination.rawValue, forKey: Keys.transcriptDestination) }
  }

  var transcriptFolder: URL? {
    didSet { defaults.set(transcriptFolder?.path(percentEncoded: false), forKey: Keys.transcriptFolder) }
  }

  /// Where a finished Direct Dictation session's text goes: the paste that
  /// always happened, the clipboard alone, or both.
  var insertionDestination: InsertionDestination {
    didSet { defaults.set(insertionDestination.rawValue, forKey: Keys.insertionDestination) }
  }

  /// Whether finished dictation text is saved to the history folder. Off by
  /// default: persisting no recognized text is the standing privacy stance,
  /// and only the user turns this on.
  var dictationHistoryEnabled: Bool {
    didSet { defaults.set(dictationHistoryEnabled, forKey: Keys.historyEnabled) }
  }

  /// The history folder, kept even while history is off so turning it back
  /// on returns to the same place. Nil means the default `~/Documents/Dilo/`.
  var dictationHistoryFolder: URL? {
    didSet { defaults.set(dictationHistoryFolder?.path(percentEncoded: false), forKey: Keys.historyFolder) }
  }

  /// The folder history writes to right now: the user's pick, or the default.
  var resolvedHistoryFolder: URL {
    dictationHistoryFolder ?? DictationHistoryStore.defaultFolderURL
  }

  /// Lo que leen de estos ajustes el servidor MCP y el CLI
  /// (`FuenteDelHistorial`, 2026-10-15). Corren sin ventana y **sin crear
  /// `AppSettings`**: su `init` migra modos y escribe en `UserDefaults`, y un
  /// proceso que sólo lee no tiene por qué escribir nada. Las claves siguen
  /// siendo de este archivo; afuera se piden por acá, y se leen en cada
  /// llamada porque la app abierta puede cambiarlas mientras tanto.
  struct LecturaParaAgentes: Sendable, Equatable {
    var historialEncendido: Bool
    var carpetaDelHistorial: URL
    var palabrasPropias: [String]
  }

  nonisolated static func lecturaParaAgentes(de defaults: UserDefaults) -> LecturaParaAgentes {
    LecturaParaAgentes(
      // `bool(forKey:)` y no `as? Bool`: entiende también el `YES` de un
      // `-dictationHistoryEnabled YES` por la línea de comandos, y sin la
      // clave da `false`, que es el de fábrica.
      historialEncendido: defaults.bool(forKey: Keys.historyEnabled),
      carpetaDelHistorial: defaults.string(forKey: Keys.historyFolder).map { URL(filePath: $0) }
        ?? DictationHistoryStore.defaultFolderURL,
      palabrasPropias: defaults.stringArray(forKey: Keys.palabrasPropias) ?? []
    )
  }

  /// La versión de migración que ya corrió sobre estos ajustes. Cero en una
  /// instalación que nunca la vio.
  @ObservationIgnored
  private(set) var versionDeMigracionDeModos: Int

  /// Los modos de Dilo: nombre, prompt, proveedor y —si quieres— una tecla.
  /// Se guardan enteros como JSON; un valor ilegible vuelve a los de fábrica
  /// en vez de dejar la lista vacía.
  var modos: [Modo] {
    didSet {
      if let data = try? JSONEncoder().encode(modos) {
        defaults.set(data, forKey: Keys.modos)
      }
    }
  }

  /// El catálogo de proveedores, con la URL base y el modelo que cada quien
  /// configuró. **Las claves de API no están acá**: viven en el Llavero, y
  /// este valor se serializa a `UserDefaults`, que es texto plano.
  var proveedores: [Proveedor] {
    didSet {
      if let data = try? JSONEncoder().encode(proveedores) {
        defaults.set(data, forKey: Keys.proveedores)
      }
    }
  }

  /// El proveedor que usan los modos que no eligieron uno propio.
  ///
  /// Cualquier cambio anota que ya se decidió: desde ese momento la regla que
  /// lo pasa a Anthropic cuando hay clave no vuelve a mirar
  /// (`pasarElGeneralAClaudeSiCorresponde`).
  var proveedorGeneralID: String {
    didSet {
      defaults.set(proveedorGeneralID, forKey: Keys.proveedorGeneral)
      defaults.set(true, forKey: Keys.proveedorGeneralDecidido)
    }
  }

  /// Una vez, al arrancar: si el general sigue en el modelo de Apple, nadie
  /// lo cambió desde que existe esta regla y hay clave de Anthropic, los
  /// modos pasan a Claude Haiku 5.5 (Alfonso, 2026-10-19). El criterio y por
  /// qué está en `MigracionDeProveedores.generalConClave`.
  ///
  /// Fuera del `init` a propósito: preguntarle al Llavero desde un binario
  /// firmado distinto abre un diálogo que espera a un humano, y los tests
  /// crean `AppSettings` a cada rato. Lo llama `AppDelegate`, con el Llavero.
  func pasarElGeneralAClaudeSiCorresponde(claves: some AlmacenDeClaves) {
    guard let nuevo = MigracionDeProveedores.generalConClave(
      actual: proveedorGeneralID,
      yaSeDecidio: defaults.bool(forKey: Keys.proveedorGeneralDecidido),
      hayClaveDeAnthropic: {
        claves.tieneClave(para: Proveedor.anthropicDeFabrica.cuentaEnElLlavero)
      }
    ) else { return }
    proveedorGeneralID = nuevo
  }

  /// "Un atajo, Dilo decide": el modo se elige por la app al frente y el
  /// contenido, sin tecla propia. Apagada de fábrica (spec §7): quien no la
  /// prende tiene exactamente el comportamiento de siempre.
  var unAtajoDiloDecide: Bool {
    didSet { defaults.set(unAtajoDiloDecide, forKey: Keys.unAtajoDiloDecide) }
  }

  /// Los modos de fábrica vuelven, y vuelven sin tecla los que no la traían.
  func restaurarModosDeFabrica() {
    modos = Modo.deFabrica
  }

  /// Tus palabras: nombres, proyectos, siglas y términos técnicos que el
  /// motor no conoce. Se le pasan al motor como contexto **y** se corrigen
  /// después, porque el contexto ayuda pero no garantiza.
  var palabrasPropias: [String] {
    didSet { defaults.set(palabrasPropias, forKey: Keys.palabrasPropias) }
  }

  /// Si se limpian las muletillas del español. Prendido de fábrica: es lo que
  /// hace que el dictado salga listo para pegar sin pasar por ninguna IA.
  var limpiarMuletillas: Bool {
    didSet { defaults.set(limpiarMuletillas, forKey: Keys.limpiarMuletillas) }
  }

  /// Tu lista de muletillas. Vacía usa las de fábrica; con algo adentro
  /// reemplaza a las de fábrica enteras, que es lo que alguien quiere cuando
  /// se toma el trabajo de escribir una.
  var muletillasPropias: [String] {
    didSet { defaults.set(muletillasPropias, forKey: Keys.muletillasPropias) }
  }

  /// Si «coma», «punto», «nueva línea» y «borra eso» se convierten en lo
  /// que dicen. Prendido de fábrica: corre sin modelo y sin internet.
  var comandosDeFormato: Bool {
    didSet { defaults.set(comandosDeFormato, forKey: Keys.comandosDeFormato) }
  }

  /// «Cuando digo… / Escríbelo así». Se guarda como JSON; una lista que no
  /// se puede leer vuelve vacía en vez de tumbar los ajustes.
  var reemplazos: [Reemplazo] {
    didSet {
      if let datos = try? JSONEncoder().encode(reemplazos) {
        defaults.set(datos, forKey: Keys.reemplazos)
      }
    }
  }

  /// Qué le cuenta Dilo al modelo de texto sobre dónde dictas: la app, y si
  /// la persona lo prende, el texto alrededor del cursor, la selección y el
  /// sitio. Se guarda como JSON; uno ilegible vuelve a los de fábrica (sólo
  /// la app).
  var fuentesDeContexto: FuentesDeContexto {
    didSet {
      if let datos = try? JSONEncoder().encode(fuentesDeContexto) {
        defaults.set(datos, forKey: Keys.fuentesDeContexto)
      }
    }
  }

  /// Si Dilo mira el campo un rato después de pegar para ofrecer aprender
  /// lo que corregiste. Prendido de fábrica en el target directo: nunca
  /// agrega nada sin que lo aceptes en la muesca. En App Store no existe.
  var aprenderDeCorrecciones: Bool {
    didSet { defaults.set(aprenderDeCorrecciones, forKey: Keys.aprenderDeCorrecciones) }
  }

  /// Si el aprendizaje pasa por Claude: Haiku 5.5 revisa cada corrección
  /// antes de ofrecerla y Sonnet 5.5 ordena Tus palabras de vez en cuando.
  /// Prendido de fábrica (Alfonso, 2026-10-19: «déjalo, sí lo vamos a
  /// usar»). Sin clave de Anthropic no hace nada: el aprendizaje sigue como
  /// antes, sin red.
  var aprenderConClaude: Bool {
    didSet { defaults.set(aprenderConClaude, forKey: Keys.aprenderConClaude) }
  }

  /// El modelo que revisa cada corrección. Se guarda el id; uno que ya no
  /// está en la lista vuelve al de fábrica.
  var modeloParaRevisar: String {
    didSet { defaults.set(modeloParaRevisar, forKey: Keys.modeloParaRevisar) }
  }

  /// El modelo que ordena Tus palabras.
  var modeloParaOrdenar: String {
    didSet { defaults.set(modeloParaOrdenar, forKey: Keys.modeloParaOrdenar) }
  }

  /// La tecla de la **Conversación**. **Sin asignar de fábrica**: nil. Se
  /// empieza también desde el panel de la barra y con el atajo «Conversar
  /// con Dilo».
  var conversacionGatillo: KeyBinding? {
    didSet {
      if let conversacionGatillo {
        Self.store(conversacionGatillo, in: defaults, key: Keys.conversacionGatillo)
      } else {
        defaults.removeObject(forKey: Keys.conversacionGatillo)
      }
    }
  }

  /// Qué modelo contesta: automático (el router) o uno fijo.
  var conversacionModelo: EleccionDeModelo {
    didSet { defaults.set(conversacionModelo.rawValue, forKey: Keys.conversacionModelo) }
  }

  /// La voz que contesta, por identificador; vacío es la de fábrica.
  var conversacionVoz: String {
    didSet { defaults.set(conversacionVoz, forKey: Keys.conversacionVoz) }
  }

  /// Sobre la velocidad normal de la voz.
  var conversacionVelocidad: Double {
    didSet { defaults.set(conversacionVelocidad, forKey: Keys.conversacionVelocidad) }
  }

  /// Con qué micrófono escucha la conversación: aparte del dictado, porque
  /// para conversar quizás sirven los audífonos aunque se dicte con el del
  /// Mac. Automático de fábrica, con la misma regla (`PlanDeMicrofono`).
  var conversacionMicrofono: EleccionDeMicrofono {
    didSet {
      defaults.set(conversacionMicrofono.uidGuardado, forKey: Keys.conversacionMicrofonoUID)
      defaults.set(conversacionMicrofono.nombreGuardado, forKey: Keys.conversacionMicrofonoNombre)
    }
  }

  /// El tope de gasto mensual de la conversación, en dólares
  /// (`TopeDeGasto`).
  var conversacionTope: Double {
    didSet { defaults.set(conversacionTope, forKey: Keys.conversacionTope) }
  }

  /// Lo gastado este mes, sólo la suma (`GastoDelMes`).
  var conversacionGasto: GastoDelMes? {
    didSet { defaults.set(conversacionGasto?.guardado, forKey: Keys.conversacionGasto) }
  }

  /// A quién se le habla en la **Conversación**: los **Agente**s con su
  /// nombre, su tipo y si se llaman por nombre. JSON; una lista ilegible o
  /// vacía vuelve a los de fábrica (Dilo, Claude Code y Switchboard), porque
  /// una llamada sin nadie que conteste no sirve.
  var conversacionAgentes: [Agente] {
    didSet {
      if let datos = try? JSONEncoder().encode(conversacionAgentes) {
        defaults.set(datos, forKey: Keys.conversacionAgentes)
      }
    }
  }

  /// Los proyectos de Claude Code escritos a mano (nombre → carpeta). Le
  /// ganan a uno de `~/Developer` con el mismo nombre.
  var claudeCodeProyectos: [ProyectoDeClaudeCode] {
    didSet {
      if let data = try? JSONEncoder().encode(claudeCodeProyectos) {
        defaults.set(data, forKey: Keys.claudeCodeProyectos)
      }
    }
  }

  /// Los servidores MCP que la persona conectó (Ajustes → Claude →
  /// Conexiones MCP). JSON; ilegible vuelve a los de fábrica (Switchboard).
  /// Sin secretos: `ReglaDelEntorno` rechaza las variables que suenan a
  /// clave antes de guardarlas.
  var servidoresMCP: [ServidorMCPConfigurado] {
    didSet {
      if let datos = try? JSONEncoder().encode(servidoresMCP) {
        defaults.set(datos, forKey: Keys.servidoresMCP)
      }
    }
  }

  /// Si cada carpeta de `~/Developer` es un proyecto de fábrica.
  var claudeCodeIncluirDeveloper: Bool {
    didSet { defaults.set(claudeCodeIncluirDeveloper, forKey: Keys.claudeCodeIncluirDeveloper) }
  }

  /// La carpeta del último proyecto al que se le habló, para cuando no se
  /// nombra ninguno.
  var claudeCodeUltimoProyecto: String {
    didSet { defaults.set(claudeCodeUltimoProyecto, forKey: Keys.claudeCodeUltimoProyecto) }
  }

  /// Un alias de la CLI (`sonnet`, `opus`, `haiku`); vacío es el que tenga
  /// configurado la persona en su Claude Code.
  var claudeCodeModelo: String {
    didSet { defaults.set(claudeCodeModelo, forKey: Keys.claudeCodeModelo) }
  }

  /// Dónde está la CLI `claude`, si no está donde la deja el instalador.
  /// Vacío: se busca sola.
  var claudeCodeRuta: String {
    didSet { defaults.set(claudeCodeRuta, forKey: Keys.claudeCodeRuta) }
  }

  /// Las de Tus palabras que entraron de una corrección aceptada y no de
  /// Ajustes. Ordenar sólo quita solas éstas; las escritas a mano, las
  /// propone.
  var palabrasAprendidas: [String] {
    didSet { defaults.set(palabrasAprendidas, forKey: Keys.palabrasAprendidas) }
  }

  /// Cuántas entradas se aprendieron desde la última vez que se ordenó.
  var aprendidasDesdeElOrden: Int {
    didSet { defaults.set(aprendidasDesdeElOrden, forKey: Keys.aprendidasDesdeElOrden) }
  }

  /// La última pasada que terminó bien, y su firma del diccionario.
  var ultimaPasadaDelOrden: Date? {
    didSet { defaults.set(ultimaPasadaDelOrden, forKey: Keys.ultimaPasadaDelOrden) }
  }

  var firmaDelOrden: String? {
    didSet { defaults.set(firmaDelOrden, forKey: Keys.firmaDelOrden) }
  }

  /// El último intento automático, saliera bien o mal (`CuandoOrdenar`).
  var ultimoIntentoDelOrden: Date? {
    didSet { defaults.set(ultimoIntentoDelOrden, forKey: Keys.ultimoIntentoDelOrden) }
  }

  /// Lo que ordenar cambió y propuso, de la pasada más nueva a la más vieja.
  /// Son las palabras de la persona y el motivo que escribió el modelo:
  /// nada de lo dictado. Se guarda como JSON; uno ilegible vuelve vacío.
  var registroDelOrden: [PasadaDelOrden] {
    didSet {
      if let datos = try? JSONEncoder().encode(registroDelOrden) {
        defaults.set(datos, forKey: Keys.registroDelOrden)
      }
    }
  }

  /// Las pasadas que se guardan. Más viejas que esto ya no se deshacen.
  static let pasadasEnElRegistro = 20

  /// Tus palabras, «Cuando digo…» y lo aprendido, como lo lee el orden.
  var diccionario: Diccionario {
    get {
      Diccionario(palabras: palabrasPropias, reemplazos: reemplazos, aprendidas: Set(palabrasAprendidas))
    }
    set {
      palabrasPropias = newValue.palabras
      reemplazos = newValue.reemplazos
      // Sólo las que siguen en la lista: una aprendida que se quitó y
      // después se escribe a mano ya no es aprendida.
      palabrasAprendidas = newValue.palabras.filter(newValue.aprendidas.contains)
    }
  }

  /// Lo que `DiloText` necesita saber, armado en un solo lugar.
  var preferenciasDeTexto: DiloText.Preferencias {
    DiloText.Preferencias(
      muletillasPropias: limpiarMuletillas ? (muletillasPropias.isEmpty ? nil : muletillasPropias) : [],
      palabrasPropias: palabrasPropias,
      comandosDeFormato: comandosDeFormato,
      reemplazos: reemplazos
    )
  }

  var voiceVisual: HUDVoiceVisualStyle {
    didSet { defaults.set(voiceVisual.rawValue, forKey: Keys.voiceVisual) }
  }

  var waveformStyle: HUDWaveformStyle {
    didSet { defaults.set(waveformStyle.rawValue, forKey: Keys.waveformStyle) }
  }

  var revealStyle: HUDRevealStyle {
    didSet { defaults.set(revealStyle.rawValue, forKey: Keys.revealStyle) }
  }

  var longDraftStyle: HUDLongDraftStyle {
    didSet { defaults.set(longDraftStyle.rawValue, forKey: Keys.longDraftStyle) }
  }

  var glowPalette: HUDGlowPalette {
    didSet { defaults.set(glowPalette.rawValue, forKey: Keys.glowPalette) }
  }

  var glowCenter: HUDGlowCenterStyle {
    didSet { defaults.set(glowCenter.rawValue, forKey: Keys.glowCenter) }
  }

  /// How large the HUD shape is, as a fraction of the standard size.
  /// `HUDMetrics` clamps it to its supported range; a stored value outside
  /// that range comes back clamped rather than refused.
  var hudScale: Double {
    didSet { defaults.set(hudScale, forKey: Keys.hudScale) }
  }

  /// The Read Aloud voice's `AVSpeechSynthesisVoice` identifier; empty
  /// means the system default voice.
  /// Whether Read Aloud translates a selection into the voice's own language
  /// before speaking it. Off by default: Read Aloud has always read what was
  /// written, and translating without being asked would change what a shortcut
  /// someone already uses does.
  var readAloudTranslates: Bool {
    didSet { defaults.set(readAloudTranslates, forKey: Keys.readAloudTranslates) }
  }

  /// Qué forma se dibuja en una pantalla sin notch: la imitación del notch
  /// pegada al borde de arriba (el default desde el 2026-09-21) o la píldora
  /// que cuelga debajo de la barra de menús. Con notch real no se mira.
  var hudEstiloSinNotch: HUDEstiloSinNotch {
    didSet { defaults.set(hudEstiloSinNotch.rawValue, forKey: Keys.hudEstiloSinNotch) }
  }

  /// Con qué colores se dibujan la muesca, Ajustes y el ícono de la barra
  /// (`PaletaDeDilo`): Glaciar de fábrica o Grafito, en Apariencia → Color.
  /// Se aplica en vivo. Decisión del 2026-10-14: el mango salió.
  ///
  /// La clave nació con el makeover y nunca guardó otra cosa; un valor que
  /// ya no existe (`mango`, `menta`, de una copia de prueba) se lee como el
  /// de fábrica.
  var paleta: PaletaDeDilo.Nombre {
    didSet {
      defaults.set(paleta.rawValue, forKey: Keys.paleta)
      PaletaActiva.compartida.elegir(paleta)
    }
  }

  /// El panel del hover de vidrio ahumado, con un reflejo que cruza el canto
  /// al abrir (`PanelDeVidrio`); apagado, la misma forma en negro puro. **Encendido de fábrica** desde el
  /// 2026-10-14, con su interruptor en Ajustes → Apariencia: apagado y con
  /// la fila sólo en Debug nadie lo veía. Se lee cada vez que el panel se
  /// abre, y «Reducir transparencia» del sistema le gana
  /// (`FondoDeLaMuesca`).
  var hudPanelDeVidrio: Bool {
    didSet { defaults.set(hudPanelDeVidrio, forKey: Keys.hudPanelDeVidrio) }
  }

  /// Cuánto tiene que quedarse el puntero encima de la muesca antes de que se
  /// abra, en segundos.
  ///
  /// Configurable y no constante porque es la diferencia entre «me acerqué a
  /// mirar» y «pasé camino al menú», y dónde está esa línea depende de cómo
  /// mueve el mouse cada persona. Cero lo deja instantáneo, que es lo que
  /// alguien va a querer después de acostumbrarse.
  var hudRetardoDeHover: Double {
    didSet { defaults.set(hudRetardoDeHover, forKey: Keys.hudRetardoDeHover) }
  }

  /// En qué pantalla vive la muesca, por el nombre que macOS le da. Vacío es
  /// automática: la del cursor, o la principal.
  ///
  /// Se guarda el nombre y no el `CGDirectDisplayID` porque el id se reparte
  /// de nuevo en cada arranque y al reconectar un monitor: la elección
  /// aterrizaría en otra pantalla sola. Dos monitores del mismo modelo
  /// comparten nombre y ahí gana el primero, que es mejor que perder la
  /// elección entera.
  var hudPantalla: String {
    didSet { defaults.set(hudPantalla, forKey: Keys.hudPantalla) }
  }

  /// Si la muesca en reposo dice el nombre del modo activo.
  ///
  /// **Apagada de fábrica.** En reposo la muesca no dice nada: es la barra
  /// negra que ya estaba ahí. Quien quiera saber en qué modo quedó sin pasar
  /// el mouse la enciende, y entonces aparece un único dato, minúsculo y en
  /// gris.
  var hudModoEnReposo: Bool {
    didSet { defaults.set(hudModoEnReposo, forKey: Keys.hudModoEnReposo) }
  }

  /// Si la muesca queda fuera de las capturas y de lo que ve el otro lado al
  /// compartir pantalla.
  ///
  /// **Encendida de fábrica.** La muesca muestra lo que dictas, los recientes
  /// del portapapeles y la próxima reunión: nada de eso tiene que salir en una
  /// llamada. Se puede apagar para sacarle una captura a la propia muesca;
  /// el cambio se aplica al volver a abrir Dilo (`HUDPanel.init`).
  var hudOcultarAlCompartir: Bool {
    didSet { defaults.set(hudOcultarAlCompartir, forKey: Keys.hudOcultarAlCompartir) }
  }

  /// Qué fuentes van a los costados de la muesca en reposo —consumo de
  /// Claude o de Codex, CPU, RAM— y a cuál va cada una. Se elige en la
  /// sección «Datos en la muesca».
  ///
  /// **Nada de fábrica**: la muesca quieta es la barra negra que ya estaba
  /// ahí. Con cualquier dato encendido la muesca se alarga a los dos lados por
  /// igual, para seguir centrada sobre el notch.
  var hudDisposicion: DisposicionDeLaMuesca {
    didSet { defaults.set(hudDisposicion.guardado, forKey: Keys.hudDatosDeLaMuesca) }
  }

  /// Si el dato de Claude es el porcentaje de tu plan —preguntado a Anthropic
  /// con la sesión de Claude Code, como hace CodexBar— en vez de los tokens
  /// del bloque de cinco horas que quedan en disco.
  ///
  /// **Apagado de fábrica** porque leer esa sesión es leer una credencial del
  /// Llavero: macOS lo pregunta la primera vez, y esa pregunta tiene que
  /// llegar después de que alguien lo pidió, no por sorpresa.
  var hudPorcentajeDeClaude: Bool {
    didSet { defaults.set(hudPorcentajeDeClaude, forKey: Keys.hudPorcentajeDeClaude) }
  }

  /// Si la muesca se abre un momento a avisar cuando una IA cruza el 80 % o el
  /// 95 % de una ventana (`VigiaDeLimites`). **Encendido de fábrica**: sólo
  /// avisa de lo que alguien eligió mirar, y enterarse antes de chocar con el
  /// límite es justo para lo que se eligió.
  var hudAvisosDeLimite: Bool {
    didSet { defaults.set(hudAvisosDeLimite, forKey: Keys.hudAvisosDeLimite) }
  }

  /// Si la muesca muestra lo que los agentes de código avisan por su *hook*
  /// (`dilo://agente?…`, `AgentesEnLaMuesca`). **Encendido de fábrica**: no
  /// llega nada mientras nadie pegue la línea en su agente, y quien la pegó
  /// lo pidió. Apagado, las URL se ignoran y lo que había se retira.
  var hudAgentes: Bool {
    didSet { defaults.set(hudAgentes, forKey: Keys.hudAgentes) }
  }

  // MARK: El panel del hover

  /// Si los recientes del panel del hover suman lo que copias, además de tus
  /// dictados. Encendido de fábrica: es lo que se pidió (2026-09-24). Lo
  /// marcado como secreto por un gestor de contraseñas no entra nunca, y
  /// nada se guarda en disco (`VigiaDelPortapapeles`).
  var hudRecientesDelPortapapeles: Bool {
    didSet { defaults.set(hudRecientesDelPortapapeles, forKey: Keys.hudRecientesDelPortapapeles) }
  }

  /// Si el panel del hover ofrece los modos para elegir el del atajo general.
  var hudModosEnElPanel: Bool {
    didSet { defaults.set(hudModosEnElPanel, forKey: Keys.hudModosEnElPanel) }
  }

  /// El modo que usa el atajo general, elegido desde el panel del hover. Nil
  /// es el dictado normal, que no pasa por ninguna IA —lo de siempre—. Los
  /// modos con tecla propia siguen usando la suya.
  var hudModoDelAtajoGeneral: String? {
    didSet { defaults.set(hudModoDelAtajoGeneral, forKey: Keys.hudModoDelAtajoGeneral) }
  }

  /// Si el panel del hover muestra la próxima reunión del calendario. Apagado
  /// de fábrica: encenderlo pide permiso para leer el calendario.
  var hudProximaReunion: Bool {
    didSet { defaults.set(hudProximaReunion, forKey: Keys.hudProximaReunion) }
  }

  /// Si el panel del hover ofrece «Nota»: dictar algo que termina en Apple
  /// Notas, carpeta «Dilo». Encendida de fábrica —es un botón, no hace nada
  /// sin un clic—; la primera nota pide permiso para usar Notas.
  var hudNotaRapida: Bool {
    didSet { defaults.set(hudNotaRapida, forKey: Keys.hudNotaRapida) }
  }

  /// Si el panel del hover ofrece «Traducir»: dictar y que se pegue en el
  /// idioma elegido. Encendido de fábrica; sin idioma elegido el botón lleva
  /// a elegirlo.
  var hudTraducirEnElPanel: Bool {
    didSet { defaults.set(hudTraducirEnElPanel, forKey: Keys.hudTraducirEnElPanel) }
  }

  var readAloudVoiceID: String {
    didSet { defaults.set(readAloudVoiceID, forKey: Keys.readAloudVoice) }
  }

  /// Quién lee en voz alta: el `rawValue` de `MotorDeLectura`. Vacío es el
  /// de fábrica (Phonon), para que una instalación que nunca eligió siga al
  /// de fábrica si algún día cambia.
  var readAloudMotor: String {
    didSet { defaults.set(readAloudMotor, forKey: Keys.readAloudMotor) }
  }

  /// La voz de Phonon, por su nombre (`VozDePhonon.nombre`). Vacía es la de
  /// fábrica.
  var readAloudVozPhonon: String {
    didSet { defaults.set(readAloudVozPhonon, forKey: Keys.readAloudVozPhonon) }
  }

  var dictationTriggerBinding: KeyBinding {
    didSet { Self.store(dictationTriggerBinding, in: defaults, key: Keys.dictationTriggerBinding) }
  }

  var readAloudBinding: KeyBinding {
    didSet { Self.store(readAloudBinding, in: defaults, key: Keys.readAloudBinding) }
  }

  /// The dictation language, as a locale identifier; empty means follow the
  /// Mac's own language, which is what every session did before the Language
  /// section existed.
  /// Si los Primeros pasos ya se mostraron alguna vez. Sólo lo escribe la
  /// app al abrirlos; volver a abrirlos desde el menú no lo cambia, porque
  /// para eso está el menú.
  var onboardingVisto: Bool {
    didSet { defaults.set(onboardingVisto, forKey: Keys.onboardingVisto) }
  }

  /// La última versión cuyas novedades se mostraron. Vacía en una instalación
  /// nueva: ahí lo que corresponde es el onboarding, no un changelog de algo
  /// que la persona nunca usó.
  var versionVista: String {
    didSet { defaults.set(versionVista, forKey: Keys.versionVista) }
  }

  /// La sección de Ajustes que estaba a la vista al cerrar la ventana, por
  /// su `rawValue`, y cuándo se cerró. Volver a abrirla poco después la deja
  /// donde estaba (`SeccionAlAbrir`). Vacía: nunca se cerró.
  var ultimaSeccionDeAjustes: String {
    didSet { defaults.set(ultimaSeccionDeAjustes, forKey: Keys.ultimaSeccionDeAjustes) }
  }

  var ajustesCerradosEn: Date? {
    didSet { defaults.set(ajustesCerradosEn, forKey: Keys.ajustesCerradosEn) }
  }

  /// Si el dictado entra con minúscula y espacio a mitad de frase, y con
  /// mayúscula tras un punto (`AjusteAlCursor`). Apagado de fábrica hasta
  /// probarlo en apps reales: cambia el comienzo de cada dictado pegado.
  var mayusculaSegunElCursor: Bool {
    didSet { defaults.set(mayusculaSegunElCursor, forKey: Keys.mayusculaSegunElCursor) }
  }

  /// Si terminar con «envía» aprieta ↩ después de pegar (`EnvioHablado`).
  /// Apagado de fábrica: mandar un mensaje no se deshace.
  var envioHablado: Bool {
    didSet { defaults.set(envioHablado, forKey: Keys.envioHablado) }
  }

  /// Las frases que mandan. Vacías vuelven a las de fábrica: una lista vacía
  /// con el interruptor prendido no mandaría nunca y nadie sabría por qué.
  var frasesDeEnvio: [String] {
    didSet { defaults.set(frasesDeEnvio, forKey: Keys.frasesDeEnvio) }
  }

  /// Cuál **Motor de voz** dicta. La clave y el default viven en
  /// `EnginePreference` para poder probar la regla con `swift test`; acá
  /// sigue estando el único lugar de la app que la lee y la escribe.
  var motorDeVoz: SpeechEngineKind {
    didSet { EnginePreference.guardar(motorDeVoz, in: defaults) }
  }

  /// Cuál Parakeet dicta si están las dos en disco. Nil —el de fábrica— es
  /// «la mejor que haya» (`ResolucionDeParakeet`); se fija a mano con «Usar
  /// este» en Motor de voz. La clave vive en `PreferenciaDeVariante`, y el
  /// cargador del motor la lee de ahí en cada dictado.
  var varianteDeParakeet: VarianteDeParakeet? {
    didSet { PreferenciaDeVariante.guardar(varianteDeParakeet, in: defaults) }
  }

  /// Si Parakeet busca Tus palabras en el audio con la segunda pasada del
  /// CTC. Sin el CTC en disco no corre aunque esté encendido. La clave y el
  /// de fábrica viven en `PreferenciaDeTusPalabrasEnParakeet`.
  var tusPalabrasEnParakeet: Bool {
    didSet { defaults.set(tusPalabrasEnParakeet, forKey: PreferenciaDeTusPalabrasEnParakeet.clave) }
  }

  /// Cuánto aguanta el modelo de Parakeet en la RAM sin que dictes. La clave
  /// y el default viven en `PreferenciaDeReposo`, por lo mismo que el motor.
  var descargarModeloTras: DescargaPorReposo {
    didSet { PreferenciaDeReposo.guardar(descargarModeloTras, in: defaults) }
  }

  /// Cuánto es un toque corto del gatillo, en milisegundos. La clave, el
  /// rango y el default viven en `GestoDelGatillo`.
  var umbralDeToqueMs: Int {
    didSet { defaults.set(umbralDeToqueMs, forKey: GestoDelGatillo.claveDelUmbral) }
  }

  /// Si un Esc se puede deshacer con un clic en la muesca.
  var deshacerCancelacion: Bool {
    didSet { defaults.set(deshacerCancelacion, forKey: GestoDelGatillo.claveDeDeshacer) }
  }

  var recognitionLocaleIdentifier: String {
    didSet {
      defaults.set(recognitionLocaleIdentifier, forKey: Keys.recognitionLocale)
      // Choosing the second language as the first leaves one language behind
      // two keys, so the second turns off rather than becoming a duplicate.
      if !recognitionLocaleIdentifier.isEmpty,
       recognitionLocaleIdentifier == secondaryRecognitionLocaleIdentifier {
        secondaryRecognitionLocaleIdentifier = ""
      }
    }
  }

  /// The second language, with its own trigger. Empty means off, which is the
  /// default: one trigger, one language, exactly as before.
  var secondaryRecognitionLocaleIdentifier: String {
    didSet {
      defaults.set(
        secondaryRecognitionLocaleIdentifier,
        forKey: Keys.secondaryRecognitionLocale
      )
    }
  }

  var secondaryTriggerBinding: KeyBinding {
    didSet { Self.store(secondaryTriggerBinding, in: defaults, key: Keys.secondaryTriggerBinding) }
  }

  /// The trigger that dictates in the primary language and inserts a
  /// translation. Defaults to right command, which shares no key with fn:
  /// any fn combination would end a held plain session the moment its
  /// modifier arrived, because fn alone is already a trigger.
  var translateTriggerBinding: KeyBinding {
    didSet { Self.store(translateTriggerBinding, in: defaults, key: Keys.translateTriggerBinding) }
  }

  /// The language Dictate and Translate translates into, as a language code.
  /// Empty means off, which is the default: the trigger is not installed at
  /// all until a target is chosen, so an unconfigured key swallows nothing.
  var translationTargetIdentifier: String {
    didSet { defaults.set(translationTargetIdentifier, forKey: Keys.translationTarget) }
  }

  var isTranslationEnabled: Bool {
    !translationTargetIdentifier.isEmpty
  }

  /// Quién traduce, elegido en Ajustes → Idioma. Nil es el de fábrica:
  /// Claude si hay clave de Anthropic, Apple si no (`MotorDeTraduccion`).
  /// Se guarda el `rawValue`, y vacío es nil.
  var motorDeTraduccion: MotorDeTraduccion? {
    didSet { defaults.set(motorDeTraduccion?.rawValue ?? "", forKey: Keys.motorDeTraduccion) }
  }

  /// The pair a session would translate, or nil when translation is off or
  /// would translate a language into itself.
  func translationPair(from source: Locale) -> TranslationPair? {
    guard isTranslationEnabled else { return nil }
    let target = Locale.Language(identifier: translationTargetIdentifier)
    guard let sourceCode = source.language.languageCode?.identifier,
       let targetCode = target.languageCode?.identifier,
       sourceCode != targetCode
    else {
      return nil
    }
    return TranslationPair(source: source.language, target: target)
  }

  /// True once a second language is chosen. The second trigger is ignored
  /// while this is false, so an unused binding cannot start a session.
  /// The labels a split Drop Target shows, or empty when one language is
  /// configured and the target stays whole.
  var languageTagsForDrop: [String] {
    guard isSecondLanguageEnabled else { return [] }
    let primary = recognitionLocaleIdentifier.isEmpty
      ? Locale.current.identifier
      : recognitionLocaleIdentifier
    return [primary, secondaryRecognitionLocaleIdentifier]
      .map { SpeechLanguageCatalog.tag(for: Locale(identifier: $0)) }
  }

  /// Which language a drop chose. Index 1 is the second language and only
  /// exists while the target is split; anything else is the primary.
  func localeIdentifierForDrop(languageIndex: Int) -> String {
    guard languageIndex == 1, isSecondLanguageEnabled else {
      return recognitionLocaleIdentifier
    }
    return secondaryRecognitionLocaleIdentifier
  }

  var isSecondLanguageEnabled: Bool {
    !secondaryRecognitionLocaleIdentifier.isEmpty
  }

  /// Transient, never persisted: true while a Shortcuts input recorder is
  /// armed, so global trigger handling pauses and the rebind input cannot
  /// start a session.
  var isRecordingKeybind = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Marimba es el default desde 0.4.0: Synth8 sonaba a alarma sintética.
    // Quien ya eligió otro juego lo conserva — el valor guardado manda.
    soundSet = Self.stored(in: defaults, key: Keys.soundSet) ?? .marimba
    dictationSoundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
    microfonoDeDictado = EleccionDeMicrofono(
      uid: defaults.string(forKey: Keys.microfonoElegidoUID) ?? "",
      nombre: defaults.string(forKey: Keys.microfonoElegidoNombre) ?? ""
    )
    motorDeAudioTibio = defaults.bool(forKey: Keys.motorDeAudioTibio)
    // Apagado y sin interruptor. "Duck other audio" baja el volumen de
    // salida del sistema por Core Audio, y macOS muestra su propio HUD de
    // volumen cada vez. Dilo nunca toca el volumen maestro: si algún día
    // se silencia la música al dictar, se pausa la reproducción (spec §8.3).
    // El mecanismo (AudioDucker) queda con sus tests por si ese día llega.
    duckOtherAudioWhileDictating = false
    let storedSoundVolume = defaults.object(forKey: Keys.soundVolume) as? Double ?? 0.5
    storedDictationSoundVolume = DictationSoundSettings.normalizedVolume(storedSoundVolume)
    transcriptDestination = Self.stored(in: defaults, key: Keys.transcriptDestination) ?? .besideSource
    transcriptFolder = (defaults.string(forKey: Keys.transcriptFolder)).map { URL(filePath: $0) }
    insertionDestination = Self.stored(in: defaults, key: Keys.insertionDestination) ?? .insert
    dictationHistoryEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? false
    dictationHistoryFolder = (defaults.string(forKey: Keys.historyFolder)).map { URL(filePath: $0) }
    let proveedoresGuardados = Self.guardado([Proveedor].self, Keys.proveedores, in: defaults)
    // El Anthropic guardado con el modelo vacío pasa a Haiku 5.5, una vez
    // (2026-10-19). Uno escrito a mano no se toca. La marca va última, como
    // en la migración de modos.
    if let proveedoresGuardados, !defaults.bool(forKey: Keys.migracionModeloDeAnthropic) {
      let conModelo = MigracionDeProveedores.conModeloDeFabrica(proveedoresGuardados)
      if conModelo != proveedoresGuardados, let datos = try? JSONEncoder().encode(conModelo) {
        defaults.set(datos, forKey: Keys.proveedores)
      }
      defaults.set(true, forKey: Keys.migracionModeloDeAnthropic)
      proveedores = conModelo
    } else {
      proveedores = proveedoresGuardados ?? Proveedor.deFabrica
    }
    proveedorGeneralID = defaults.string(forKey: Keys.proveedorGeneral)
      ?? Proveedor.deFabrica[0].id

    // Las dos bibliotecas se juntan acá, una sola vez. La migración es pura y
    // vive en `DiloModes` con sus tests; este bloque sólo le pasa lo que hay
    // guardado y anota lo que devuelve.
    let migracion = MigracionDeModos.migrar(
      heredados: Self.guardado(
        [PromptHeredado].self, Keys.shapingPrompts, in: defaults
      ) ?? [],
      transformarEstabaPrendido: defaults.object(
        forKey: Keys.promptShapingEnabled
      ) as? Bool ?? false,
      modosGuardados: Self.guardado([Modo].self, Keys.modos, in: defaults),
      unAtajoDiloDecide: defaults.object(forKey: Keys.unAtajoDiloDecide) as? Bool ?? false,
      marca: defaults.integer(forKey: Keys.migracionDeModos)
    )
    modos = migracion.modos
    unAtajoDiloDecide = migracion.unAtajoDiloDecide
    versionDeMigracionDeModos = migracion.version
    if migracion.seMigro {
      // Los `didSet` no corren durante `init`, así que lo que la migración
      // decidió se escribe a mano. La marca va **última**: si el proceso
      // muere en el medio, la próxima vez vuelve a migrar sobre lo mismo y
      // el resultado es idéntico, que es lo que idempotente quiere decir.
      if let datos = try? JSONEncoder().encode(migracion.modos) {
        defaults.set(datos, forKey: Keys.modos)
      }
      defaults.set(migracion.unAtajoDiloDecide, forKey: Keys.unAtajoDiloDecide)
      defaults.set(migracion.version, forKey: Keys.migracionDeModos)
    }
    // Los sitios y las frases de los modos de fábrica, una vez, a quien ya
    // tenía modos guardados (`MigracionDeModos.sumarSenalesDeFabrica`). La
    // marca va última, por lo mismo que arriba.
    if !defaults.bool(forKey: Keys.migracionDeSenales) {
      let conSenales = MigracionDeModos.sumarSenalesDeFabrica(migracion.modos)
      if conSenales != migracion.modos {
        modos = conSenales
        if let datos = try? JSONEncoder().encode(conSenales) {
          defaults.set(datos, forKey: Keys.modos)
        }
      }
      defaults.set(true, forKey: Keys.migracionDeSenales)
    }
    palabrasPropias = defaults.stringArray(forKey: Keys.palabrasPropias) ?? []
    limpiarMuletillas = defaults.object(forKey: Keys.limpiarMuletillas) as? Bool ?? true
    muletillasPropias = defaults.stringArray(forKey: Keys.muletillasPropias) ?? []
    comandosDeFormato = defaults.object(forKey: Keys.comandosDeFormato) as? Bool ?? true
    reemplazos = defaults.data(forKey: Keys.reemplazos)
      .flatMap { try? JSONDecoder().decode([Reemplazo].self, from: $0) } ?? []
    fuentesDeContexto = defaults.data(forKey: Keys.fuentesDeContexto)
      .flatMap { try? JSONDecoder().decode(FuentesDeContexto.self, from: $0) } ?? .deFabrica
    aprenderDeCorrecciones = defaults.object(forKey: Keys.aprenderDeCorrecciones) as? Bool ?? true
    aprenderConClaude = defaults.object(forKey: Keys.aprenderConClaude) as? Bool ?? true
    modeloParaRevisar = defaults.string(forKey: Keys.modeloParaRevisar)
      .flatMap(ModelosDeAnthropic.conocido)?.id ?? ModelosDeAnthropic.deFabricaParaRevisar.id
    modeloParaOrdenar = defaults.string(forKey: Keys.modeloParaOrdenar)
      .flatMap(ModelosDeAnthropic.conocido)?.id ?? ModelosDeAnthropic.deFabricaParaOrdenar.id
    palabrasAprendidas = defaults.stringArray(forKey: Keys.palabrasAprendidas) ?? []
    conversacionGatillo = Self.storedBinding(
      in: defaults, key: Keys.conversacionGatillo, allowsMouseButton: true
    )
    conversacionModelo = Self.stored(in: defaults, key: Keys.conversacionModelo) ?? .automatico
    conversacionVoz = defaults.string(forKey: Keys.conversacionVoz) ?? ""
    conversacionVelocidad = defaults.object(forKey: Keys.conversacionVelocidad) as? Double ?? 1
    conversacionMicrofono = EleccionDeMicrofono(
      uid: defaults.string(forKey: Keys.conversacionMicrofonoUID) ?? "",
      nombre: defaults.string(forKey: Keys.conversacionMicrofonoNombre) ?? ""
    )
    conversacionTope = defaults.object(forKey: Keys.conversacionTope) as? Double ?? TopeDeGasto.deFabrica
    conversacionGasto = defaults.string(forKey: Keys.conversacionGasto).flatMap(GastoDelMes.init(guardado:))
    conversacionAgentes = Self.guardado([Agente].self, Keys.conversacionAgentes, in: defaults)
      .flatMap { $0.isEmpty ? nil : $0 } ?? Agente.deFabrica
    servidoresMCP = Self.guardado([ServidorMCPConfigurado].self, Keys.servidoresMCP, in: defaults)
      ?? ServidorMCPConfigurado.deFabrica
    claudeCodeProyectos = Self.guardado([ProyectoDeClaudeCode].self, Keys.claudeCodeProyectos, in: defaults) ?? []
    claudeCodeIncluirDeveloper = defaults.object(forKey: Keys.claudeCodeIncluirDeveloper) as? Bool ?? true
    claudeCodeUltimoProyecto = defaults.string(forKey: Keys.claudeCodeUltimoProyecto) ?? ""
    claudeCodeModelo = defaults.string(forKey: Keys.claudeCodeModelo) ?? ""
    claudeCodeRuta = defaults.string(forKey: Keys.claudeCodeRuta) ?? ""
    aprendidasDesdeElOrden = defaults.integer(forKey: Keys.aprendidasDesdeElOrden)
    ultimaPasadaDelOrden = defaults.object(forKey: Keys.ultimaPasadaDelOrden) as? Date
    firmaDelOrden = defaults.string(forKey: Keys.firmaDelOrden)
    ultimoIntentoDelOrden = defaults.object(forKey: Keys.ultimoIntentoDelOrden) as? Date
    registroDelOrden = defaults.data(forKey: Keys.registroDelOrden)
      .flatMap { try? JSONDecoder().decode([PasadaDelOrden].self, from: $0) } ?? []
    voiceVisual = Self.stored(in: defaults, key: Keys.voiceVisual) ?? .waveform
    // Siri Wave de fábrica: lo eligió Alfonso al ver la píldora (2026-09-21).
    waveformStyle = Self.stored(in: defaults, key: Keys.waveformStyle) ?? .brasas
    revealStyle = Self.stored(in: defaults, key: Keys.revealStyle) ?? .slide
    longDraftStyle = Self.stored(in: defaults, key: Keys.longDraftStyle) ?? .growDown
    glowPalette = Self.stored(in: defaults, key: Keys.glowPalette) ?? .spectrum
    glowCenter = Self.stored(in: defaults, key: Keys.glowCenter) ?? .particles
    // `double(forKey:)` reads a missing key as zero, which would start every
    // existing user at the smallest HUD, so absence is checked directly.
    hudScale = defaults.object(forKey: Keys.hudScale) as? Double
      ?? Double(HUDMetrics.maximumScale)
    // Sin nada guardado manda el notch simulado (2026-09-21): el escenario de
    // Dilo es el notch, y en una pantalla sin carcasa la imitación es lo que
    // más se le parece. Ocupa sólo la franja del centro de la barra de menús,
    // que macOS deja vacía, así que sigue sin tapar un status item.
    //
    // Quien eligió a mano conserva su elección, y quien había **encendido**
    // el interruptor viejo pedía justamente que la forma despejara la barra:
    // esa elección vale como haber elegido la píldora. El interruptor apagado
    // quería la forma donde iría el notch, que es el default de hoy.
    hudEstiloSinNotch = Self.stored(in: defaults, key: Keys.hudEstiloSinNotch)
      ?? (defaults.object(forKey: Keys.hudClearsMenuBar) as? Bool == true ? .pildora : .notchSimulado)
    // Leerla no la aplica: la paleta activa es una por proceso, y un
    // `AppSettings` de un test no puede pintar la app. La aplica `AppDelegate`.
    paleta = Self.stored(in: defaults, key: Keys.paleta) ?? .deFabrica
    // `bool(forKey:)` lee la clave ausente como apagado; el de fábrica es
    // encendido, así que la ausencia se pregunta directo.
    hudPanelDeVidrio = defaults.object(forKey: Keys.hudPanelDeVidrio) as? Bool ?? true
    // `double(forKey:)` lee una clave ausente como cero, que dejaría el hover
    // instantáneo para todo el mundo; la ausencia se pregunta directo.
    hudRetardoDeHover = defaults.object(forKey: Keys.hudRetardoDeHover) as? Double
      ?? HUDStage.retardoDeHoverDeFabrica
    hudPantalla = defaults.string(forKey: Keys.hudPantalla) ?? ""
    hudModoEnReposo = defaults.bool(forKey: Keys.hudModoEnReposo)
    hudOcultarAlCompartir = defaults.object(forKey: Keys.hudOcultarAlCompartir) as? Bool ?? true
    hudDisposicion = defaults.string(forKey: Keys.hudDatosDeLaMuesca)
      .map(DisposicionDeLaMuesca.init(guardado:))
      ?? .migrada(
        izquierdo: Self.stored(in: defaults, key: Keys.hudDatoIzquierdo) ?? .ninguno,
        derecho: Self.stored(in: defaults, key: Keys.hudDatoDerecho) ?? .ninguno
      )
    hudPorcentajeDeClaude = defaults.bool(forKey: Keys.hudPorcentajeDeClaude)
    hudAvisosDeLimite = defaults.object(forKey: Keys.hudAvisosDeLimite) as? Bool ?? true
    hudAgentes = defaults.object(forKey: Keys.hudAgentes) as? Bool ?? true
    hudRecientesDelPortapapeles = defaults.object(forKey: Keys.hudRecientesDelPortapapeles) as? Bool ?? true
    hudModosEnElPanel = defaults.object(forKey: Keys.hudModosEnElPanel) as? Bool ?? true
    hudModoDelAtajoGeneral = defaults.string(forKey: Keys.hudModoDelAtajoGeneral)
    hudProximaReunion = defaults.bool(forKey: Keys.hudProximaReunion)
    hudNotaRapida = defaults.object(forKey: Keys.hudNotaRapida) as? Bool ?? true
    hudTraducirEnElPanel = defaults.object(forKey: Keys.hudTraducirEnElPanel) as? Bool ?? true
    readAloudVoiceID = defaults.string(forKey: Keys.readAloudVoice) ?? ""
    readAloudTranslates = defaults.bool(forKey: Keys.readAloudTranslates)
    readAloudMotor = defaults.string(forKey: Keys.readAloudMotor) ?? ""
    readAloudVozPhonon = defaults.string(forKey: Keys.readAloudVozPhonon) ?? ""
    dictationTriggerBinding = Self.storedBinding(
      in: defaults,
      key: Keys.dictationTriggerBinding,
      allowsMouseButton: true
    ) ?? .fnTrigger
    readAloudBinding = Self.storedBinding(
      in: defaults,
      key: Keys.readAloudBinding,
      allowsMouseButton: false
    ) ?? .optionEscape
    onboardingVisto = defaults.bool(forKey: Keys.onboardingVisto)
    versionVista = defaults.string(forKey: Keys.versionVista) ?? ""
    ultimaSeccionDeAjustes = defaults.string(forKey: Keys.ultimaSeccionDeAjustes) ?? ""
    ajustesCerradosEn = defaults.object(forKey: Keys.ajustesCerradosEn) as? Date
    motorDeVoz = EnginePreference.leer(defaults)
    mayusculaSegunElCursor = defaults.bool(forKey: Keys.mayusculaSegunElCursor)
    envioHablado = defaults.bool(forKey: Keys.envioHablado)
    frasesDeEnvio = defaults.stringArray(forKey: Keys.frasesDeEnvio) ?? EnvioHablado.frasesDeFabrica
    varianteDeParakeet = PreferenciaDeVariante.leer(defaults)
    tusPalabrasEnParakeet = PreferenciaDeTusPalabrasEnParakeet.leer(defaults)
    descargarModeloTras = PreferenciaDeReposo.leer(defaults)
    umbralDeToqueMs = GestoDelGatillo.umbralMs(en: defaults)
    deshacerCancelacion = GestoDelGatillo.deshacer(en: defaults)
    recognitionLocaleIdentifier = defaults.string(forKey: Keys.recognitionLocale) ?? ""
    secondaryRecognitionLocaleIdentifier =
      defaults.string(forKey: Keys.secondaryRecognitionLocale) ?? ""
    secondaryTriggerBinding = Self.storedBinding(
      in: defaults,
      key: Keys.secondaryTriggerBinding,
      allowsMouseButton: true
    ) ?? .controlOptionSpace
    translateTriggerBinding = Self.storedBinding(
      in: defaults,
      key: Keys.translateTriggerBinding,
      allowsMouseButton: true
    ) ?? .rightCommandTrigger
    translationTargetIdentifier = defaults.string(forKey: Keys.translationTarget) ?? ""
    motorDeTraduccion = defaults.string(forKey: Keys.motorDeTraduccion)
      .flatMap(MotorDeTraduccion.init(rawValue:))
  }

  private static func stored<Value: RawRepresentable<String>>(
    in defaults: UserDefaults,
    key: String
  ) -> Value? {
    defaults.string(forKey: key).flatMap { Value(rawValue: $0) }
  }

  /// `allowsMouseButton` is false for Read Aloud, which fires from keyDown
  /// and so has no mouse path at all: a stored mouse binding there could only
  /// ever be dead.
  private static func storedBinding(
    in defaults: UserDefaults,
    key: String,
    allowsMouseButton: Bool
  ) -> KeyBinding? {
    guard let data = defaults.data(forKey: key),
       let binding = try? JSONDecoder().decode(KeyBinding.self, from: data),
       allowsMouseButton || !binding.isMouseButton
    else { return nil }
    return binding
  }

  /// Un valor de Dilo guardado como JSON, o nil si no está o no se puede
  /// leer. Un JSON roto vale lo mismo que uno ausente: se reseminan los de
  /// fábrica, que es mejor que una pantalla vacía sin explicación.
  private static func guardado<T: Decodable>(
    _: T.Type, _ clave: String, in defaults: UserDefaults
  ) -> T? {
    guard let data = defaults.data(forKey: clave) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private static func store(_ binding: KeyBinding, in defaults: UserDefaults, key: String) {
    if let data = try? JSONEncoder().encode(binding) {
      defaults.set(data, forKey: key)
    }
  }

  func binding(for role: BindingRole) -> KeyBinding {
    switch role {
    case .dictation: dictationTriggerBinding
    case .secondLanguage: secondaryTriggerBinding
    case .translate: translateTriggerBinding
    case .readAloud: readAloudBinding
    }
  }

  func setBinding(_ binding: KeyBinding, for role: BindingRole) {
    switch role {
    case .dictation: dictationTriggerBinding = binding
    case .secondLanguage: secondaryTriggerBinding = binding
    case .translate: translateTriggerBinding = binding
    case .readAloud: readAloudBinding = binding
    }
  }

  /// The role already using this exact input and modifiers, if any.
  ///
  /// One rule in one place: the recorders, the Language section and
  /// `setBindings` would otherwise each decide for themselves what clashes.
  /// A second language that is off holds no binding, so it clashes with
  /// nothing. Only the input matters — the same binding recorded and clicked
  /// carries a different label, and comparing whole values would miss it.
  func roleUsing(_ candidate: KeyBinding, excluding role: BindingRole) -> BindingRole? {
    BindingRole.allCases.first { other in
      guard other != role else { return false }
      guard other != .secondLanguage || isSecondLanguageEnabled else { return false }
      // A translate trigger that has no target holds no binding, so an
      // unconfigured one must not report a clash with a real binding.
      guard other != .translate || isTranslationEnabled else { return false }
      return binding(for: other).hasSameInputAndModifiers(as: candidate)
    }
  }

  /// El id con que un rol aparece entre los atajos ocupados. Con prefijo para
  /// que nunca choque con el id de un modo.
  static func idDeRol(_ role: BindingRole) -> String { "rol.\(role)" }

  /// El id de la tecla de conversar entre los atajos ocupados.
  static let idDeConversar = "rol.conversar"

  /// **Todos** los atajos que hoy tienen tecla en Dilo: los cuatro roles y
  /// cada modo, con el nombre que se le muestra a la persona.
  ///
  /// Es la lista que `ValidadorDeGatillos` necesita para que una tecla no se
  /// pueda asignar dos veces. Antes cada pantalla revisaba lo suyo —Modos
  /// contra los otros modos, Atajos contra los cuatro roles— y así la tecla
  /// del dictado y la de un modo podían quedar iguales: el modo no disparaba
  /// nunca y nada lo decía.
  var gatillosEnUso: [ValidadorDeGatillos.GatilloEnUso] {
    var ocupados = BindingRole.allCases.compactMap { rol -> ValidadorDeGatillos.GatilloEnUso? in
      // Un segundo idioma apagado o un traducir sin destino no tienen tecla
      // instalada, así que no le quitan nada a nadie.
      if rol == .secondLanguage, !isSecondLanguageEnabled { return nil }
      if rol == .translate, !isTranslationEnabled { return nil }
      return ValidadorDeGatillos.GatilloEnUso(
        id: Self.idDeRol(rol), nombre: rol.title, gatillo: binding(for: rol).gatillo
      )
    }
    // La tecla de conversar, cuando la hay: una tecla que el dictado y la
    // conversación compartieran dejaría a una de las dos sin disparar.
    if let conversacionGatillo {
      ocupados.append(ValidadorDeGatillos.GatilloEnUso(
        id: Self.idDeConversar, nombre: String(localized: "Conversar"), gatillo: conversacionGatillo.gatillo
      ))
    }
    ocupados += modos.compactMap { modo in
      modo.gatillo.map {
        ValidadorDeGatillos.GatilloEnUso(id: modo.id, nombre: modo.nombre, gatillo: $0)
      }
    }
    return ocupados
  }

  /// Quién más usa esta tecla, por nombre. Cubre roles y modos, que es lo que
  /// `roleUsing` no alcanza a ver.
  func quienUsa(_ candidato: KeyBinding, salvo id: String) -> String? {
    let gatillo = candidato.gatillo
    return gatillosEnUso
      .first { $0.id != id && $0.gatillo.disparaLoMismoQue(gatillo) }?
      .nombre
  }
}

/// Which recorded binding is being talked about. Shared so the Shortcuts
/// section, the Language section and the event tap all name the same three
/// roles.
enum BindingRole: Hashable, CaseIterable {
  case dictation
  case secondLanguage
  case translate
  case readAloud

  var title: String {
    switch self {
    case .dictation: String(localized: "Dictado")
    case .secondLanguage: String(localized: "Segundo idioma")
    case .translate: String(localized: "Traducir")
    case .readAloud: String(localized: "Leer en voz alta")
    }
  }
}

/// The preferences captured when Direct Dictation starts. A session keeps
/// this value until its end and paste sounds have played.
struct DictationSessionSettings: Equatable {
  let sounds: DictationSoundSettings
  let insertionDestination: InsertionDestination
  /// The translation this session performs, or nil when it inserts the words
  /// as spoken. Captured with everything else: changing the target
  /// mid-session must not redirect the session already under way (ADR-0004).
  let translation: TranslationPair?
  /// Con qué traduce esta sesión, resuelto al apretar la tecla. Congelado
  /// como todo lo demás (ADR-0004): sólo importa si `translation` no es nil.
  let motorDeTraduccion: MotorDeTraduccion.Resuelto
  let historyEnabled: Bool
  let historyFolder: URL
  /// Captured with everything else: a session that started while ducking was
  /// on has to restore the volume even if the toggle flips mid-session.
  let ducksOtherAudio: Bool
  /// La biblioteca de modos entera, congelada al empezar: es lo que las
  /// flechas recorren mientras hablas, y leerla de Ajustes a mitad de camino
  /// dejaría la lista cambiando debajo de la persona.
  let modos: [Modo]
  /// Si el atajo principal puede elegir modo por reglas en esta sesión.
  let unAtajoDiloDecide: Bool
  /// El catálogo de proveedores y el general, también congelados. Con esto y
  /// `proveedoresConClave` la sesión resuelve **su** proveedor al terminar sin
  /// volver a mirar Ajustes: cambiarlos a mitad de dictado aplica al
  /// siguiente (ADR-0004), y eso es lo que impide que un modo que empezó
  /// local termine saliendo a una nube.
  let proveedores: [Proveedor]
  let proveedorGeneralID: String
  /// Qué proveedores tenían clave cuando esto empezó. Se pregunta al Llavero
  /// una vez por sesión y sólo por los que la necesitan.
  let proveedoresConClave: Set<String>
  /// Las reglas de español que aplican a esta sesión: muletillas y tus
  /// palabras. Se capturan como todo lo demás, para que editar el
  /// diccionario a mitad de dictado no cambie el dictado en vuelo (ADR-0004).
  let textoPreferencias: DiloText.Preferencias
  let voiceVisual: HUDVoiceVisualStyle
  let waveformStyle: HUDWaveformStyle
  let revealStyle: HUDRevealStyle
  let longDraftStyle: HUDLongDraftStyle
  let glowPalette: HUDGlowPalette
  let glowCenter: HUDGlowCenterStyle
  let hudMetrics: HUDMetrics
  /// Si la muesca en reposo dice el nombre del modo activo. Viaja con la
  /// sesión como todo lo demás que la forma dibuja, aunque el reposo no sea
  /// una sesión: es el escenario el que lo lee, y lee un solo objeto.
  let muestraElModoEnReposo: Bool
  /// El modo que usa el atajo general, elegido en el panel del hover, o nil.
  let modoDelAtajoGeneralID: String?
  /// Si el dictado se adapta a lo que hay antes del cursor.
  let ajustarAlCursor: Bool
  /// Las frases que mandan el mensaje, o nil con «envía» apagado.
  let frasesDeEnvio: [String]?

  /// The colour a Drop Transcription wears — on the HUD's target and card, and
  /// on the status ghost while a file job fills it. Edge Glow and Edge Glow +
  /// Draft lend the palette's own hue; every other visual keeps the HUD's own blue.
  /// One definition, so the shape and the menu bar can never drift apart
  /// (CONTEXT.md).
  var dropAccent: NSColor {
    voiceVisual.usesEdgeGlow ? glowPalette.statusAccent : SettingsTheme.accentColor
  }

  /// Sólo los proveedores que esta sesión podría llegar a usar **y** que
  /// piden clave: el general y los que algún modo eligió.
  ///
  /// Preguntarle al Llavero por el modelo del chip sería una consulta al
  /// sistema para nada, y esto corre al empezar cada dictado, donde los
  /// milisegundos se cuentan (spec §3). Y hay una razón más fuerte: leer un
  /// ítem del Llavero desde un binario firmado distinto abre un diálogo que
  /// espera a un humano, y eso colgaría la suite igual que lo hacía TCC. Con
  /// los ajustes de fábrica —todo en el chip— no se consulta nada.
  private static func conClave(
    _ proveedores: [Proveedor],
    general: String,
    modos: [Modo],
    en claves: some AlmacenDeClaves
  ) -> Set<String> {
    let alcanzables = Set([general] + modos.compactMap(\.proveedorID))
    return Set(
      proveedores
        .filter { alcanzables.contains($0.id) && $0.necesitaClave }
        .filter { claves.tieneClave(para: $0.cuentaEnElLlavero) }
        .map(\.id)
    )
  }

  /// El proveedor con que este modo corre en **esta** sesión, resuelto contra
  /// la foto que se tomó al empezar. No hay respaldo: si falla, se dice.
  func proveedorDeSesion(para modo: Modo) -> ResolucionDeProveedor.DeSesion {
    ResolucionDeProveedor.deSesion(
      para: modo,
      general: proveedorGeneralID,
      catalogo: proveedores,
      tieneClave: { proveedoresConClave.contains($0.id) }
    )
  }

  /// El modo cuya tecla es ésta, dentro de la biblioteca congelada.
  func modo(delGatillo gatillo: Gatillo?) -> Modo? {
    guard let gatillo else { return nil }
    return ResolucionDeModo.porAtajo(gatillo, entre: modos)
  }

  /// - Parameter claves: el Llavero, o uno de mentira en los tests. Se
  ///   consulta una vez por sesión y sólo por los proveedores que piden clave.
  @MainActor
  init(
    settings: AppSettings,
    translation: TranslationPair? = nil,
    motorDeTraduccion: MotorDeTraduccion.Resuelto = .apple,
    claves: some AlmacenDeClaves = Llavero()
  ) {
    self.translation = translation
    self.motorDeTraduccion = motorDeTraduccion
    sounds = DictationSoundSettings(
      set: settings.soundSet,
      isEnabled: settings.dictationSoundsEnabled,
      volume: settings.dictationSoundVolume
    )
    insertionDestination = settings.insertionDestination
    historyEnabled = settings.dictationHistoryEnabled
    historyFolder = settings.resolvedHistoryFolder
    ducksOtherAudio = settings.duckOtherAudioWhileDictating
    modos = settings.modos
    unAtajoDiloDecide = settings.unAtajoDiloDecide
    proveedores = settings.proveedores
    proveedorGeneralID = settings.proveedorGeneralID
    proveedoresConClave = Self.conClave(
      settings.proveedores,
      general: settings.proveedorGeneralID,
      modos: settings.modos,
      en: claves
    )
    textoPreferencias = settings.preferenciasDeTexto
    voiceVisual = settings.voiceVisual
    waveformStyle = settings.waveformStyle
    revealStyle = settings.revealStyle
    longDraftStyle = settings.longDraftStyle
    glowPalette = settings.glowPalette
    glowCenter = settings.glowCenter
    hudMetrics = HUDMetrics(scale: CGFloat(settings.hudScale))
    muestraElModoEnReposo = settings.hudModoEnReposo
    modoDelAtajoGeneralID = settings.hudModoDelAtajoGeneral
    ajustarAlCursor = settings.mayusculaSegunElCursor
    let frases = settings.frasesDeEnvio.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    frasesDeEnvio = settings.envioHablado ? (frases.isEmpty ? EnvioHablado.frasesDeFabrica : frases) : nil
  }
}

extension AppSettings {
  var sessionSettings: DictationSessionSettings {
    DictationSessionSettings(settings: self)
  }
}

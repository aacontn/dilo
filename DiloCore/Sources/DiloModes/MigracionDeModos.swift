import Foundation

/// Un prompt de "Transformar", tal como Talkify lo dejó guardado.
///
/// Existe sólo para leer lo viejo. Los nombres de campo son los de la clase
/// que ya no existe (`ShapingPrompt`), porque el JSON que hay en
/// `UserDefaults` los tiene escritos así y renombrarlos sería perder la
/// biblioteca de quien ya escribió sus prompts.
public struct PromptHeredado: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var preInstruction: String
  public var postInstruction: String
  public var exampleInput: String
  public var exampleOutput: String

  public init(
    id: String,
    name: String,
    preInstruction: String = "",
    postInstruction: String = "",
    exampleInput: String = "",
    exampleOutput: String = ""
  ) {
    self.id = id
    self.name = name
    self.preInstruction = preInstruction
    self.postInstruction = postInstruction
    self.exampleInput = exampleInput
    self.exampleOutput = exampleOutput
  }

  /// Los tres que Talkify sembraba en una instalación limpia. Se conservan
  /// para reconocerlos: un prompt que nadie tocó no merece volverse un modo
  /// duplicado al lado de los de fábrica de Dilo.
  public static let sembradosPorTalkify: Set<String> = [
    "tighten-grammar", "bullet-lists", "remove-fillers",
  ]
}

/// De dos bibliotecas a una sola.
///
/// Dilo venía arrastrando dos listas que hacían lo mismo: los `Modo` de Dilo
/// y los prompts de "Transformar" heredados de Talkify. El dictado usaba los
/// segundos y los primeros no llegaban al controlador, así que las teclas de
/// los modos no disparaban nada y el historial guardaba como modo el nombre
/// de un prompt. Esta migración deja una sola biblioteca.
///
/// Es una función pura y **idempotente**: recibe lo que hay, devuelve lo que
/// debe quedar, y la marca de que ya corrió es parte de la entrada. Correrla
/// dos veces no duplica nada. Los datos viejos no se borran acá — se dejan en
/// `UserDefaults` una versión más, por si algo salió mal.
public enum MigracionDeModos {
  /// La versión de la migración. Sube cuando haya que volver a pasar por acá
  /// con reglas nuevas; una marca menor a ésta vuelve a correr.
  public static let version = 1

  public struct Resultado: Equatable, Sendable {
    public var modos: [Modo]
    /// Prendido cuando el dictado normal venía transformando siempre. Es lo
    /// más cerca que queda de esa costumbre sin resucitar el "modo activo":
    /// el atajo principal elige modo por reglas y, si no lo tiene claro, no
    /// toca nada (spec §7).
    public var unAtajoDiloDecide: Bool
    /// La marca que se persiste. Igual a `version` cuando algo se hizo.
    public var version: Int
    /// Falso cuando la marca ya estaba al día y no se tocó nada.
    public var seMigro: Bool

    public init(
      modos: [Modo], unAtajoDiloDecide: Bool, version: Int, seMigro: Bool
    ) {
      self.modos = modos
      self.unAtajoDiloDecide = unAtajoDiloDecide
      self.version = version
      self.seMigro = seMigro
    }
  }

  /// El proveedor con que llegan los modos migrados.
  ///
  /// El del chip, siempre, aunque el proveedor general sea una nube. Los
  /// prompts de Talkify corrían en FoundationModels: el texto nunca salía de
  /// la compu, y heredar el general los mandaría a un servidor sin que nadie
  /// lo pida. Cambiar local por remoto en silencio es exactamente lo que
  /// esta pasada existe para impedir.
  public static let proveedorDeLosMigrados = "chip"

  /// - Parameters:
  ///   - heredados: la biblioteca de "Transformar" tal como está guardada.
  ///   - transformarEstabaPrendido: el interruptor beta de Talkify.
  ///   - modosGuardados: los `Modo` que ya existen, o nil si nunca se
  ///     guardaron (instalación nueva, o una anterior a que existieran).
  ///   - marca: la versión de migración que quedó anotada; 0 si ninguna.
  public static func migrar(
    heredados: [PromptHeredado],
    transformarEstabaPrendido: Bool,
    modosGuardados: [Modo]?,
    unAtajoDiloDecide: Bool,
    marca: Int
  ) -> Resultado {
    guard marca < version else {
      return Resultado(
        modos: modosGuardados ?? Modo.deFabrica,
        unAtajoDiloDecide: unAtajoDiloDecide,
        version: marca,
        seMigro: false
      )
    }

    var modos = modosGuardados ?? []

    // Los de fábrica de Dilo entran si no están. "Si no están" es por id: a
    // uno renombrado o editado no se le pisa nada.
    for deFabrica in Modo.deFabrica where !modos.contains(where: { $0.id == deFabrica.id }) {
      modos.append(deFabrica)
    }

    for heredado in heredados {
      let id = idDeModo(heredado.id)
      // Ya migrado: la migración corrió antes, o alguien lo trajo a mano.
      guard !modos.contains(where: { $0.id == id }) else { continue }
      // Los tres que Talkify sembraba y nadie tocó ya los cubren los de
      // fábrica de Dilo; traerlos sería llenar la lista de duplicados.
      if PromptHeredado.sembradosPorTalkify.contains(heredado.id), esComoVino(heredado) {
        continue
      }
      modos.append(modo(de: heredado))
    }

    return Resultado(
      modos: modos,
      // Sólo se prende, nunca se apaga: quien ya lo tenía prendido lo sigue
      // teniendo, y quien tenía "Transformar" prendido conserva la costumbre
      // de que el atajo principal haga algo con lo dictado.
      unAtajoDiloDecide: unAtajoDiloDecide || transformarEstabaPrendido,
      version: version,
      seMigro: true
    )
  }

  /// El id del modo que sale de un prompt heredado. Con prefijo para que no
  /// choque nunca con un id de fábrica de Dilo ni con un UUID de uno nuevo.
  public static func idDeModo(_ idHeredado: String) -> String {
    "heredado.\(idHeredado)"
  }

  static func modo(de heredado: PromptHeredado) -> Modo {
    Modo(
      id: idDeModo(heredado.id),
      nombre: heredado.name,
      prompt: heredado.preInstruction,
      instruccionFinal: heredado.postInstruction,
      ejemploEntrada: heredado.exampleInput,
      ejemploSalida: heredado.exampleOutput,
      proveedorID: proveedorDeLosMigrados,
      // Sin tecla: los prompts de Talkify no tenían ninguna, y repartir
      // teclas por cuenta propia es la forma más rápida de chocar con las
      // que la persona ya usa. Cada quien le asigna la suya en Ajustes.
      gatillo: nil,
      esDeFabrica: false
    )
  }

  /// Si este prompt es idéntico al que Talkify sembraba. Se compara sólo lo
  /// que se puede editar; el id ya se sabe que coincide.
  static func esComoVino(_ heredado: PromptHeredado) -> Bool {
    guard let original = semillasDeTalkify.first(where: { $0.id == heredado.id }) else {
      return false
    }
    return original == heredado
  }

  /// Las semillas exactas de Talkify 0.8.3, ya en español porque Dilo las
  /// tradujo antes de este cambio. Están acá sólo para reconocerlas.
  static let semillasDeTalkify: [PromptHeredado] = [
    PromptHeredado(
      id: "tighten-grammar",
      name: "Ortografía y puntuación",
      preInstruction: "Arregla la ortografía, la gramática y la puntuación. "
        + "No cambies las palabras, el sentido ni el tono.",
      exampleInput: "a que hora empieza la la reunion mañana",
      exampleOutput: "¿A qué hora empieza la reunión mañana?"
    ),
    PromptHeredado(
      id: "bullet-lists",
      name: "Hazme una lista",
      preInstruction: "Donde la transcripción enumere cosas, ponlas como lista "
        + "con viñetas, una por línea, con un guión adelante. Todo lo demás se "
        + "queda tal como se dijo.",
      exampleInput: "llevo bloqueador una toalla y un quitasol",
      exampleOutput: "llevo\n- bloqueador\n- una toalla\n- un quitasol"
    ),
    PromptHeredado(
      id: "remove-fillers",
      name: "Sin muletillas",
      preInstruction: "Saca las muletillas y los arranques en falso: eh, este, "
        + "o sea, cachai, po, y las palabras repetidas. No cambies nada más.",
      exampleInput: "eh a que hora empieza empieza la reunion o sea mañana",
      exampleOutput: "a qué hora empieza la reunión mañana"
    ),
  ]
}

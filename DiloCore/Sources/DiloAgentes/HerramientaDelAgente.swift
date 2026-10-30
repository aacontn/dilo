import Foundation

/// Una herramienta que un agente de la **Conversación** le ofrece a Claude:
/// las propias de Dilo y las de los servidores MCP conectados.
///
/// Cada una se declara de **lectura** o de **escritura**. Las de lectura
/// corren solas; las de escritura piden un clic en la muesca antes de correr
/// (`Aprobacion`), y la voz nunca aprueba. Lo que no se sabe si escribe —una
/// herramienta MCP sin `readOnlyHint`— es de escritura.
public struct HerramientaDelAgente: Sendable {
  public enum Efecto: Sendable, Equatable {
    case lectura
    case escritura
  }

  /// Cómo la nombra Claude: `^[a-zA-Z0-9_-]{1,64}$`.
  public let nombre: String
  public let descripcion: String
  /// El JSON Schema de sus argumentos (`input_schema`).
  public let esquema: ValorJSON
  public let efecto: Efecto
  /// Lo que dice la barra mientras corre: «Buscando en tus dictados…».
  public let enCurso: String
  /// Lo que pide aprobar: una línea que sigue al nombre del agente («quiere
  /// crear una nota») y el detalle completo. Sólo se mira en las de
  /// escritura.
  public let paraAprobar: @Sendable (ValorJSON) -> (descripcion: String, detalle: String)
  public let ejecutar: @Sendable (ValorJSON) async -> ResultadoDeHerramienta

  public init(
    nombre: String,
    descripcion: String,
    esquema: ValorJSON,
    efecto: Efecto,
    enCurso: String,
    paraAprobar: @escaping @Sendable (ValorJSON) -> (descripcion: String, detalle: String) = { argumentos in
      ("quiere usar una herramienta", argumentos.legible)
    },
    ejecutar: @escaping @Sendable (ValorJSON) async -> ResultadoDeHerramienta
  ) {
    self.nombre = nombre
    self.descripcion = descripcion
    self.esquema = esquema
    self.efecto = efecto
    self.enCurso = enCurso
    self.paraAprobar = paraAprobar
    self.ejecutar = ejecutar
  }

  /// Como la pide la API de mensajes en `tools`. `eager_input_streaming`
  /// deja que los argumentos lleguen sin el búfer del servidor; a cambio, el
  /// destino los valida él mismo antes de correr nada.
  public var comoJSON: ValorJSON {
    .objeto([
      "name": .texto(nombre),
      "description": .texto(descripcion),
      "input_schema": Self.esquemaValido(esquema),
      "eager_input_streaming": .bool(true),
    ])
  }

  /// La API exige un objeto con `"type": "object"`; un servidor MCP que manda
  /// otra cosa no puede tumbar el pedido entero.
  static func esquemaValido(_ esquema: ValorJSON) -> ValorJSON {
    guard case var .objeto(campos) = esquema, campos["type"] == .texto("object") else {
      return .objeto(["type": .texto("object"), "properties": .objeto([:])])
    }
    if campos["properties"] == nil { campos["properties"] = .objeto([:]) }
    return .objeto(campos)
  }
}

/// Lo que devolvió una herramienta, como vuelve a Claude en un `tool_result`.
public struct ResultadoDeHerramienta: Equatable, Sendable {
  public let texto: String
  public let esError: Bool

  public init(_ texto: String, esError: Bool = false) {
    self.texto = texto
    self.esError = esError
  }

  /// Una falla de las herramientas de Dilo, con su arreglo.
  public init(_ falla: FallaDeHerramienta) {
    self.init(falla.paraElModelo, esError: true)
  }
}

/// Cómo se llaman ante Claude las herramientas de un servidor MCP: con el
/// servidor adelante, para que dos servidores con una `search` no choquen y
/// para que se sepa de dónde viene cada una.
public enum NombreDeHerramientaMCP {
  public static let largoMaximo = 64

  /// `switchboard__find_entities`: sólo letras ASCII, dígitos, `_` y `-`, y a
  /// lo más 64. Lo que no cabe se corta y lleva un sufijo con su largo
  /// original, para que dos nombres largos no terminen iguales.
  public static func nombre(servidor: String, herramienta: String) -> String {
    let crudo = limpio(servidor) + "__" + limpio(herramienta)
    guard crudo.count > largoMaximo else { return crudo }
    let sufijo = "_\(abs(crudo.hashEstable) % 10_000)"
    return String(crudo.prefix(largoMaximo - sufijo.count)) + sufijo
  }

  static func limpio(_ texto: String) -> String {
    let plegado = texto.folding(options: [.diacriticInsensitive], locale: nil)
    let permitidos = plegado.unicodeScalars.map { escalar -> Character in
      let ascii = escalar.isASCII && (CharacterSet.alphanumerics.contains(escalar) || escalar == "_" || escalar == "-")
      return ascii ? Character(escalar) : "_"
    }
    let resultado = String(permitidos)
    return resultado.isEmpty ? "_" : resultado
  }
}

extension String {
  /// Un hash que no cambia entre corridas (el de `Hasher` sí): el nombre de
  /// una herramienta tiene que ser el mismo en cada turno de la llamada.
  var hashEstable: Int {
    var hash = 5381
    for byte in utf8 { hash = (hash &* 33) &+ Int(byte) }
    return hash
  }
}

extension HerramientaDelAgente {
  /// Una herramienta de un servidor MCP, que se corre con su cliente.
  public static func mcp(
    _ herramienta: HerramientaMCP,
    de servidor: ServidorMCPConfigurado,
    cliente: ClienteMCP
  ) -> HerramientaDelAgente {
    let nombreDelServidor = servidor.nombre
    let original = herramienta.nombre
    return HerramientaDelAgente(
      nombre: NombreDeHerramientaMCP.nombre(servidor: servidor.id, herramienta: original),
      descripcion: "[\(nombreDelServidor)] \(herramienta.descripcion)",
      esquema: herramienta.esquema,
      efecto: herramienta.soloLectura ? .lectura : .escritura,
      enCurso: "Preguntándole a \(nombreDelServidor)…",
      paraAprobar: { argumentos in
        ("quiere usar \(original) de \(nombreDelServidor)", "\(original) \(argumentos.enUnaLinea)")
      },
      ejecutar: { argumentos in
        do {
          let resultado = try await cliente.llamar(original, argumentos: argumentos)
          return ResultadoDeHerramienta(resultado.texto, esError: resultado.esError)
        } catch {
          return ResultadoDeHerramienta(
            (error as? FallaDelClienteMCP)?.mensaje ?? "No pude hablar con \(nombreDelServidor).", esError: true
          )
        }
      }
    )
  }
}

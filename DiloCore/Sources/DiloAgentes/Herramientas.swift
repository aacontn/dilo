import Foundation

/// Una herramienta para agentes: la misma fila sirve al servidor MCP
/// (`tools/list`), al CLI (`dilo spec`, `dilo --help`, la validación de
/// opciones) y a la ejecución. Una sola tabla, para que el CLI y el MCP no
/// puedan decir cosas distintas sobre lo mismo.
public struct Herramienta: Sendable, Equatable {
  public enum Tipo: String, Sendable {
    case entero = "integer"
    case texto = "string"
  }

  public struct Parametro: Sendable, Equatable {
    public let nombre: String
    public let tipo: Tipo
    public let descripcion: String
  }

  public let nombre: String
  public let descripcion: String
  public let parametros: [Parametro]
  public let requeridos: [String]

  public func parametro(_ nombre: String) -> Parametro? {
    parametros.first { $0.nombre == nombre }
  }

  /// Como la pide la especificación de MCP. Todas son de sólo lectura y lo
  /// dicen (`readOnlyHint`): un cliente puede llamarlas sin pedir permiso a
  /// la persona cada vez.
  public var comoJSON: ValorJSON {
    var propiedades: [String: ValorJSON] = [:]
    for p in parametros {
      propiedades[p.nombre] = .objeto([
        "type": .texto(p.tipo.rawValue), "description": .texto(p.descripcion),
      ])
    }
    return .objeto([
      "name": .texto(nombre),
      "description": .texto(descripcion),
      "inputSchema": .objeto([
        "type": .texto("object"),
        "properties": .objeto(propiedades),
        "required": .lista(requeridos.map(ValorJSON.texto)),
      ]),
      "annotations": .objeto(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)]),
    ])
  }
}

/// Por qué una herramienta no devolvió datos, dicho para que un agente sepa
/// qué hacer: `arreglo` es una frase con el paso siguiente. Es lo que más le
/// sirve a quien llama, y lo que un «error» a secas no le da.
public struct FallaDeHerramienta: Error, Equatable, Sendable, Encodable {
  public enum Codigo: String, Sendable, Encodable {
    case historialApagado = "historial_apagado"
    case historialIlegible = "historial_ilegible"
    case faltaArgumento = "falta_argumento"
    case argumentoInvalido = "argumento_invalido"
    case noEncontrado = "no_encontrado"
    case herramientaDesconocida = "herramienta_desconocida"
    case reunionesIlegibles = "reuniones_ilegibles"
  }

  public let codigo: Codigo
  public let mensaje: String
  public let arreglo: String

  public init(_ codigo: Codigo, _ mensaje: String, arreglo: String) {
    self.codigo = codigo
    self.mensaje = mensaje
    self.arreglo = arreglo
  }

  /// El texto que ve el modelo cuando la herramienta falla por MCP.
  public var paraElModelo: String { "\(mensaje) \(arreglo)" }
}

/// Las herramientas de Dilo y cómo se ejecutan. Las cuatro del plan (cap. 4
/// §6) y las tres de reuniones, todas de lectura: el historial que la persona
/// eligió guardar, Tus palabras y los guiones de las reuniones. Lo que vive
/// sólo en la app abierta —el último dictado si el historial está apagado, un
/// dictado pedido por un agente, la reunión en curso— espera al socket de la
/// fase 2.
public struct HerramientasDeDilo: Sendable {
  public let fuente: any FuenteDeDilo
  /// Dónde están las reuniones. Nil es un Dilo sin reuniones: las
  /// herramientas siguen en la tabla y lo dicen.
  public let reuniones: (any FuenteDeReuniones)?

  public init(fuente: any FuenteDeDilo, reuniones: (any FuenteDeReuniones)? = nil) {
    self.fuente = fuente
    self.reuniones = reuniones
  }

  /// Topes. Los extractos se cortan para que una lista de 50 no llene el
  /// contexto del agente; el texto entero se pide por id y por páginas.
  public static let maximoPorDefecto = 10
  public static let topeDeMaximo = 50
  public static let caracteresPorPagina = 20_000
  public static let topeDeCaracteres = 100_000
  public static let largoDelExtracto = 280

  public static let recientes = Herramienta(
    nombre: "dictados_recientes",
    descripcion: "Los últimos dictados guardados en el historial de Dilo, del más nuevo al más viejo. "
      + "Cada uno trae un extracto; el texto entero se pide con ver_dictado.",
    parametros: [
      .init(nombre: "maximo", tipo: .entero, descripcion: "Cuántos (10 por defecto, tope 50).")
    ],
    requeridos: []
  )

  public static let buscar = Herramienta(
    nombre: "buscar_dictados",
    descripcion: "Dictados guardados que contienen el texto, en lo dictado, la app o el modo, "
      + "sin importar tildes ni mayúsculas. Del más nuevo al más viejo.",
    parametros: [
      .init(nombre: "consulta", tipo: .texto, descripcion: "Qué buscar."),
      .init(nombre: "maximo", tipo: .entero, descripcion: "Cuántos (10 por defecto, tope 50)."),
    ],
    requeridos: ["consulta"]
  )

  public static let ver = Herramienta(
    nombre: "ver_dictado",
    descripcion: "Un dictado entero por su id, paginado por caracteres. "
      + "Si queda texto, la respuesta trae `siguiente`: pásalo como `desde`.",
    parametros: [
      .init(nombre: "id", tipo: .texto, descripcion: "El id que dio otra herramienta."),
      .init(nombre: "desde", tipo: .entero, descripcion: "Desde qué carácter (0 por defecto)."),
      .init(
        nombre: "max_caracteres", tipo: .entero,
        descripcion: "Cuántos caracteres (20000 por defecto, tope 100000)."
      ),
    ],
    requeridos: ["id"]
  )

  public static let palabras = Herramienta(
    nombre: "tus_palabras",
    descripcion: "Los nombres y términos que la persona le enseñó a Dilo (Tus palabras). "
      + "Sirven para escribir bien lo que ella nombra.",
    parametros: [],
    requeridos: []
  )

  public static let todas = [recientes, buscar, ver, palabras] + HerramientasDeReuniones.todas

  public static func llamada(_ nombre: String) -> Herramienta? {
    todas.first { $0.nombre == nombre }
  }

  /// Corre una herramienta. Puro salvo por la fuente: se prueba con una falsa.
  public func llamar(_ nombre: String, _ argumentos: ValorJSON) async -> Result<ValorJSON, FallaDeHerramienta> {
    guard let herramienta = Self.llamada(nombre) else {
      return .failure(
        FallaDeHerramienta(
          .herramientaDesconocida, "No existe la herramienta \(nombre).",
          arreglo: "Las que hay: \(Self.todas.map(\.nombre).joined(separator: ", "))."
        )
      )
    }
    do {
      return .success(try await ejecutar(herramienta, Argumentos(argumentos, de: herramienta)))
    } catch let falla as FallaDeHerramienta {
      return .failure(falla)
    } catch {
      return .failure(Self.historialIlegible)
    }
  }

  private func ejecutar(_ herramienta: Herramienta, _ args: Argumentos) async throws -> ValorJSON {
    if HerramientasDeReuniones.todas.contains(herramienta) {
      return try HerramientasDeReuniones.ejecutar(herramienta, args, fuente: reuniones)
    }
    if herramienta == Self.palabras {
      return .lista(fuente.tusPalabras().map(ValorJSON.texto))
    }
    // Se validan antes de mirar el historial: un argumento mal escrito se
    // arregla aunque el historial esté apagado, y decirlo después obliga a
    // dos vueltas.
    let maximo = try args.entero("maximo", porDefecto: Self.maximoPorDefecto, rango: 1 ... Self.topeDeMaximo)
    let consulta = herramienta == Self.buscar ? try args.textoRequerido("consulta") : ""
    let id = herramienta == Self.ver ? try args.textoRequerido("id") : ""
    let desde = try args.entero("desde", porDefecto: 0, rango: 0 ... Int.max)
    let cuantos = try args.entero(
      "max_caracteres", porDefecto: Self.caracteresPorPagina, rango: 1 ... Self.topeDeCaracteres
    )

    let todos = try await dictadosGuardados()
    switch herramienta {
    case Self.recientes:
      return .desde(todos.prefix(maximo).map(Self.extracto))
    case Self.buscar:
      let plegada = Self.plegar(consulta)
      let hallados = todos.filter { dictado in
        Self.plegar([dictado.texto, dictado.app, dictado.modo].compactMap { $0 }.joined(separator: " "))
          .contains(plegada)
      }
      return .desde(hallados.prefix(maximo).map(Self.extracto))
    default:
      guard let dictado = todos.first(where: { $0.id == id }) else {
        throw FallaDeHerramienta(
          .noEncontrado, "No hay un dictado con el id \(id).",
          arreglo: "Usa dictados_recientes o buscar_dictados para conseguir uno."
        )
      }
      return .desde(Self.pagina(de: dictado, desde: desde, cuantos: cuantos))
    }
  }

  private func dictadosGuardados() async throws -> [DictadoParaAgentes] {
    guard fuente.historialEncendido else {
      throw FallaDeHerramienta(
        .historialApagado, "El historial de Dilo está apagado, así que no hay dictados guardados.",
        arreglo: "Pídele a la persona que lo encienda en Dilo → Ajustes → Historial."
      )
    }
    do {
      return try await fuente.dictados()
    } catch {
      throw Self.historialIlegible
    }
  }

  static let historialIlegible = FallaDeHerramienta(
    .historialIlegible, "No pude leer la carpeta del historial.",
    arreglo: "Revisa en Dilo → Ajustes → Historial dónde está y que se pueda abrir."
  )

  /// Una página de `ver_dictado`, con dónde sigue si queda texto.
  public struct Pagina: Codable, Equatable, Sendable {
    public var dictado: DictadoParaAgentes
    public var siguiente: Int?
    public var total: Int
  }

  static func pagina(de dictado: DictadoParaAgentes, desde: Int, cuantos: Int) -> Pagina {
    let caracteres = Array(dictado.texto)
    let inicio = min(desde, caracteres.count)
    let fin = min(caracteres.count, inicio + cuantos)
    var parte = dictado
    parte.texto = String(caracteres[inicio ..< fin])
    return Pagina(dictado: parte, siguiente: fin < caracteres.count ? fin : nil, total: caracteres.count)
  }

  static func extracto(_ dictado: DictadoParaAgentes) -> DictadoParaAgentes {
    guard dictado.texto.count > largoDelExtracto else { return dictado }
    var corto = dictado
    corto.texto = String(dictado.texto.prefix(largoDelExtracto)) + "…"
    corto.recortado = true
    return corto
  }

  /// Sin tildes y sin mayúsculas, como `DictationHistoryStore.plegar`: se
  /// busca como se recuerda, no como se escribió.
  static func plegar(_ texto: String) -> String {
    texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
  }
}

/// Los argumentos de una llamada, leídos contra el esquema de su herramienta.
struct Argumentos {
  let valores: [String: ValorJSON]
  let herramienta: Herramienta

  init(_ valor: ValorJSON, de herramienta: Herramienta) {
    if case let .objeto(o) = valor { valores = o } else { valores = [:] }
    self.herramienta = herramienta
  }

  /// Un entero, o el de fábrica si no vino. Fuera del rango se acota al tope
  /// que la descripción promete; un valor que no es entero es un error, no
  /// un default silencioso. Un texto con un número (`"5"`) se acepta: hay
  /// clientes que mandan todo como texto.
  func entero(_ nombre: String, porDefecto: Int, rango: ClosedRange<Int>) throws -> Int {
    guard herramienta.parametro(nombre) != nil, let valor = valores[nombre], valor != .nulo else {
      return porDefecto
    }
    guard let n = valor.comoEntero ?? valor.comoTexto.flatMap({ Int($0) }) else {
      throw FallaDeHerramienta(
        .argumentoInvalido, "`\(nombre)` tiene que ser un número entero.",
        arreglo: "Manda `\(nombre)` como entero, por ejemplo \(porDefecto)."
      )
    }
    return min(max(n, rango.lowerBound), rango.upperBound)
  }

  /// Un texto que puede no venir: nil si falta o viene vacío.
  func textoOpcional(_ nombre: String) -> String? {
    let texto = valores[nombre]?.comoTexto?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return texto.isEmpty ? nil : texto
  }

  func textoRequerido(_ nombre: String) throws -> String {
    let texto = valores[nombre]?.comoTexto?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !texto.isEmpty else {
      throw FallaDeHerramienta(
        .faltaArgumento, "Falta `\(nombre)`.",
        arreglo: herramienta.parametro(nombre).map { "\($0.descripcion)" } ?? "Mándalo como texto."
      )
    }
    return texto
  }
}

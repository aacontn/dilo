import DiloReuniones
import Foundation

/// Dónde están las reuniones, para el servidor y el CLI. En la app lo da la
/// carpeta de Ajustes (`PreferenciasDeReuniones`); en los tests, una carpeta
/// temporal. Se pregunta en cada llamada: la persona puede cambiar la carpeta
/// mientras el agente sigue conectado.
public protocol FuenteDeReuniones: Sendable {
  func lector() -> LectorDeReuniones
}

/// Las reuniones donde las deja la app, leídas de las mismas claves de
/// `UserDefaults` sin crear nada de la app.
public struct ReunionesEnDisco: FuenteDeReuniones {
  /// El dominio de ajustes, cuando no es el estándar (el CLI entró por el
  /// enlace y Foundation no ve el bundle).
  public var dominio: String?
  public var respaldo: URL?

  public init(dominio: String? = nil, respaldo: URL? = nil) {
    self.dominio = dominio
    self.respaldo = respaldo
  }

  public func lector() -> LectorDeReuniones {
    let defaults = dominio.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    let respaldo = self.respaldo ?? CarpetaDeReunion.respaldoInterno(
      applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )
    return LectorDeReuniones(raiz: PreferenciasDeReuniones.leer(defaults).carpeta, respaldo: respaldo)
  }
}

/// Una reunión como la ve un agente en una lista: sin palabras, con lo que
/// sirve para decidir cuál abrir.
public struct ReunionParaAgentes: Codable, Equatable, Sendable {
  /// `2026-10-21T15:30:07`: lo que se pasa a `ver_reunion`.
  public var id: String
  public var titulo: String
  public var inicio: String
  public var minutos: Int
  /// grabando, afinando, lista, interrumpida o esperando el disco.
  public var estado: String
  /// Quiénes tienen voz en el guion, por nombre. Nunca sus huellas.
  public var hablantes: [String]
  /// Si ya hay guion que leer.
  public var conGuion: Bool

  init(_ enDisco: ReunionEnDisco, conGuion: Bool) {
    id = enDisco.id
    titulo = enDisco.reunion.titulo
    inicio = enDisco.reunion.inicio.formatted(.iso8601)
    minutos = Int((enDisco.reunion.duracion(ahora: enDisco.reunion.fin ?? Date()) / 60).rounded())
    estado = switch enDisco.estado {
    case .grabando: "grabando"
    case .afinando: "afinando"
    case .lista: "lista"
    case .interrumpida: "interrumpida"
    case .esperandoElDisco: "esperando el disco"
    }
    hablantes = enDisco.reunion.hablantes.map(\.nombreVisible)
    self.conGuion = conGuion
  }
}

/// Una página de `ver_reunion`.
public struct PaginaDeReunion: Codable, Equatable, Sendable {
  public var reunion: ReunionParaAgentes
  public var parte: String
  public var texto: String
  public var siguiente: Int?
  public var total: Int
}

/// Las tres herramientas de reuniones (spec, «MCP y CLI»): sólo lectura, los
/// mismos topes y el mismo sobre de errores que las de dictados.
enum HerramientasDeReuniones {
  static let recientes = Herramienta(
    nombre: "reuniones_recientes",
    descripcion: "Las últimas reuniones que grabó Dilo, de la más nueva a la más vieja, con quiénes hablaron. "
      + "El guion de cada una se pide con ver_reunion.",
    parametros: [.init(nombre: "maximo", tipo: .entero, descripcion: "Cuántas (10 por defecto, tope 50).")],
    requeridos: []
  )

  static let buscar = Herramienta(
    nombre: "buscar_reuniones",
    descripcion: "Líneas de los guiones de reuniones que contienen el texto, sin importar tildes ni mayúsculas. "
      + "Una palabra que es el nombre de quien habló también filtra por esa persona («Camila despacho»). "
      + "Cada resultado trae la reunión, el número de línea y la hora, para citar el momento.",
    parametros: [
      .init(nombre: "consulta", tipo: .texto, descripcion: "Qué buscar en lo dicho."),
      .init(nombre: "hablante", tipo: .texto, descripcion: "Sólo lo que dijo esta persona (opcional)."),
      .init(nombre: "maximo", tipo: .entero, descripcion: "Cuántas líneas (10 por defecto, tope 50)."),
    ],
    requeridos: ["consulta"]
  )

  static let ver = Herramienta(
    nombre: "ver_reunion",
    descripcion: "El guion de una reunión por su id, en Markdown y paginado por caracteres: una línea por "
      + "intervención con quién la dijo y a qué hora. Si queda texto, la respuesta trae `siguiente`: pásalo como `desde`.",
    parametros: [
      .init(nombre: "id", tipo: .texto, descripcion: "El id que dio otra herramienta."),
      .init(nombre: "parte", tipo: .texto, descripcion: "guion (por defecto) o resumen."),
      .init(nombre: "desde", tipo: .entero, descripcion: "Desde qué carácter (0 por defecto)."),
      .init(
        nombre: "max_caracteres", tipo: .entero, descripcion: "Cuántos caracteres (20000 por defecto, tope 100000)."
      ),
    ],
    requeridos: ["id"]
  )

  static let todas = [recientes, buscar, ver]

  static func ejecutar(
    _ herramienta: Herramienta, _ args: Argumentos, fuente: (any FuenteDeReuniones)?
  ) throws -> ValorJSON {
    let maximo = try args.entero(
      "maximo", porDefecto: HerramientasDeDilo.maximoPorDefecto, rango: 1 ... HerramientasDeDilo.topeDeMaximo
    )
    let consulta = herramienta == buscar ? try args.textoRequerido("consulta") : ""
    let hablante = herramienta == buscar ? args.textoOpcional("hablante") : nil
    let id = herramienta == ver ? try args.textoRequerido("id") : ""
    let parte = herramienta == ver ? (args.textoOpcional("parte") ?? "guion") : "guion"
    guard ["guion", "resumen"].contains(parte) else {
      throw FallaDeHerramienta(.argumentoInvalido, "`parte` es guion o resumen.", arreglo: "Manda parte = guion.")
    }
    let desde = try args.entero("desde", porDefecto: 0, rango: 0 ... Int.max)
    let cuantos = try args.entero(
      "max_caracteres", porDefecto: HerramientasDeDilo.caracteresPorPagina, rango: 1 ... HerramientasDeDilo.topeDeCaracteres
    )

    guard let fuente else { throw sinReuniones }
    let todas: [ReunionEnDisco]
    do { todas = try fuente.lector().todas() } catch { throw ilegibles }

    switch herramienta {
    case recientes:
      return .desde(todas.prefix(maximo).map { ReunionParaAgentes($0, conGuion: LectorDeReuniones.guionLegible(de: $0) != nil) })
    case buscar:
      let leidas = todas.compactMap { r in LectorDeReuniones.guionLegible(de: r).map { (reunion: r.reunion, markdown: $0) } }
      return .desde(BusquedaEnReuniones.buscar(consulta, hablante: hablante, en: leidas, maximo: maximo))
    default:
      guard let reunion = todas.first(where: { $0.id == id }) else {
        throw FallaDeHerramienta(
          .noEncontrado, "No hay una reunión con el id \(id).",
          arreglo: "Usa reuniones_recientes o buscar_reuniones para conseguir uno."
        )
      }
      let texto: String
      if parte == "resumen" {
        guard let resumen = try? String(contentsOf: reunion.archivo("resumen-1.md"), encoding: .utf8) else {
          throw FallaDeHerramienta(
            .noEncontrado, "Esa reunión no tiene resumen: Dilo nunca resume solo.",
            arreglo: "Pide parte = guion y resume tú lo que necesites."
          )
        }
        texto = resumen
      } else {
        guard let guion = LectorDeReuniones.guionLegible(de: reunion) else {
          throw FallaDeHerramienta(
            .noEncontrado, "Esa reunión todavía no tiene guion (\(ReunionParaAgentes(reunion, conGuion: false).estado)).",
            arreglo: "El guion sale cuando termina la pasada final; vuelve a pedirlo en un rato."
          )
        }
        texto = guion
      }
      let caracteres = Array(texto)
      let inicio = min(desde, caracteres.count)
      let fin = min(caracteres.count, inicio + cuantos)
      return .desde(
        PaginaDeReunion(
          reunion: ReunionParaAgentes(reunion, conGuion: parte == "guion"), parte: parte,
          texto: String(caracteres[inicio ..< fin]), siguiente: fin < caracteres.count ? fin : nil, total: caracteres.count
        )
      )
    }
  }

  static let sinReuniones = FallaDeHerramienta(
    .reunionesIlegibles, "Este Dilo no sabe dónde están las reuniones.",
    arreglo: "Abre Dilo una vez y revisa Ajustes → Reuniones."
  )

  static let ilegibles = FallaDeHerramienta(
    .reunionesIlegibles, "No pude leer la carpeta de reuniones.",
    arreglo: "Revisa que el disco esté montado y que se pueda abrir la carpeta de Ajustes → Reuniones. "
      + "Si es un disco externo, macOS puede pedir permiso a quien lanzó este proceso."
  )
}

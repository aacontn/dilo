import Foundation

/// Qué se dice en voz alta de lo que escribe Claude Code y qué queda sólo
/// para la transcripción.
///
/// Claude Code escribe para una pantalla: bloques de código, diffs, tablas,
/// rutas largas, markdown. Nada de eso se lee entero: un bloque de código se
/// salta, una tabla también, una ruta se dice por su último pedazo, un enlace
/// es «un enlace», y lo que pasa de `topeParaDecir` se corta en una oración y
/// avisa que el resto está en la transcripción. El texto completo sigue
/// yendo a la transcripción.
public enum VozDeClaudeCode {
  /// Unos 30 segundos de voz. Más que eso es leer un documento en voz alta.
  public static let topeParaDecir = 480
  /// Más largo que esto, un `código en línea` no se lee: se dice «esto».
  public static let topeDeCodigoEnLinea = 40

  public static let avisoDeDetalle = "El detalle está en la transcripción."
  public static let avisoDeRecorte = "El resto está en la transcripción."

  /// Lo que se dice de un bloque de texto. Nil si no queda nada que decir.
  public static func paraDecir(_ texto: String) -> String? {
    var frases: [String] = []
    var enBloque = false
    var huboDetalle = false

    for lineaCruda in texto.components(separatedBy: .newlines) {
      let linea = lineaCruda.trimmingCharacters(in: .whitespaces)
      if linea.hasPrefix("```") || linea.hasPrefix("~~~") {
        enBloque.toggle()
        huboDetalle = true
        continue
      }
      if enBloque || linea.isEmpty { continue }
      if esDeTablaODiff(linea) {
        huboDetalle = true
        continue
      }
      let (dicha, recorto) = lineaDicha(linea)
      huboDetalle = huboDetalle || recorto
      guard !dicha.isEmpty else { continue }
      frases.append(conPunto(dicha))
    }

    var dicho = frases.joined(separator: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)

    if dicho.count > topeParaDecir {
      return recortado(dicho) + " " + avisoDeRecorte
    }
    if dicho.isEmpty {
      return huboDetalle ? "Te lo dejé en la transcripción." : nil
    }
    if huboDetalle { dicho += " " + avisoDeDetalle }
    return dicho
  }

  /// Una tabla de markdown o un diff no se leen.
  private static func esDeTablaODiff(_ linea: String) -> Bool {
    linea.hasPrefix("|") || linea.hasPrefix("@@") || linea.hasPrefix("diff --git")
      || linea.hasPrefix("+++ ") || linea.hasPrefix("--- ")
      || linea.allSatisfy { "-=*_".contains($0) }
  }

  /// Una línea sin markdown, con el código en línea, las rutas y los enlaces
  /// pasados a algo que se puede decir. `recorto` es si se calló algo.
  static func lineaDicha(_ linea: String) -> (String, recorto: Bool) {
    var s = linea
    var recorto = false
    // Títulos, citas y viñetas.
    s = s.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+•]\s+|\d{1,3}[.)]\s+)"#, with: "", options: .regularExpression)
    // [texto](url) → texto
    s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
    // `código`
    s = reemplazar(#"`([^`]+)`"#, grupo: 1, en: s) { codigo in
      if codigo.count > topeDeCodigoEnLinea && !esRuta(codigo) {
        recorto = true
        return "esto"
      }
      return esRuta(codigo) ? ultimoPedazo(codigo) : codigo
    }
    // URLs sueltas.
    s = s.replacingOccurrences(of: #"https?://\S+"#, with: "un enlace", options: .regularExpression)
    // Rutas sueltas con al menos dos barras: «/Volumes/SSD 1/…/x.swift» sin
    // espacios adentro.
    s = reemplazar(#"(~|\.{1,2})?(/[^\s/]+){2,}/?"#, en: s) { ruta in ultimoPedazo(ruta) }
    // Énfasis.
    s = s.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
    s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
    return (s.trimmingCharacters(in: .whitespaces), recorto)
  }

  static func esRuta(_ texto: String) -> Bool {
    let barras = texto.filter { $0 == "/" }.count
    // Una ruta absoluta puede llevar espacios («/Volumes/SSD 1/…»).
    if (texto.hasPrefix("/") || texto.hasPrefix("~/")) && barras >= 2 && !texto.contains("://") { return true }
    return !texto.contains(" ") && barras >= 1
      && (texto.hasPrefix("/") || texto.hasPrefix("~") || texto.hasPrefix(".") || texto.contains("."))
      && !texto.contains("://")
  }

  static func ultimoPedazo(_ ruta: String) -> String {
    let pedazos = ruta.split(separator: "/").filter { !$0.isEmpty }
    return pedazos.last.map(String.init) ?? ruta
  }

  private static func conPunto(_ frase: String) -> String {
    guard let ultimo = frase.last else { return frase }
    return ".!?:;…".contains(ultimo) ? frase : frase + "."
  }

  /// Corta en la última oración que entra; si no hay, en la última palabra.
  private static func recortado(_ texto: String) -> String {
    let tope = texto.index(texto.startIndex, offsetBy: topeParaDecir)
    let cabeza = texto[..<tope]
    if let fin = cabeza.lastIndex(where: { ".!?".contains($0) }), cabeza.distance(from: cabeza.startIndex, to: fin) > topeParaDecir / 3 {
      return String(cabeza[...fin])
    }
    if let espacio = cabeza.lastIndex(of: " ") {
      return String(cabeza[..<espacio]) + "…"
    }
    return String(cabeza) + "…"
  }

  /// Cambia cada coincidencia de `patron` por lo que devuelve `cambio`, que
  /// recibe el grupo `grupo` (0 es la coincidencia entera).
  private static func reemplazar(
    _ patron: String, grupo: Int = 0, en texto: String, con cambio: (String) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: patron) else { return texto }
    var resultado = ""
    var desde = texto.startIndex
    let rango = NSRange(texto.startIndex..., in: texto)
    for coincidencia in regex.matches(in: texto, range: rango) {
      guard let entero = Range(coincidencia.range, in: texto) else { continue }
      guard grupo < coincidencia.numberOfRanges, let pedazo = Range(coincidencia.range(at: grupo), in: texto) else { continue }
      let adentro = String(texto[pedazo])
      resultado += texto[desde..<entero.lowerBound]
      resultado += cambio(adentro)
      desde = entero.upperBound
    }
    resultado += texto[desde...]
    return resultado
  }
}

/// Cómo se nombra en la barra lo que Claude Code está haciendo: «Corriendo
/// `swift test`», «Editando AppDelegate.swift». No se dice en voz alta.
public enum HerramientaDeClaudeCode {
  public static let topeDeComando = 50

  public static func enCurso(_ nombre: String, _ entrada: EntradaDeHerramienta) -> String {
    switch nombre {
    case "Bash", "PowerShell":
      return "Corriendo `\(comandoCorto(entrada["command"]))`"
    case "Read": return "Leyendo \(archivo(entrada))"
    case "Edit", "MultiEdit": return "Editando \(archivo(entrada))"
    case "Write": return "Escribiendo \(archivo(entrada))"
    case "NotebookEdit": return "Editando \(VozDeClaudeCode.ultimoPedazo(entrada["notebook_path"] ?? "el notebook"))"
    case "Grep": return "Buscando «\(corto(entrada["pattern"] ?? ""))»"
    case "Glob": return "Buscando archivos «\(corto(entrada["pattern"] ?? ""))»"
    case "WebFetch": return "Abriendo \(sitio(entrada["url"]))"
    case "WebSearch": return "Buscando en la web «\(corto(entrada["query"] ?? ""))»"
    case "Task", "Agent": return "Con un subagente: \(corto(entrada["description"] ?? "trabajando"))"
    case "TodoWrite", "TaskCreate", "TaskUpdate": return "Anotando pendientes"
    case "Skill": return "Usando la skill \(entrada["skill"] ?? "")"
    case "ExitPlanMode": return "Terminando el plan"
    default:
      if let (servidor, herramienta) = deMCP(nombre) { return "Usando \(herramienta) de \(servidor)" }
      return "Usando \(nombre)"
    }
  }

  static func archivo(_ entrada: EntradaDeHerramienta) -> String {
    VozDeClaudeCode.ultimoPedazo(entrada["file_path"] ?? entrada["path"] ?? "un archivo")
  }

  static func comandoCorto(_ comando: String?, tope: Int = topeDeComando) -> String {
    let primera = (comando ?? "").components(separatedBy: .newlines).first ?? ""
    let limpia = primera.trimmingCharacters(in: .whitespaces)
    let masLineas = (comando ?? "").contains("\n")
    if limpia.count > tope { return String(limpia.prefix(tope)) + "…" }
    return masLineas ? limpia + " …" : limpia
  }

  static func corto(_ texto: String, tope: Int = 40) -> String {
    texto.count > tope ? String(texto.prefix(tope)) + "…" : texto
  }

  static func sitio(_ url: String?) -> String {
    guard let url, let host = URL(string: url)?.host() else { return "una página" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// `mcp__switchboard__status` → (switchboard, status).
  static func deMCP(_ nombre: String) -> (String, String)? {
    guard nombre.hasPrefix("mcp__") else { return nil }
    let partes = nombre.dropFirst(5).components(separatedBy: "__")
    guard partes.count >= 2 else { return nil }
    return (partes[0], partes.dropFirst().joined(separator: "__"))
  }
}

/// Cómo se pide en la muesca el permiso que pide Claude Code: una línea
/// (`Aprobacion.descripcion`) y el detalle entero para la transcripción
/// (`Aprobacion.detalle`).
public enum PermisoDeClaudeCode {
  /// Lo que entra del contenido de un archivo o de un cambio en el detalle.
  public static let topeDelDetalle = 1_200

  public static func descripcion(_ pedido: PedidoDePermiso, agente: String) -> String {
    let e = pedido.entrada
    let accion: String
    switch pedido.herramienta {
    case "Bash", "PowerShell":
      accion = "correr `\(HerramientaDeClaudeCode.comandoCorto(e["command"], tope: 60))`"
    case "Edit", "MultiEdit": accion = "editar `\(HerramientaDeClaudeCode.archivo(e))`"
    case "Write": accion = "escribir `\(HerramientaDeClaudeCode.archivo(e))`"
    case "NotebookEdit": accion = "editar `\(VozDeClaudeCode.ultimoPedazo(e["notebook_path"] ?? "el notebook"))`"
    case "Read": accion = "leer `\(HerramientaDeClaudeCode.archivo(e))`"
    case "Grep", "Glob": accion = "buscar en `\(VozDeClaudeCode.ultimoPedazo(e["path"] ?? pedido.rutaBloqueada ?? "otra carpeta"))`"
    case "WebFetch": accion = "abrir \(HerramientaDeClaudeCode.sitio(e["url"]))"
    case "WebSearch": accion = "buscar en la web «\(HerramientaDeClaudeCode.corto(e["query"] ?? ""))»"
    case "Task", "Agent": accion = "lanzar un subagente: \(HerramientaDeClaudeCode.corto(e["description"] ?? "sin descripción"))"
    case "ExitPlanMode": accion = "dejar de planear y empezar a cambiar archivos"
    case "Skill": accion = "usar la skill `\(e["skill"] ?? "")`"
    default:
      if let (servidor, herramienta) = HerramientaDeClaudeCode.deMCP(pedido.herramienta) {
        accion = "usar `\(herramienta)` de \(servidor)"
      } else {
        accion = "usar `\(pedido.herramienta)`"
      }
    }
    return "\(agente) quiere \(accion)"
  }

  public static func detalle(_ pedido: PedidoDePermiso) -> String {
    let e = pedido.entrada
    var lineas: [String] = []
    switch pedido.herramienta {
    case "Bash", "PowerShell":
      lineas.append("Comando:")
      lineas.append(e["command"] ?? "")
      if let porque = e["description"] { lineas.append("Para qué: \(porque)") }
    case "Edit":
      lineas.append("Archivo: \(e["file_path"] ?? "")")
      lineas.append("Cambia:")
      lineas.append(cortado(e["old_string"] ?? ""))
      lineas.append("Por:")
      lineas.append(cortado(e["new_string"] ?? ""))
    case "Write":
      let contenido = e["content"] ?? ""
      lineas.append("Archivo: \(e["file_path"] ?? "")")
      lineas.append("Contenido (\(contenido.count) caracteres):")
      lineas.append(cortado(contenido))
    default:
      lineas.append("Herramienta: \(pedido.herramienta)")
      lineas.append(cortado(e.json))
    }
    if let ruta = pedido.rutaBloqueada { lineas.append("Ruta: \(ruta)") }
    return lineas.joined(separator: "\n")
  }

  private static func cortado(_ texto: String) -> String {
    texto.count > topeDelDetalle ? String(texto.prefix(topeDelDetalle)) + "\n…" : texto
  }
}

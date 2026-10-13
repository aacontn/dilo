import Foundation

// Reglas y umbrales adaptados de imnotpayingforwisprflow,
// Sources/LocalDictation/CleanupClient.swift:353-807 (MIT, © 2026 Yosef
// Shammout) y de Muesli, Qwen3PostProcessor.swift:36-144 (MIT, © 2026 Pranav
// Hari). Umbrales de palabras (40 %, +20 %, 25 % nuevas, «?») tomados como
// dato de BetterWispr TranscriptPolisher.swift:206-221; ese archivo es GPL y
// no se copió nada de su texto. Reescrito para español por Dilo.

/// Lo que el modelo de texto devolvió, juzgado contra lo que se le dio.
///
/// No prueba que el sentido sea el mismo: caza las fallas que ya vimos —un
/// número cambiado, un «no» que desaparece, una URL tocada, una respuesta en
/// vez de una limpieza— y ante la duda rechaza. Rechazar no pierde nada: se
/// pega lo que dejaron las reglas locales.
public enum ValidadorDeLimpieza {
  /// Cuánto puede cambiar el modo. Lo declara el `Modo`, no el modelo.
  public enum Perfil: Sendable, Equatable {
    /// Limpio: arregla, no reescribe. Ninguna palabra con contenido nueva y
    /// todo en el mismo orden.
    case limpieza
    /// Mensaje: puede acortar y cambiar alguna palabra (≤ 25 % nuevas).
    case ligera
    /// Correo, Prompt: reescriben a propósito. Sólo se cuida lo que nunca
    /// puede cambiar: números, literales, negaciones y la pregunta.
    case reescritura
    /// Un modo propio que traduce o resume: números y negaciones cambian de
    /// forma con el idioma, así que sólo se caza la basura y la respuesta de
    /// asistente. Sigue pasando por acá: ninguna salida se pega sin juicio.
    case libre
  }

  /// Por qué no pasó. El `rawValue` es lo que va al log: nunca el texto.
  public enum Rechazo: String, Error, Equatable, Sendable {
    case vacia, basura, respondio, cambioUnLiteral, cambioUnNumero
    case cambioUnaNegacion, perdioLaPregunta, largoFueraDeRango
    case palabrasNuevas, desordeno, perdioUnNombre

    /// Lo que dice la muesca. Corto, porque la persona está mirando su texto,
    /// y con dónde quedó lo que el modo propuso: el validador también se
    /// equivoca, y un falso rechazo no puede costar la limpieza entera.
    public func aviso(modo: String) -> String {
      let que = switch self {
      case .cambioUnNumero: "cambió un número"
      case .cambioUnaNegacion: "cambió un «no»"
      case .cambioUnLiteral: "tocó una dirección o un código"
      case .respondio, .perdioLaPregunta: "contestó en vez de reescribir"
      case .vacia, .basura: "devolvió algo que no era texto"
      default: "cambió demasiado tu texto"
      }
      return "\(modo) \(que): va tu dictado sin el modo, y lo que propuso "
        + "queda en el menú de Dilo."
    }
  }

  public static func validar(
    _ respuesta: String, contra fuente: String, perfil: Perfil = .limpieza
  ) throws(Rechazo) -> String {
    let salida = lavar(respuesta, fuente: fuente)
    guard !salida.isEmpty else { throw .vacia }
    guard !salida.unicodeScalars.contains(where: {
      CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
    }), !salida.contains("<think") else { throw .basura }
    if pareceAsistente(salida, fuente: fuente, perfil: perfil) { throw .respondio }
    if perfil == .libre { return salida }

    let literalesF = literales(fuente), literalesS = literales(salida)
    let mismosLiterales = perfil == .reescritura
      ? literalesF.sorted() == literalesS.sorted() : literalesF == literalesS
    guard mismosLiterales else { throw .cambioUnLiteral }

    let fuenteRecortada = fuente.trimmingCharacters(in: .whitespacesAndNewlines)
    if salida == fuenteRecortada { return salida }

    let tope = perfil == .reescritura
      ? max(400, fuenteRecortada.count * 4) : max(80, fuenteRecortada.count * 3 / 2 + 30)
    guard salida.count <= tope else { throw .largoFueraDeRango }
    if esPregunta(fuenteRecortada), !salida.contains("?") { throw .perdioLaPregunta }

    // Las viñetas de una lista («1.», «-») no son palabras ni números dichos.
    let sinVinetas = salida.replacing(/(?m)^[ \t]*(?:\d+[.)]|[-*•])[ \t]+/, with: "")
    let f = fichas(fuenteRecortada), s = fichas(sinVinetas)
    let corrigio = huboAutocorreccion(f)

    // Números: los mismos valores, o sólo menos si hubo una autocorrección y
    // cada uno que falta fue reemplazado ahí mismo («veinte, no, treinta»).
    let numerosF = sinTartamudeo(f.filter(\.esNumero).map(\.clave))
    let numerosS = sinTartamudeo(s.filter(\.esNumero).map(\.clave))
    if numerosF.sorted() != numerosS.sorted() {
      guard corrigio, esSubmulticonjunto(numerosS, de: numerosF) else { throw .cambioUnNumero }
    }

    let negF = negaciones(f), negS = negaciones(s)
    switch perfil {
    case .reescritura, .libre:
      guard negS.count >= negF.count else { throw .cambioUnaNegacion }
      return salida
    case .ligera:
      guard corrigio || negF.sorted() == negS.sorted() else { throw .cambioUnaNegacion }
      try revisarLargoEnPalabras(f, s, corrigio: corrigio, holgura: 5)
      let contenidoS = s.filter { esContenido($0) }
      let nuevas = contenidoS.filter { p in !f.contains { calza($0, p) } }
      guard nuevas.count * 4 <= max(contenidoS.count, 1) else { throw .palabrasNuevas }
      return salida
    case .limpieza:
      guard corrigio || negF.sorted() == negS.sorted() else { throw .cambioUnaNegacion }
      try revisarLargoEnPalabras(f, s, corrigio: corrigio, holgura: 5)
      guard s.filter({ esContenido($0) }).allSatisfy({ p in f.contains { calza($0, p) } })
      else { throw .palabrasNuevas }
      // Primero de izquierda a derecha; si no, de derecha a izquierda: en
      // «el jueves, perdón, el viernes» lo que queda es la segunda mención.
      var ultimo: Rechazo = .desordeno
      for desdeLaDerecha in [false, true] {
        guard let mapa = alinear(f, s, desdeLaDerecha: desdeLaDerecha) else { continue }
        do throws(Rechazo) {
          try revisarAlineado(f, s, mapa: mapa, corrigio: corrigio)
          return salida
        } catch { ultimo = error }
      }
      throw ultimo
    }
  }

  /// Quita lo que el modelo agrega alrededor sin que sea texto: razonamiento,
  /// marcas, rótulos, comillas que envuelven todo, el sobre JSON.
  static func lavar(_ texto: String, fuente: String) -> String {
    var t = texto
    if let datos = t.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
      obj.count == 1, let dentro = obj["texto"] as? String
    {
      t = dentro
    }
    t = t.replacing(/(?s)<think>.*?<\/think>/, with: " ")
    t = t.replacing(/(?s)<think\b.*$/, with: "")
    t = t.replacing(/<\/?transcript>/, with: "")
    if !fuente.contains("```") { t = t.replacing(/```[A-Za-z0-9_-]*/, with: "") }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    t = t.replacing(
      /^(?i)(texto( limpio| corregido)?|transcripci[oó]n( limpia)?|resultado|salida|output)\s*:\s*/,
      with: "")
    for (abre, cierra) in [("\"", "\""), ("“", "”"), ("«", "»")]
    where t.hasPrefix(abre) && t.hasSuffix(cierra) && t.count > 2 && !fuente.hasPrefix(abre) {
      t = String(t.dropFirst().dropLast())
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static let inicioDeAsistente = [
    "claro", "por supuesto", "aqui tienes", "aqui esta", "aqui va", "he aqui",
    "lo siento", "sure", "here is", "here's", "certainly",
  ]
  static let frasesDeAsistente = [
    "como modelo de lenguaje", "como asistente", "como ia", "no puedo ayudar",
    "no tengo acceso", "espero que te sirva", "espero que esto ayude",
    "espero que te ayude", "si necesitas algo mas", "algo mas en lo que",
    "he eliminado", "he corregido", "he quitado", "he reescrito", "opcion 1",
    "the user", "as an ai", "i can't", "i cannot", "here is the",
  ]

  /// Una frase de asistente que la persona no dijo. En Limpio basta una;
  /// en reescritura hacen falta dos o una al comienzo, porque un correo
  /// puede cerrar con «espero que te sirva» sin que nadie lo haya dictado.
  static func pareceAsistente(_ salida: String, fuente: String, perfil: Perfil) -> Bool {
    let s = plegar(salida), f = plegar(fuente)
    let alInicio = inicioDeAsistente.contains { s.hasPrefix($0) && !f.contains($0) }
    let senales = frasesDeAsistente.filter { s.contains($0) && !f.contains($0) }.count
    let rehace = perfil == .reescritura || perfil == .libre
    return rehace ? alInicio || senales >= 2 : alInicio || senales >= 1
  }

  /// Una pregunta directa: tiene «?» o «¿», o parte con un interrogativo
  /// con tilde. «No sé qué hacer» no cuenta: el «qué» no va al comienzo.
  static func esPregunta(_ texto: String) -> Bool {
    texto.contains("?") || texto.contains("¿")
      || texto.lowercased().prefixMatch(
        of: /\s*(?:(?:a|de|en|para|por|con|desde|hasta)\s+)?(?:qué|cómo|cuándo|dónde|cuál|cuáles|quién|quiénes|cuánto|cuánta|cuántos|cuántas)\b/
      ) != nil
  }

  /// URL, correos, rutas, código, flags y lo que va entre comillas: se
  /// comparan tal cual, carácter por carácter.
  static func literales(_ texto: String) -> [String] {
    let patrones = [
      #"```[\s\S]*?(?:```|\z)"#, #"`[^`\n]+`"#, #""[^"\n]*"|“[^”\n]*”|«[^»\n]*»"#,
      #"\b(?:https?|file)://[^\s<>"`]+"#, #"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#,
      #"(?<![\p{L}\p{N}_])(?:~?/|\./|\.\./)[^\s<>"`]+"#,
      #"\b[\w.~-]+(?:/[\w.~-]+)+\b"#, #"(?<![\p{L}\p{N}_-])--?[A-Za-z][\w-]*(?:=[^\s<>"`]+)?"#,
    ]
    let ns = texto as NSString
    var rangos: [NSRange] = []
    for patron in patrones {
      let regex = try! NSRegularExpression(pattern: patron)
      for m in regex.matches(in: texto, range: NSRange(location: 0, length: ns.length)) {
        var r = m.range
        // El punto que cierra la frase no es parte de la URL.
        while r.length > 0, ".,;:!?".contains(ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1))) {
          r.length -= 1
        }
        rangos.append(r)
      }
    }
    rangos.sort { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
    var unidos: [NSRange] = []
    for r in rangos {
      if let ultimo = unidos.last, r.location < NSMaxRange(ultimo) {
        unidos[unidos.count - 1] = NSUnionRange(ultimo, r)
      } else {
        unidos.append(r)
      }
    }
    return unidos.map { ns.substring(with: $0) }
  }

  /// Una palabra del texto, lista para comparar: plegada, o «#valor» si es
  /// número. `antes` es lo que la separa de la anterior, con su puntuación.
  struct Ficha {
    var clave: String
    var esNumero = false
    var protegida = false
    var antes = ""
  }

  static func plegar(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_CL"))
  }

  static func fichas(_ texto: String) -> [Ficha] {
    let ns = texto as NSString
    let regex = try! NSRegularExpression(
      pattern: #"[0-9]+(?:[.,:][0-9]+)*|[\p{L}\p{M}_][\p{L}\p{M}\p{N}_]*"#)
    let crudas = regex.matches(in: texto, range: NSRange(location: 0, length: ns.length)).map(\.range)
    let plegadas = crudas.map { plegar(ns.substring(with: $0)) }
    func hueco(_ k: Int) -> String {
      let desde = k == 0 ? 0 : NSMaxRange(crudas[k - 1])
      return ns.substring(with: NSRange(location: desde, length: crudas[k].location - desde))
    }
    func unido(_ k: Int) -> Bool {
      let h = hueco(k)
      return !h.isEmpty && h.allSatisfy { $0 == " " || $0 == "\t" }
    }
    var resultado: [Ficha] = []
    var i = 0
    while i < crudas.count {
      let antes = hueco(i)
      if let (clave, n) = NumerosHablados.leer(plegadas, desde: i, unido: unido) {
        resultado.append(Ficha(clave: "#" + clave, esNumero: true, antes: antes))
        i += n
        continue
      }
      let original = ns.substring(with: crudas[i])
      let inicioDeFrase = i == 0 || antes.contains { ".!?¿¡\n:".contains($0) }
      // Un nombre (mayúscula sin ser comienzo de frase) o un identificador
      // (user_id, userId, v2) no se repara ni se puede perder.
      let esNombre = !inicioDeFrase && original.first?.isUppercase == true
      let esIdentificador = original.contains("_")
        || original.contains(where: \.isNumber)
        || original.dropFirst().contains(where: \.isUppercase)
      resultado.append(Ficha(clave: plegadas[i], protegida: esNombre || esIdentificador, antes: antes))
      i += 1
    }
    return resultado
  }

  static let gramaticales: Set<String> = [
    "el", "la", "los", "las", "lo", "un", "una", "unos", "unas", "de", "del", "a", "al",
    "en", "con", "por", "para", "pa", "sin", "sobre", "entre", "hasta", "desde", "hacia",
    "que", "q", "y", "o", "u", "e", "pero", "mas", "si", "se", "me", "te", "le", "les",
    "nos", "mi", "mis", "tu", "tus", "su", "sus", "es", "son", "era", "fue", "ser",
    "esta", "estan", "este", "esto", "ese", "esa", "eso", "hay", "ha", "he", "han",
    "muy", "tan", "como", "cuando", "donde", "porque", "pues", "entonces", "ya", "yo",
  ]
  /// Las de relleno: el modelo puede sacarlas, y que las saque no cuenta
  /// como perder contenido.
  static let deRelleno: Set<String> = [
    "eh", "em", "mm", "osea", "sea", "digamos", "cachai", "cachay", "po", "pos",
    "onda", "tipo", "bueno", "oye", "mira", "pucha", "ok", "okey",
  ]
  static let palabrasDeNegacion: Set<String> = [
    "no", "nunca", "tampoco", "ni", "jamas", "nadie", "nada", "ningun", "ninguno", "ninguna",
  ]
  static let dias: Set<String> = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
  static let marcadores: Set<String> = ["no", "perdon", "perdona", "digo", "mejor", "quiero", "mas", "corrijo"]

  static func esContenido(_ f: Ficha) -> Bool {
    f.esNumero || !(gramaticales.contains(f.clave) || deRelleno.contains(f.clave)
      || palabrasDeNegacion.contains(f.clave))
  }

  static func comaAntes(_ f: [Ficha], _ i: Int) -> Bool {
    f[i].antes.contains(",") || f[i].antes.contains(";")
  }

  /// ¿Esta ficha abre una autocorrección? «el jueves, perdón, el viernes»,
  /// «a las nueve, no, a las once», «a Josefa, digo, a Martina», «mejor
  /// dicho». «Perdón por la demora» y «perdón, no puedo» no corrigen nada.
  static func esMarcador(_ f: [Ficha], _ i: Int) -> Bool {
    let siguiente = i + 1 < f.count ? f[i + 1] : nil
    switch f[i].clave {
    case "no":
      if comaAntes(f, i), let siguiente,
        siguiente.antes.contains(",") || ["mejor", "perdon", "digo"].contains(siguiente.clave)
      {
        return true
      }
      // Sin comas, sólo entre dos números o dos días: «el 15 no el 20».
      guard i > 0, let despues = f[(i + 1)...].first(where: { !gramaticales.contains($0.clave) })
      else { return false }
      return (f[i - 1].esNumero && despues.esNumero)
        || (dias.contains(f[i - 1].clave) && dias.contains(despues.clave))
    case "perdon", "perdona":
      return comaAntes(f, i) && !["por", "que"].contains(siguiente?.clave ?? "")
    case "digo", "corrijo":
      return comaAntes(f, i)
    case "mejor":
      return siguiente?.clave == "dicho" && (comaAntes(f, i) || i >= 2)
    case "quiero":
      return siguiente?.clave == "decir" && comaAntes(f, i)
    case "mas":
      return siguiente?.clave == "bien" && comaAntes(f, i)
    default:
      return false
    }
  }

  static func huboAutocorreccion(_ f: [Ficha]) -> Bool {
    f.indices.contains { esMarcador(f, $0) }
  }

  /// Las negaciones de verdad, sin el «no» que corrige y sin repetir el
  /// «no, no» enfático, que el modelo puede dejar en uno.
  static func negaciones(_ f: [Ficha]) -> [String] {
    var r: [String] = []
    for i in f.indices where palabrasDeNegacion.contains(f[i].clave) && !esMarcador(f, i) {
      if i > 0, f[i - 1].clave == f[i].clave { continue }
      r.append(f[i].clave)
    }
    return r
  }

  static func sinTartamudeo(_ claves: [String]) -> [String] {
    claves.enumerated().filter { $0.offset == 0 || claves[$0.offset - 1] != $0.element }.map(\.element)
  }

  static func esSubmulticonjunto(_ a: [String], de b: [String]) -> Bool {
    var resto = b
    for x in a {
      guard let i = resto.firstIndex(of: x) else { return false }
      resto.remove(at: i)
    }
    return true
  }

  static func revisarLargoEnPalabras(
    _ f: [Ficha], _ s: [Ficha], corrigio: Bool, holgura: Int
  ) throws(Rechazo) {
    guard f.count >= 4 else { return }
    let piso = corrigio ? f.count / 4 : f.count * 2 / 5
    guard s.count >= max(1, piso), s.count <= f.count + max(2, f.count / holgura) else {
      throw .largoFueraDeRango
    }
  }

  /// Una reparación ortográfica chica: un cambio, una letra de más o de
  /// menos, o dos letras vecinas cambiadas de lugar.
  static func reparacionChica(_ a: String, _ b: String) -> Bool {
    let x = Array(a), y = Array(b)
    guard x.count >= 4, y.count >= 4, abs(x.count - y.count) <= 1 else { return false }
    if x.count == y.count {
      let difs = x.indices.filter { x[$0] != y[$0] }
      return difs.count <= 1
        || (difs.count == 2 && difs[1] == difs[0] + 1 && x[difs[0]] == y[difs[1]] && x[difs[1]] == y[difs[0]])
    }
    let (corta, larga) = x.count < y.count ? (x, y) : (y, x)
    var i = 0, j = 0, salto = false
    while i < corta.count, j < larga.count {
      if corta[i] == larga[j] { i += 1; j += 1 } else if salto { return false } else { salto = true; j += 1 }
    }
    return true
  }

  static func calza(_ fuente: Ficha, _ salida: Ficha) -> Bool {
    fuente.clave == salida.clave
      || (!fuente.esNumero && !salida.esNumero && !fuente.protegida
        && reparacionChica(fuente.clave, salida.clave))
  }

  /// Cada palabra con contenido de la salida, en orden y sin retroceder,
  /// con una de la fuente. Devuelve índice de salida → índice de fuente.
  static func alinear(_ f: [Ficha], _ s: [Ficha], desdeLaDerecha: Bool) -> [Int: Int]? {
    let cf = f.indices.filter { esContenido(f[$0]) }
    let cs = s.indices.filter { esContenido(s[$0]) }
    var mapa: [Int: Int] = [:]
    if desdeLaDerecha {
      var tope = cf.count - 1
      for i in cs.reversed() {
        guard tope >= 0, let k = (0 ... tope).reversed().first(where: { calza(f[cf[$0]], s[i]) }) else { return nil }
        mapa[i] = cf[k]; tope = k - 1
      }
    } else {
      var desde = 0
      for i in cs {
        guard desde < cf.count, let k = (desde ..< cf.count).first(where: { calza(f[cf[$0]], s[i]) }) else { return nil }
        mapa[i] = cf[k]; desde = k + 1
      }
    }
    return mapa
  }

  /// Un número o nombre que falta tiene que haber sido reemplazado ahí
  /// mismo: un marcador a ≤ 4 palabras, sin cruzar el fin de la frase, y
  /// algo después que sí quedó.
  static func reemplazadoAhiMismo(_ f: [Ficha], _ i: Int, retenidas: Set<Int>) -> Bool {
    var j = i + 1
    while j < f.count, j <= i + 4 {
      if f[j].antes.contains(where: { ".!?\n".contains($0) }) { return false }
      if esMarcador(f, j) {
        return (j + 1 ..< min(f.count, j + 6)).contains { retenidas.contains($0) && f[$0].esNumero == f[i].esNumero }
      }
      if f[j].esNumero && f[i].esNumero { return false }
      j += 1
    }
    return false
  }

  static func revisarAlineado(
    _ f: [Ficha], _ s: [Ficha], mapa: [Int: Int], corrigio: Bool
  ) throws(Rechazo) {
    let retenidas = Set(mapa.values)
    for i in f.indices where (f[i].esNumero || f[i].protegida) && !retenidas.contains(i) {
      // Tartamudeo: «2 2 cajas» → «2 cajas».
      if i > 0, f[i - 1].clave == f[i].clave, retenidas.contains(i - 1) { continue }
      if i + 1 < f.count, f[i + 1].clave == f[i].clave, retenidas.contains(i + 1) { continue }
      guard corrigio, reemplazadoAhiMismo(f, i, retenidas: retenidas) else {
        throw f[i].esNumero ? .cambioUnNumero : .perdioUnNombre
      }
    }
    // Cada negación, pegada a la misma palabra que le sigue en la fuente.
    func anclas(_ x: [Ficha], traducir: (Int) -> Int?) -> [(palabra: String, ancla: Int?)] {
      x.indices.compactMap { i in
        guard palabrasDeNegacion.contains(x[i].clave), !esMarcador(x, i),
          i == 0 || x[i - 1].clave != x[i].clave
        else { return nil }
        return (x[i].clave, (i + 1 ..< x.count).first { esContenido(x[$0]) }.flatMap(traducir))
      }
    }
    var anclasF = anclas(f) { $0 }
    // Lo que se corrigió se fue con su negación: «no el lunes, perdón, el martes».
    if corrigio { anclasF.removeAll { $0.ancla.map { !retenidas.contains($0) } ?? false } }
    let firma = { (a: [(palabra: String, ancla: Int?)]) in
      a.map { "\($0.palabra)→\($0.ancla.map(String.init) ?? "fin")" }.sorted()
    }
    guard firma(anclasF) == firma(anclas(s) { mapa[$0] }) else { throw .cambioUnaNegacion }

    let contenidoF = f.indices.filter { esContenido(f[$0]) }
    if contenidoF.count >= 3 {
      let retencion = Double(retenidas.count) / Double(contenidoF.count)
      guard retencion >= (corrigio ? 0.25 : 0.55) else { throw .largoFueraDeRango }
    }
  }
}

import Foundation

/// La búsqueda de la ventana de Ajustes (⌘F): qué ajustes calzan con lo
/// escrito, y en qué orden. Pura: la app le pasa el índice ya traducido y
/// recibe los ids.
///
/// Se busca como se recuerda (2026-10-19): sin tildes, sin mayúsculas, por
/// pedazos de palabra y en cualquier orden —«clave anth» encuentra la clave
/// de Anthropic, «microfono» el micrófono—. Cada palabra de la consulta
/// tiene que estar en algún lado del ajuste; el orden lo da dónde está: el
/// título pesa más que las palabras clave, y éstas más que la descripción.
public enum BusquedaDeAjustes {
  /// Un ajuste tal como se busca.
  public struct Buscable: Equatable, Sendable {
    public var id: String
    public var titulo: String
    public var detalle: String
    /// Sinónimos y nombres viejos: lo que alguien escribiría sin que esté
    /// en el título («api key», «idioma», el nombre de antes de un ajuste
    /// que se movió).
    public var palabras: [String]

    public init(id: String, titulo: String, detalle: String = "", palabras: [String] = []) {
      self.id = id
      self.titulo = titulo
      self.detalle = detalle
      self.palabras = palabras
    }
  }

  /// Los ids que calzan, del más al menos pertinente. Una consulta vacía o
  /// de puros espacios no calza con nada: la búsqueda está cerrada.
  public static func buscar(_ consulta: String, en indice: [Buscable]) -> [String] {
    let pedazos = palabras(de: consulta)
    guard !pedazos.isEmpty else { return [] }

    var puntajes: [(id: String, puntaje: Int, orden: Int)] = []
    for (orden, ajuste) in indice.enumerated() {
      let titulo = palabras(de: ajuste.titulo)
      let clave = ajuste.palabras.flatMap(palabras(de:))
      let detalle = palabras(de: ajuste.detalle)
      var total = 0
      var calzanTodos = true
      for pedazo in pedazos {
        let puntaje = max(
          puntos(pedazo, en: titulo, inicio: 30, dentro: 12),
          puntos(pedazo, en: clave, inicio: 20, dentro: 8),
          puntos(pedazo, en: detalle, inicio: 6, dentro: 2)
        )
        guard puntaje > 0 else {
          calzanTodos = false
          break
        }
        total += puntaje
      }
      // El título entero, escrito tal cual, va primero.
      if calzanTodos, plegar(ajuste.titulo).hasPrefix(pedazos.joined(separator: " ")) {
        total += 50
      }
      if calzanTodos { puntajes.append((ajuste.id, total, orden)) }
    }
    return puntajes
      .sorted { $0.puntaje != $1.puntaje ? $0.puntaje > $1.puntaje : $0.orden < $1.orden }
      .map(\.id)
  }

  /// Sin tildes ni mayúsculas, y la ñ como n: quien busca «contrasena» o
  /// «diseno» con un teclado inglés tiene que encontrar lo mismo.
  public static func plegar(_ texto: String) -> String {
    texto
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "es"))
      .lowercased()
  }

  static func palabras(de texto: String) -> [String] {
    plegar(texto)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  /// Cuánto vale un pedazo en una lista de palabras: más si una palabra
  /// empieza con él, menos si sólo lo contiene. Un pedazo de una letra sólo
  /// cuenta al principio: «a» no puede calzar con todo.
  private static func puntos(_ pedazo: String, en palabras: [String], inicio: Int, dentro: Int) -> Int {
    if palabras.contains(where: { $0.hasPrefix(pedazo) }) { return inicio }
    if pedazo.count > 1, palabras.contains(where: { $0.contains(pedazo) }) { return dentro }
    return 0
  }
}

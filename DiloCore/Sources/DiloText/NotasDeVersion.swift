import Foundation

/// Las notas de una versión, leídas del Markdown que se versiona en el repo.
///
/// Talkify mostraba su changelog trayéndolo de GitHub: la app sabía menos de
/// sí misma que un servidor, y sin internet no tenía nada que contar. Dilo
/// trae las suyas adentro, en español, y esta es la regla que las convierte en
/// algo que una vista pueda dibujar.
///
/// El Markdown que se entiende es a propósito un subconjunto —títulos de
/// nivel dos, vinetas y párrafos—, porque es el que usan las notas de Dilo
/// desde la 0.1.12. Lo de adentro de la línea (**negrita**, `código`, enlaces)
/// no se toca acá: viaja tal cual y lo resuelve `AttributedString` en la vista.
public struct NotasDeVersion: Equatable, Sendable {
  public enum Bloque: Equatable, Sendable {
    case titulo(String)
    case parrafo(String)
    case lista([String])
  }

  public let version: String
  public let bloques: [Bloque]

  public init(version: String, bloques: [Bloque]) {
    self.version = version
    self.bloques = bloques
  }

  /// Parte el Markdown en bloques.
  ///
  /// Un párrafo o una vineta partidos en varias líneas se vuelven a unir con
  /// un espacio: las notas se escriben a 80 columnas para que el diff sea
  /// legible, y ese corte es del archivo, no del texto.
  public init(version: String, markdown: String) {
    var bloques: [Bloque] = []
    var parrafo: [String] = []
    var lista: [String] = []

    func cerrarParrafo() {
      guard !parrafo.isEmpty else { return }
      bloques.append(.parrafo(parrafo.joined(separator: " ")))
      parrafo = []
    }

    func cerrarLista() {
      guard !lista.isEmpty else { return }
      bloques.append(.lista(lista))
      lista = []
    }

    for cruda in markdown.components(separatedBy: .newlines) {
      let linea = cruda.trimmingCharacters(in: .whitespaces)

      if linea.isEmpty {
        cerrarParrafo()
        cerrarLista()
        continue
      }

      if let titulo = Self.titulo(de: linea) {
        cerrarParrafo()
        cerrarLista()
        bloques.append(.titulo(titulo))
        continue
      }

      if let vineta = Self.vineta(de: linea) {
        cerrarParrafo()
        lista.append(vineta)
        continue
      }

      // Una línea suelta dentro de una lista es la continuación de la última
      // vineta, que es lo que significa en Markdown y lo que pasa cada vez que
      // una vineta no cabe en 80 columnas.
      if !lista.isEmpty {
        lista[lista.count - 1] += " " + linea
        continue
      }

      parrafo.append(linea)
    }

    cerrarParrafo()
    cerrarLista()

    self.init(version: version, bloques: bloques)
  }

  private static func titulo(de linea: String) -> String? {
    for marca in ["## ", "### "] where linea.hasPrefix(marca) {
      return String(linea.dropFirst(marca.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  private static func vineta(de linea: String) -> String? {
    for marca in ["- ", "* "] where linea.hasPrefix(marca) {
      return String(linea.dropFirst(marca.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
}

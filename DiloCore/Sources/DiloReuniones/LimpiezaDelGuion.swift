import Foundation

/// Sin tildes, sin mayúsculas y sin signos: se compara como se oye y se busca
/// como se recuerda, no como se escribió.
public enum TextoPlegado {
  public static func plegar(_ texto: String) -> String {
    texto.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "es"))
      .lowercased()
  }

  /// Una palabra sin la puntuación que Parakeet le pega («precio,» → «precio»).
  public static func palabra(_ texto: String) -> String {
    String(plegar(texto).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
  }

  /// Las palabras de una consulta.
  public static func palabras(_ texto: String) -> [String] {
    plegar(texto)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
}

/// Lo que se marca en las palabras de `yo` antes de armar el guion: lo que
/// dictaste mientras tanto y el eco de los parlantes.
public enum LimpiezaDelGuion {
  /// La ventana del eco: una palabra de `yo` que repite una de `ellos` dentro
  /// de ±1,5 s es el micrófono oyendo los parlantes (spec, «Eco», F1).
  public static let ventanaDeEco: Double = 1.5
  /// Palabras así de cortas («sí», «ya», «no») se repiten de verdad en una
  /// conversación: solas no bastan para decir eco. Con una vecina que también
  /// repite, sí. Es un refinamiento de la regla del spec, sin medir: con
  /// parlantes, lo que el micrófono re-capta llega en frases, no en
  /// monosílabos sueltos.
  public static let largoMinimoSola = 4

  /// Marca `eco` en las palabras de `yo` que repiten una de `ellos`. Los
  /// tiempos ya están en el reloj de la reunión.
  public static func marcarEco(_ palabras: inout [PalabraDelGuion]) {
    let deEllos = palabras.filter { $0.pista == .ellos }
      .map { (texto: TextoPlegado.palabra($0.texto), centro: $0.centro) }
      .filter { !$0.texto.isEmpty }
      .sorted { $0.centro < $1.centro }
    guard !deEllos.isEmpty else { return }

    let indicesDeYo = palabras.indices.filter { palabras[$0].pista == .yo }.sorted {
      palabras[$0].desde < palabras[$1].desde
    }
    let repite = indicesDeYo.map { indice -> Bool in
      let texto = TextoPlegado.palabra(palabras[indice].texto)
      guard !texto.isEmpty else { return false }
      return hayIgual(texto, cerca: palabras[indice].centro, en: deEllos)
    }
    for (posicion, indice) in indicesDeYo.enumerated() where repite[posicion] {
      let largo = TextoPlegado.palabra(palabras[indice].texto).count
      let vecinaRepite =
        (posicion > 0 && repite[posicion - 1]) || (posicion + 1 < repite.count && repite[posicion + 1])
      if largo >= largoMinimoSola || vecinaRepite { palabras[indice].marcar(.eco) }
    }
  }

  private static func hayIgual(
    _ texto: String, cerca centro: Double, en deEllos: [(texto: String, centro: Double)]
  ) -> Bool {
    // Búsqueda binaria del primero que entra en la ventana: una reunión de una
    // hora son diez mil palabras por pista.
    var bajo = 0
    var alto = deEllos.count
    while bajo < alto {
      let medio = (bajo + alto) / 2
      if deEllos[medio].centro < centro - ventanaDeEco { bajo = medio + 1 } else { alto = medio }
    }
    var i = bajo
    while i < deEllos.count, deEllos[i].centro <= centro + ventanaDeEco {
      if deEllos[i].texto == texto { return true }
      i += 1
    }
    return false
  }

  /// Marca `dictado` en las palabras de `yo` que caen en un tramo en que la
  /// persona dictaba. Basta con que la palabra toque el tramo: el gatillo se
  /// aprieta un poco antes de hablar y se suelta un poco después.
  public static func marcarDictado(_ palabras: inout [PalabraDelGuion], tramos: [TramoDeDictado]) {
    guard !tramos.isEmpty else { return }
    for indice in palabras.indices where palabras[indice].pista == .yo {
      let p = palabras[indice]
      if tramos.contains(where: { p.hasta > $0.desde && p.desde < $0.hasta }) {
        palabras[indice].marcar(.dictado)
      }
    }
  }
}

import Foundation

/// **Cómo se pegan dos trozos de dictado.** Una sola función pura para todos
/// los caminos: los parciales de Parakeet, la pasada final sobre el buffer,
/// los segmentos que entrega `SpeechTranscriber` de Apple y lo que el
/// controlador muestra mientras hablas.
///
/// Existe porque cada camino lo hacía con `+=` y, cada cierto trecho, la
/// última palabra de un trozo terminaba pegada a la primera del siguiente:
/// «Igual se ve que es rápidoAhora habría que ver qué tan». Un motor entrega
/// cada trozo recortado y sin saber qué vino antes; quien los junta es el
/// único que puede poner el espacio, y hasta hoy nadie lo ponía.
///
/// **Lo único que decide es el espacio.** No inventa puntos ni toca
/// mayúsculas: que el motor escriba «Ahora» con mayúscula por ser el comienzo
/// de su trozo es un defecto del motor, no una frase nueva, pero bajarle la
/// letra rompería un nombre propio de verdad ("Ahora" contra "Ana") y ponerle
/// un punto al trozo anterior inventaría una frase que nadie dictó. El
/// espacio, en cambio, no se puede equivocar: sin él las dos palabras no
/// existen, y con él el texto se lee.
public enum Union {
  /// Los signos que abren algo y se quedan pegados a lo que sigue.
  private static let aperturas: Set<Character> = ["¿", "¡", "(", "[", "{", "«", "\"", "“", "‘", "—", "–"]

  /// Los signos que cierran o puntúan y se quedan pegados a lo que viene
  /// antes. La comilla recta no está: abre y cierra con el mismo carácter, y
  /// ante la duda vale más un espacio de sobra que una palabra partida.
  private static let cierres: Set<Character> = [
    ",", ".", ";", ":", "?", "!", ")", "]", "}", "»", "”", "’", "…", "%",
  ]

  /// Pega los trozos en el orden en que llegaron.
  ///
  /// Cada trozo entra recortado y los vacíos no cuentan: un parcial que no
  /// dijo nada no puede dejar un espacio de más. Entre dos trozos va **un**
  /// espacio, salvo que el de la izquierda termine en apertura o el de la
  /// derecha empiece en cierre.
  public static func unir(_ segmentos: [String]) -> String {
    var resultado = ""
    for segmento in segmentos {
      let trozo = segmento.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trozo.isEmpty else { continue }
      if resultado.isEmpty {
        resultado = trozo
        continue
      }
      resultado += colaDe(resultado, trozo)
    }
    return resultado
  }

  /// Junta dos trozos. El caso de todos los días: lo que ya se llevaba y lo
  /// que acaba de llegar.
  public static func unir(_ izquierda: String, _ derecha: String) -> String {
    unir([izquierda, derecha])
  }

  /// El trozo de la derecha listo para pegarse a lo que ya va: recortado y
  /// con el espacio adelante si hace falta.
  ///
  /// Existe para los lugares donde los dos pedazos tienen que seguir
  /// separados —el HUD dibuja lo firme quieto y lo volátil parpadeando, y
  /// cuenta caracteres para saber dónde termina uno— pero el texto junto
  /// tiene que leerse igual.
  public static func colaDe(_ izquierda: String, _ derecha: String) -> String {
    let trozo = derecha.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trozo.isEmpty else { return "" }
    guard !izquierda.isEmpty else { return trozo }
    return necesitaEspacio(despuesDe: izquierda, antesDe: trozo) ? " " + trozo : trozo
  }

  /// Si entre estos dos trozos va un espacio. Los dos llegan ya recortados.
  static func necesitaEspacio(despuesDe izquierda: String, antesDe derecha: String) -> Bool {
    guard let ultima = izquierda.last, let primera = derecha.first else { return false }
    if aperturas.contains(ultima) { return false }
    if cierres.contains(primera) { return false }
    return true
  }
}

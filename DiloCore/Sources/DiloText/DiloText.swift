import Foundation

/// La costura de español de Dilo: todo lo que el motor reconoce pasa por acá
/// antes de que nadie más lo toque.
///
/// Cinco pasos, en este orden: espacios, comandos de formato, muletillas,
/// reemplazos y tus palabras. Los comandos van antes de las muletillas
/// porque «o sea coma» tiene que quedar «o sea,» para que la regla de la
/// pausa lo reconozca. Las muletillas van antes del diccionario porque borrar
/// un "eh" del medio deja juntas dos palabras que eran una sola ("Charge eh
/// B"), y el diccionario las puede unir; al revés, no. Los reemplazos van
/// antes de tus palabras para que «chat ge pe te» llegue como «ChatGPT» y no
/// como una corrección por parecido a medias.
public enum DiloText {
  /// Lo que la persona configuró. Se captura con el resto de los ajustes de
  /// la sesión: cambiar una palabra a mitad de dictado aplica al siguiente.
  public struct Preferencias: Equatable, Sendable {
    /// Las muletillas de la persona. `nil` usa las de fábrica; una lista
    /// vacía apaga la limpieza, que es la forma de decir "no me toques nada".
    public var muletillasPropias: [String]?
    public var palabrasPropias: [String]
    public var umbral: Double
    /// «Coma», «punto», «nueva línea», «borra eso». Prendido de fábrica:
    /// sin él, un salto de línea dictado sin modo no tiene cómo llegar.
    public var comandosDeFormato: Bool
    /// «Cuando digo… / Escríbelo así».
    public var reemplazos: [Reemplazo]

    public init(
      muletillasPropias: [String]? = nil,
      palabrasPropias: [String] = [],
      umbral: Double = DiccionarioPersonal.umbralDeFabrica,
      comandosDeFormato: Bool = true,
      reemplazos: [Reemplazo] = []
    ) {
      self.muletillasPropias = muletillasPropias
      self.palabrasPropias = palabrasPropias
      self.umbral = umbral
      self.comandosDeFormato = comandosDeFormato
      self.reemplazos = reemplazos
    }

    public static let deFabrica = Preferencias()
  }

  public static func limpiar(
    _ texto: String, con preferencias: Preferencias = .deFabrica
  ) -> String {
    let sinEspaciosDeMas = limpiarEspacios(texto)
    let conSignos = preferencias.comandosDeFormato
      ? ComandosDeFormato.aplicar(sinEspaciosDeMas) : sinEspaciosDeMas
    let sinMuletillas = Muletillas.limpiar(
      conSignos, propias: preferencias.muletillasPropias
    )
    let reemplazado = Reemplazos.aplicar(preferencias.reemplazos, a: sinMuletillas)
    return DiccionarioPersonal.aplicar(
      reemplazado,
      palabras: preferencias.palabrasPropias,
      umbral: preferencias.umbral
    )
  }

  /// Quita los espacios de los bordes y colapsa los espacios repetidos que
  /// deja el dictado cuando uno duda a mitad de frase.
  ///
  /// No toca los saltos de línea: dictar código y dictar un correo comparten
  /// esta función, y ahí los saltos son contenido.
  public static func limpiarEspacios(_ texto: String) -> String {
    let lineas = texto.split(separator: "\n", omittingEmptySubsequences: false).map { linea in
      linea
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
    }
    return lineas.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

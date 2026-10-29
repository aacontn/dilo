import FluidAudio
import Foundation

/// Cuál de los modelos de Parakeet dicta cuando el **Motor de voz** es
/// Parakeet.
///
/// Las dos son el mismo motor para el resto de la app: mismo tokenizer, mismos
/// 25 idiomas, misma ventana de 15 s y el mismo contrato de decodificación
/// (FluidAudio las trata como una familia, `isV3Family`). Lo único distinto
/// son los pesos. Por eso no son dos `SpeechEngineKind`: la elección guardada
/// en `speechEngine` sigue siendo `parakeet`, y la variante se resuelve por
/// lo que hay en disco (`ResolucionDeParakeet`).
///
/// El `rawValue` se guarda en `UserDefaults` (`PreferenciaDeVariante`): no se
/// renombra nunca.
public enum VarianteDeParakeet: String, CaseIterable, Sendable {
  /// Parakeet TDT 0.6B v3, int8. La que Dilo bajaba hasta la 0.9.x.
  case v3
  /// Parakeet Ultra (moondream): un post-entrenamiento de v3 con encoder int8
  /// lineal. En FLEURS de 24 idiomas baja el WER de 14,81 % a 11,67 % a la
  /// misma velocidad (FluidAudio 0.17.3, `Documentation/ASR/ParakeetUltra.md`;
  /// ese FLEURS no trae `es_es`, y por eso existe `scripts/comparar-motores.sh`).
  case ultra

  /// **La que se ofrece a quien no tiene ninguna.** Una instalación nueva baja
  /// Ultra; quien ya tiene v3 sigue con v3 hasta que elija bajar Ultra.
  public static let recomendada: VarianteDeParakeet = .ultra

  var version: AsrModelVersion {
    switch self {
    case .v3: .v3
    case .ultra: .ultra
    }
  }

  /// La carpeta dentro de `models/`. Es la que FluidAudio arma sola con el
  /// nombre del repo, así que el v3 que ya está en disco se sigue encontrando
  /// donde siempre (`parakeet-tdt-0.6b-v3`).
  public var nombreDeCarpeta: String {
    switch self {
    case .v3: Repo.parakeetV3.folderName
    case .ultra: Repo.parakeetUltra.folderName
    }
  }

  public var nombre: String {
    switch self {
    case .v3: "Parakeet v3"
    case .ultra: "Parakeet Ultra"
    }
  }

  /// Lo que se baja, en megas, para decirlo **antes** de que la persona
  /// apriete. Medido sobre la carpeta ya bajada (`du -sm`), no sacado de la
  /// ficha del modelo: la ficha cuenta el encoder y no el resto.
  public var megasDeDescarga: Int {
    switch self {
    case .v3: 469
    case .ultra: 615
    }
  }
}

/// Qué variante de Parakeet dicta, qué se ofrece bajar y qué se ofrece
/// borrar. Puro: recibe lo que hay en disco y lo que eligió la persona, y
/// por eso se prueba con `swift test` sin bajar un giga de modelos.
public enum ResolucionDeParakeet {
  /// La que dicta. Lo elegido a mano gana si está en disco; si no, la mejor
  /// que haya. **Nada se baja solo**: con v3 en disco y Ultra no, dicta v3.
  /// Nil cuando no hay ninguna, y ahí el router cae a Apple y lo dice.
  public static func enUso(
    enDisco: Set<VarianteDeParakeet>,
    elegida: VarianteDeParakeet?
  ) -> VarianteDeParakeet? {
    if let elegida, enDisco.contains(elegida) { return elegida }
    if enDisco.contains(.ultra) { return .ultra }
    if enDisco.contains(.v3) { return .v3 }
    return nil
  }

  /// La que Ajustes ofrece bajar, o nil si no hay nada que ofrecer. Es
  /// siempre la recomendada: a quien ya la tiene no se le ofrece otra
  /// descarga, y v3 se baja sólo a mano.
  public static func paraBajar(enDisco: Set<VarianteDeParakeet>) -> VarianteDeParakeet? {
    enDisco.contains(.recomendada) ? nil : .recomendada
  }

  /// La que sobra en disco: v3 cuando ya dicta Ultra. Se **ofrece** mandarla a
  /// la Papelera; nunca se borra sola, porque quien compare las dos con sus
  /// dictados puede querer volver.
  public static func paraBorrar(
    enDisco: Set<VarianteDeParakeet>,
    enUso: VarianteDeParakeet?
  ) -> VarianteDeParakeet? {
    guard let enUso, enUso != .v3, enDisco.contains(.v3) else { return nil }
    return .v3
  }
}

/// Dónde se guarda la variante elegida a mano. Vacío es «la mejor que haya en
/// disco», que es lo que tiene todo el mundo hasta que toque «Usar este».
///
/// La clave es nueva: `speechEngine` sigue guardando `parakeet` igual que
/// antes, y quien venía de la 0.9.x no pierde nada.
public enum PreferenciaDeVariante {
  public static let clave = "diloVarianteDeParakeet"

  public static func leer(_ defaults: UserDefaults) -> VarianteDeParakeet? {
    defaults.string(forKey: clave).flatMap(VarianteDeParakeet.init(rawValue:))
  }

  public static func guardar(_ variante: VarianteDeParakeet?, in defaults: UserDefaults) {
    if let variante {
      defaults.set(variante.rawValue, forKey: clave)
    } else {
      defaults.removeObject(forKey: clave)
    }
  }
}

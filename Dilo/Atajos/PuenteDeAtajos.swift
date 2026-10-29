import AppIntents
import DiloModes
import DiloPlataforma
import Foundation

/// Lo que los App Intents necesitan de la app viva. Los intents corren en el
/// proceso de Dilo —macOS lo abre si no estaba— y lo encuentran acá:
/// `AppDelegate` lo llena al arrancar con `AccionesDeDiloEnVivo`, que llama a
/// los mismos controladores que el menú de la barra y el panel del hover. Un
/// atajo no tiene lógica propia: si el menú y el atajo hicieran lo mismo por
/// dos caminos, tarde o temprano dirían cosas distintas.
///
/// Un protocolo y no closures sueltas: los tests de `EjecucionDeAtajos`
/// pasan un doble entero, sin tocar el micrófono ni el portapapeles.
@MainActor
protocol AccionesParaAtajos: AnyObject {
  func dictar(_ pedido: DirectDictationController.ModoPedido) -> DirectDictationController.RespuestaAlDictar
  func dictarNota()
  var modos: [Modo] { get }
  /// El modo del atajo general (el que se elige en el panel del hover); nil
  /// es el dictado sin modo.
  var modoDelAtajoGeneral: String? { get set }
  var ultimoDictado: UltimoDictado? { get }
  func copiar(_ texto: String)
  var historialEncendido: Bool { get }
  func buscarEnHistorial(_ consulta: String) async throws -> [String]
  func transcribir(_ archivo: URL) async throws -> String
  func mostrarEnLaMuesca(_ aviso: AvisoDeAfuera)
}

@MainActor
enum PuenteDeAtajos {
  /// La app viva, o nil mientras arranca (y siempre, en los tests).
  static weak var actual: (any AccionesParaAtajos)?

  static func requerido() throws(FallaDeAtajo) -> any AccionesParaAtajos {
    guard let actual else { throw .diloNoEstaListo }
    return actual
  }

  /// Las reuniones de la app viva (`ControlDeReuniones`), aparte de las
  /// acciones del dictado.
  static weak var reuniones: (any ReunionesParaAtajos)?

  static func requeridoParaReuniones() throws(FallaDeAtajo) -> any ReunionesParaAtajos {
    guard let reuniones else { throw .diloNoEstaListo }
    return reuniones
  }
}

/// Lo que un atajo contesta cuando no puede. Cada frase dice qué hacer, no
/// sólo qué falló: Atajos la muestra tal cual y Siri la lee.
enum FallaDeAtajo: Error, Equatable, CustomLocalizedStringResourceConvertible {
  case diloNoEstaListo
  case sinDictado
  case historialApagado
  case modoDesconocido
  case archivoIlegible
  case textoVacio

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .diloNoEstaListo:
      "Dilo todavía está arrancando. Prueba de nuevo en unos segundos."
    case .sinDictado:
      "No hay un dictado reciente. Lo último que dictas vive sólo en memoria y se va al cerrar Dilo."
    case .historialApagado:
      "El historial está apagado. Actívalo en Dilo → Ajustes → Historial."
    case .modoDesconocido:
      "Ese modo ya no existe en Dilo. Elige otro en el atajo."
    case .archivoIlegible:
      "No pude leer ese archivo."
    case .textoVacio:
      "No hay nada que mostrar: el texto llegó vacío."
    }
  }
}

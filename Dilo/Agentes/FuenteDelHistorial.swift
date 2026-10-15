import DiloAgentes
import Foundation

/// Lo que el servidor MCP y el CLI leen de Dilo: el historial que la persona
/// eligió guardar y Tus palabras.
///
/// No crea `AppSettings` ni nada de la app viva: lee las mismas claves de
/// `UserDefaults` (`AppSettings.lecturaParaAgentes`) y los mismos archivos
/// diarios con el mismo parser (`DictationHistoryStore.entradas(in:)`). Lo
/// único propio es el id, que para un agente tiene que ser estable
/// (`IdsDeDictados`).
struct FuenteDelHistorial: FuenteDeDilo {
  /// El dominio de ajustes de la app, cuando no es el de `Bundle.main`: el
  /// proceso entró por el enlace `dilo` y Foundation no ve el bundle
  /// (`ArranqueParaAgentes.bundleDeLaApp`). Nil es `UserDefaults.standard`.
  var dominio: String?

  /// Se piden en cada llamada: un servidor vive lo que dura la sesión del
  /// agente, y la persona puede encender el historial o cambiar la carpeta
  /// mientras tanto.
  private var ajustes: AppSettings.LecturaParaAgentes {
    let defaults = dominio.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    return AppSettings.lecturaParaAgentes(de: defaults)
  }

  var historialEncendido: Bool { ajustes.historialEncendido }

  func dictados() async throws -> [DictadoParaAgentes] {
    let carpeta = ajustes.carpetaDelHistorial
    // Una carpeta que no existe es un historial recién encendido, sin nada
    // todavía; una que existe y no se deja listar (permisos, un disco
    // desmontado a medias) es un error que el agente tiene que poder decir.
    var esCarpeta: ObjCBool = false
    if FileManager.default.fileExists(atPath: carpeta.path(percentEncoded: false), isDirectory: &esCarpeta) {
      guard esCarpeta.boolValue else { throw CocoaError(.fileReadInvalidFileName) }
      _ = try FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)
    }
    let entradas = try await DictationHistoryStore().entradas(in: carpeta)
    return Self.paraAgentes(entradas)
  }

  func tusPalabras() -> [String] { ajustes.palabrasPropias }

  /// Las entradas del historial —del más nuevo al más viejo, como las da el
  /// store— con su id para agentes.
  static func paraAgentes(_ entradas: [DictationHistoryStore.Entrada]) -> [DictadoParaAgentes] {
    let ids = IdsDeDictados.asignar(entradas.map { IdsDeDictados.base(dia: $0.dia, hora: $0.hora) })
    return zip(ids, entradas).map { id, entrada in
      DictadoParaAgentes(id: id, app: entrada.fuente, modo: entrada.modo, motor: entrada.motor, texto: entrada.texto)
    }
  }
}

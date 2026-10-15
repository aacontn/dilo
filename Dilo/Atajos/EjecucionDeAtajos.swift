import AppIntents
import DiloModes
import DiloPlataforma
import Foundation

/// Lo que hace cada App Intent, separado del `perform()`: recibe las
/// acciones de la app como parámetro, así los tests pasan un doble y no
/// dependen del puente global ni de una app levantada.
@MainActor
enum EjecucionDeAtajos {
  /// «Sin modo» primero y después los modos en el orden de Ajustes.
  static func modos(_ acciones: (any AccionesParaAtajos)?, que texto: String? = nil) -> [ModoDeDilo] {
    let todos = [ModoDeDilo.sinModo] + (acciones?.modos ?? []).map(ModoDeDilo.init)
    guard let texto, !texto.trimmingCharacters(in: .whitespaces).isEmpty else { return todos }
    let buscado = plegar(texto)
    return todos.filter { plegar($0.nombre).contains(buscado) }
  }

  /// Como se dice, no como se escribe: «codigo» encuentra «Código».
  static func plegar(_ texto: String) -> String {
    texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
      .trimmingCharacters(in: .whitespaces)
  }

  static func pedido(de modo: ModoDeDilo?) -> DirectDictationController.ModoPedido {
    guard let modo else { return .elDelAtajoGeneral }
    return modo.esSinModo ? .ninguno : .modo(modo.id)
  }

  static func dictar(
    _ acciones: any AccionesParaAtajos, modo: ModoDeDilo?
  ) throws(FallaDeAtajo) -> DirectDictationController.RespuestaAlDictar {
    let respuesta = acciones.dictar(pedido(de: modo))
    if respuesta == .modoDesconocido { throw .modoDesconocido }
    return respuesta
  }

  /// Fija el modo del atajo general, lo mismo que elegirlo en el panel del
  /// hover. Devuelve el nombre del modo, o nil para «sin modo».
  static func elegirModo(_ acciones: any AccionesParaAtajos, _ modo: ModoDeDilo) throws(FallaDeAtajo) -> String? {
    guard !modo.esSinModo else {
      acciones.modoDelAtajoGeneral = nil
      return nil
    }
    guard let elegido = acciones.modos.modo(modo.id) else { throw .modoDesconocido }
    acciones.modoDelAtajoGeneral = elegido.id
    return elegido.nombre
  }

  static func ultimoDictado(_ acciones: any AccionesParaAtajos, mitad: MitadDelDictado) throws(FallaDeAtajo) -> String {
    let texto = acciones.ultimoDictado?.texto(mitad.mitad) ?? ""
    guard !texto.isEmpty else { throw .sinDictado }
    return texto
  }

  /// Lo copia y además lo devuelve, para encadenarlo en un atajo.
  static func copiarUltimo(_ acciones: any AccionesParaAtajos, mitad: MitadDelDictado) throws(FallaDeAtajo) -> String {
    let texto = try ultimoDictado(acciones, mitad: mitad)
    acciones.copiar(texto)
    return texto
  }

  static let maximoDeResultados = 50

  /// Del más nuevo al más viejo, a lo más `maximo`. Una consulta vacía
  /// devuelve los últimos.
  static func buscar(_ acciones: any AccionesParaAtajos, consulta: String, maximo: Int) async throws -> [String] {
    guard acciones.historialEncendido else { throw FallaDeAtajo.historialApagado }
    let tope = min(max(maximo, 1), maximoDeResultados)
    return Array(try await acciones.buscarEnHistorial(consulta).prefix(tope))
  }

  static func mostrar(
    _ acciones: any AccionesParaAtajos, texto: String, simbolo: String?, segundos: Int?,
    simboloExiste: (String) -> Bool
  ) throws(FallaDeAtajo) {
    guard let aviso = AvisoDeAfuera(texto: texto, simbolo: simbolo, segundos: segundos, simboloExiste: simboloExiste)
    else { throw .textoVacio }
    acciones.mostrarEnLaMuesca(aviso)
  }

  /// Le da al cuerpo una URL legible del archivo de un atajo y limpia lo
  /// que haya creado, salga bien o mal.
  ///
  /// Si el archivo viene con ruta se usa ésa —un video de un giga no se
  /// carga en memoria—; si sólo vienen los bytes, se escriben a un temporal
  /// propio y se borra al terminar, como el arrastre al notch.
  static func conArchivo<T>(
    _ archivo: IntentFile,
    temporales: URL = FileManager.default.temporaryDirectory,
    _ cuerpo: (URL) async throws -> T
  ) async throws -> T {
    if let url = archivo.fileURL {
      let accedido = url.startAccessingSecurityScopedResource()
      defer { if accedido { url.stopAccessingSecurityScopedResource() } }
      if FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) {
        return try await cuerpo(url)
      }
    }
    let extension_ = URL(filePath: archivo.filename).pathExtension
    let temporal = temporales
      .appending(path: "dilo-atajo-\(UUID().uuidString)")
      .appendingPathExtension(extension_.isEmpty ? "m4a" : extension_)
    do {
      try archivo.data.write(to: temporal, options: .atomic)
    } catch {
      throw FallaDeAtajo.archivoIlegible
    }
    defer { try? FileManager.default.removeItem(at: temporal) }
    return try await cuerpo(temporal)
  }
}

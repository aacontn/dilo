import CryptoKit
import Foundation
import os

/// Phonon en disco: el runtime (`ptts`), el modelo y las voces, cada uno con
/// su hash fijo.
///
/// **El runtime no va dentro del `.app`.** Enlazar `PhononCore.xcframework`
/// suma ~4–6 MB al binario (medido: un ejecutable que sólo lo usa pesa 5,8 MB,
/// 4,2 MB sin símbolos) y el `.app` ya está en 21 de 25 MB; además ese camino
/// corre Core ML y pide exportar el modelo con Rust. El CLI precompilado de
/// la release (8,4 MB comprimido) corre en CPU, se baja a pedido como el
/// modelo y se verifica contra el SHA-256 publicado en `SHA256SUMS`: lo que
/// no calza no se ejecuta.
///
/// **El modelo no se puede bajar desde la app.** `gradium/phonon-40m-es` es
/// un repo con aceptación de términos en Hugging Face y responde 401 sin el
/// token de quien los aceptó, y la app no lleva ni pide ese token. Lo instala
/// `scripts/instalar-phonon.sh`, que lo lee del Llavero de quien lo corre. Las
/// voces (Apache 2.0) y el runtime (MIT/Apache) son públicos y sí se bajan
/// desde la app.
///
/// Vive en `~/Library/Application Support/Dilo/models/phonon/`, al lado de
/// Parakeet, por lo mismo que Parakeet: es de Dilo y se borra con Dilo.
public actor InstalacionDePhonon {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "lectura")

  public struct Archivo: Sendable {
    public let nombre: String
    public let sha256: String
    public let bytes: Int64
  }

  /// La release de `gradium-ai/xn-ptts` y el hash de su `SHA256SUMS`.
  public static let versionDelRuntime = "0.5.0"
  static let urlDelRuntime = URL(
    string: "https://github.com/gradium-ai/xn-ptts/releases/download/v0.5.0/ptts-0.5.0-aarch64-apple-darwin.tar.gz"
  )!
  static let shaDelTar = "b8e8a889fbe7888604908a932a1643611e5156719c5c15829c700594e12a0b76"
  /// El del ejecutable ya extraído: se revisa antes de cada uso que no sea
  /// el primero de la sesión, para que un archivo cambiado no se ejecute.
  static let shaDelEjecutable = "e1d0ebd28a1ce661830aed6ba8fe2964d33b75fafb7c36ff282b6081c0646c90"
  public static let bytesDelRuntime: Int64 = 8_466_541

  /// `gradium/phonon-40m-es`, revisión fija. CC BY-NC 4.0: uso personal y no
  /// comercial, que es el de Dilo.
  public static let revisionDelModelo = "e5e052b26e31abd5918ade71d3135e69d51a66f8"
  public static let archivosDelModelo: [Archivo] = [
    .init(nombre: "config.json", sha256: "353a6153d9bfacdfe9bd2426e4ae1d1c055c86a17cdb172ca3eacd1dfb454a22", bytes: 4_634),
    .init(nombre: "tokenizer.json", sha256: "e6a00cd1a15986fa1e79ba338fa8174a2dd8c6c4630a66bf9c36237b2ebc4a15", bytes: 278_837),
    .init(nombre: "model.q8.gguf", sha256: "b90d5897e5e663c56a8975a8b2d6f7db557b9bad59ad82a82361ac56614c2a5c", bytes: 74_553_568),
    .init(nombre: "default-voice.safetensors", sha256: "be8c5f329070f40c39007bea13cee9503fe71599704cfe55c67d6eb51f5e6eb2", bytes: 256_136),
  ]

  public static var carpeta: URL { raiz }

  /// Se cambia sólo desde el banco de voces, para probar la instalación de
  /// punta a punta sin tocar la de la app.
  public nonisolated(unsafe) static var raiz: URL =
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dilo/models/phonon", isDirectory: true)

  public static var ejecutable: URL {
    carpeta.appendingPathComponent("runtime/ptts-\(versionDelRuntime)/ptts")
  }

  public static var carpetaDelModelo: URL {
    carpeta.appendingPathComponent("phonon-40m-es", isDirectory: true)
  }

  public static func archivoDeVoz(_ voz: VozDePhonon) -> URL {
    carpeta.appendingPathComponent("voces/\(voz.archivo).safetensors")
  }

  /// Qué está en disco. Mira tamaños y no hashes: se llama desde Ajustes y
  /// leer 75 MB para dibujar una fila sería el congelamiento de siempre.
  public struct Estado: Sendable, Equatable {
    public var runtime: Bool
    public var modelo: Bool
    public var voz: Bool
    public var listo: Bool { runtime && modelo && voz }

    public init(runtime: Bool, modelo: Bool, voz: Bool) {
      self.runtime = runtime
      self.modelo = modelo
      self.voz = voz
    }
  }

  public static func estado(voz: VozDePhonon) -> Estado {
    Estado(
      runtime: tiene(ejecutable, bytes: nil),
      modelo: archivosDelModelo.allSatisfy { tiene(carpetaDelModelo.appendingPathComponent($0.nombre), bytes: $0.bytes) },
      voz: tiene(archivoDeVoz(voz), bytes: nil)
    )
  }

  private static func tiene(_ url: URL, bytes: Int64?) -> Bool {
    guard let atributos = try? FileManager.default.attributesOfItem(atPath: url.path),
      let tamano = atributos[.size] as? Int64
    else { return false }
    return bytes.map { $0 == tamano } ?? (tamano > 0)
  }

  public enum Falla: Error, Equatable, Sendable {
    /// El modelo con términos de Hugging Face: lo instala el script.
    case faltaElModelo
    case hashNoCalza(String)
    case sinConexion
    case descomprimir
  }

  private var descarga: Task<Void, any Error>?
  private var ejecutableVerificado = false

  public init() {}

  /// Baja lo que falta y se puede bajar —el runtime y la voz—, informando el
  /// avance. Dos llamadas seguidas esperan la misma descarga.
  public func preparar(
    voz: VozDePhonon,
    progreso: @escaping @Sendable (ProgresoDeDescarga) -> Void
  ) async throws {
    if let descarga {
      try await descarga.value
      return
    }
    let tarea = Task { () throws -> Void in
      let estado = Self.estado(voz: voz)
      if !estado.runtime {
        try await Self.bajarRuntime { fraccion in
          progreso(ProgresoDeDescarga(fraccion: fraccion * 0.95, fase: "Bajando el motor de Phonon…"))
        }
      }
      if !estado.voz {
        progreso(ProgresoDeDescarga(fraccion: 0.96, fase: "Bajando la voz \(voz.nombre)…"))
        try await Self.bajar(
          VocesDePhonon.url(de: voz), a: Self.archivoDeVoz(voz), sha256: voz.sha256, avance: { _ in }
        )
      }
      progreso(ProgresoDeDescarga(fraccion: 1, fase: "Listo"))
      // El modelo se mira al final, para que el runtime y la voz ya queden
      // bajados cuando la persona corra el script.
      if !Self.estado(voz: voz).modelo { throw Falla.faltaElModelo }
    }
    descarga = tarea
    defer { descarga = nil }
    try await tarea.value
  }

  public func cancelar() {
    descarga?.cancel()
    descarga = nil
  }

  /// Borra todo lo de Phonon, también el modelo que instaló el script.
  public func borrar() throws {
    cancelar()
    ejecutableVerificado = false
    if FileManager.default.fileExists(atPath: Self.carpeta.path) {
      try FileManager.default.removeItem(at: Self.carpeta)
    }
  }

  /// La ruta del ejecutable, verificado una vez por sesión contra su hash.
  func ejecutableListo() throws -> URL {
    if !ejecutableVerificado {
      guard try Self.sha256(de: Self.ejecutable) == Self.shaDelEjecutable else {
        throw Falla.hashNoCalza("ptts")
      }
      ejecutableVerificado = true
    }
    return Self.ejecutable
  }

  private static func bajarRuntime(avance: @escaping @Sendable (Double) -> Void) async throws {
    let fm = FileManager.default
    let destino = ejecutable.deletingLastPathComponent().deletingLastPathComponent()
    let tar = carpeta.appendingPathComponent("runtime/ptts.tar.gz")
    try fm.createDirectory(at: destino, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tar) }
    try await bajar(urlDelRuntime, a: tar, sha256: shaDelTar, avance: avance)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = ["-xzf", tar.path, "-C", destino.path]
    let carpetaDelTar = destino.appendingPathComponent("ptts-\(versionDelRuntime)-aarch64-apple-darwin")
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0, fm.fileExists(atPath: carpetaDelTar.appendingPathComponent("ptts").path) else {
      throw Falla.descomprimir
    }
    let final = ejecutable.deletingLastPathComponent()
    if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
    try fm.moveItem(at: carpetaDelTar, to: final)
    guard try sha256(de: ejecutable) == shaDelEjecutable else {
      try? fm.removeItem(at: final)
      throw Falla.hashNoCalza("ptts")
    }
    logger.info("runtime de Phonon \(versionDelRuntime, privacy: .public) listo")
  }

  /// Baja a un archivo temporal y lo mueve a su lugar sólo si el hash calza:
  /// una descarga cortada o cambiada no queda en disco como si fuera buena.
  static func bajar(
    _ url: URL, a destino: URL, sha256 esperado: String,
    avance: @escaping @Sendable (Double) -> Void
  ) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
    let (bytes, respuesta) = try await URLSession.shared.bytes(from: url)
    guard let http = respuesta as? HTTPURLResponse, http.statusCode == 200 else {
      throw Falla.sinConexion
    }
    let total = max(http.expectedContentLength, 1)
    let temporal = destino.appendingPathExtension("parcial")
    fm.createFile(atPath: temporal.path, contents: nil)
    let manija = try FileHandle(forWritingTo: temporal)
    var hash = SHA256()
    var bufer = Data()
    var llevados: Int64 = 0
    do {
      for try await byte in bytes {
        bufer.append(byte)
        if bufer.count >= 1 << 16 {
          try Task.checkCancellation()
          hash.update(data: bufer)
          try manija.write(contentsOf: bufer)
          llevados += Int64(bufer.count)
          bufer.removeAll(keepingCapacity: true)
          avance(Double(llevados) / Double(total))
        }
      }
      hash.update(data: bufer)
      try manija.write(contentsOf: bufer)
      try manija.close()
    } catch {
      try? manija.close()
      try? fm.removeItem(at: temporal)
      throw error
    }
    let calculado = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard calculado == esperado else {
      try? fm.removeItem(at: temporal)
      throw Falla.hashNoCalza(destino.lastPathComponent)
    }
    if fm.fileExists(atPath: destino.path) { try fm.removeItem(at: destino) }
    try fm.moveItem(at: temporal, to: destino)
  }

  static func sha256(de url: URL) throws -> String {
    let manija = try FileHandle(forReadingFrom: url)
    defer { try? manija.close() }
    var hash = SHA256()
    while let trozo = try manija.read(upToCount: 1 << 20), !trozo.isEmpty {
      hash.update(data: trozo)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

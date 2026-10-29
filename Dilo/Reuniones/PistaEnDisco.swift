import DiloReuniones
import Foundation
import os

/// Una **Pista** escribiéndose a disco: vacía su búfer anular cada segundo, lo
/// lleva a 16 kHz, lo escribe en su WAV y anota sus anclas de reloj (spec,
/// «Nunca perder»).
///
/// - Cada segundo: lo que juntó el IOProc pasa al archivo. Matar la app pierde
///   a lo más eso y lo que el búfer no alcanzó a entregar.
/// - Cada 10 s: la cabecera WAV se reescribe con el tamaño real, el archivo se
///   sincroniza y se anota un ancla (muestra, hora del Mac).
/// - Si el disco desaparece, `mudarA` sigue en otra carpeta con la parte
///   siguiente (`yo-2.wav`): la grabación no se corta.
///
/// Todo corre en una cola propia; lo que sale hacia afuera (el estado de la
/// vigía, las anclas, una falla) sale por closures que no esperan a nadie.
final class PistaEnDisco: @unchecked Sendable {
  struct Estado: Sendable, Equatable {
    var vigia: VigiaDeSilencio.Estado = .bien
    /// dBFS del último segundo, para las marcas de la muesca.
    var nivel: Float = -160
    var pareceFaltarPermiso = false
    /// Segundos de audio escritos.
    var segundos: Double = 0
    var yaSono = false
  }

  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")
  /// Cada cuántos segundos van la cabecera, la sincronización y el ancla.
  static let segundosPorCabecera = 10

  let pista: Pista
  let bufer: BuferAnular
  private let cola: DispatchQueue
  private let anotarAncla: @Sendable (AnclaDeReloj) -> Void
  private let alCambiar: @Sendable (Estado) -> Void
  private let alFallar: @Sendable (String) -> Void

  private var carpeta: URL
  private var archivo: FileHandle?
  private(set) var partes: [String] = []
  private var bytesEnLaParte = 0
  private var muestrasEscritas: Int64 = 0
  private let remuestreo = RemuestreoA16k()
  private var vigia: VigiaDeSilencio
  private var temporizador: DispatchSourceTimer?
  private var tics = 0
  private var anclaPendiente = true
  private var fallo = false
  private var perdidasAvisadas = 0

  init(
    pista: Pista,
    carpeta: URL,
    bufer: BuferAnular,
    anotarAncla: @escaping @Sendable (AnclaDeReloj) -> Void,
    alCambiar: @escaping @Sendable (Estado) -> Void,
    alFallar: @escaping @Sendable (String) -> Void
  ) {
    self.pista = pista
    self.carpeta = carpeta
    self.bufer = bufer
    self.anotarAncla = anotarAncla
    self.alCambiar = alCambiar
    self.alFallar = alFallar
    vigia = VigiaDeSilencio(sinBuferesSonCeros: pista == .yo)
    cola = DispatchQueue(label: "cl.espaciodigital.dilo.reuniones.\(pista.rawValue)", qos: .utility)
  }

  /// Crea el WAV de la primera parte —aunque la captura falle después: la
  /// reunión siempre tiene sus archivos— y arranca el segundero.
  func empezar() throws {
    try cola.sync { try abrirParte() }
    let temporizador = DispatchSource.makeTimerSource(queue: cola)
    temporizador.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
    temporizador.setEventHandler { [weak self] in self?.tic() }
    temporizador.resume()
    self.temporizador = temporizador
  }

  /// Sigue en otra carpeta: cierra la parte actual con su cabecera y abre la
  /// siguiente allá. Devuelve el nombre de la parte nueva.
  func mudarA(_ nueva: URL) -> String? {
    cola.sync {
      vaciar()
      cerrarParte()
      carpeta = nueva
      fallo = false
      do {
        try abrirParte()
        return partes.last
      } catch {
        marcarFalla("No pude seguir grabando en \(nueva.path(percentEncoded: false)): \(error.localizedDescription)")
        return nil
      }
    }
  }

  /// Lo último del búfer, la cabecera final y el archivo cerrado. Espera: al
  /// volver, los WAV están completos en disco.
  func terminar() {
    temporizador?.cancel()
    temporizador = nil
    cola.sync {
      vaciar()
      cerrarParte()
    }
  }

  private func abrirParte() throws {
    let nombre = pista.archivo(parte: partes.count + 1)
    let url = carpeta.appending(path: nombre)
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: CabeceraWAV.datos(bytesDeDatos: 0))
    else { throw CocoaError(.fileWriteUnknown) }
    let archivo = try FileHandle(forWritingTo: url)
    try archivo.seekToEnd()
    self.archivo = archivo
    bytesEnLaParte = 0
    partes.append(nombre)
    // La parte nueva empieza con su ancla: la muestra sigue contando desde la
    // primera de la pista, la hora del Mac la dice el primer bloque.
    anclaPendiente = true
  }

  private func cerrarParte() {
    guard let archivo else { return }
    escribirCabecera()
    try? archivo.synchronize()
    try? archivo.close()
    self.archivo = nil
  }

  private func tic() {
    tics += 1
    vaciar()
    if tics % Self.segundosPorCabecera == 0 {
      escribirCabecera()
      try? archivo?.synchronize()
      anclaPendiente = true
    }
    let perdidas = bufer.muestrasPerdidas
    if perdidas > perdidasAvisadas {
      perdidasAvisadas = perdidas
      Self.logger.error("Pista \(self.pista.rawValue, privacy: .public): el búfer perdió \(perdidas) muestras")
    }
  }

  private func vaciar() {
    guard let remuestreo else { return }
    var salida: [Float] = []
    bufer.vaciar { bloque in
      if anclaPendiente, bloque.muestras.count > 0 {
        anclaPendiente = false
        anotarAncla(AnclaDeReloj(pista: pista, muestra: muestrasEscritas + Int64(salida.count), host: bloque.host))
      }
      salida += remuestreo.convertir(bloque.muestras, tasa: bloque.tasa)
    }
    let medida = salida.withUnsafeBufferPointer { VigiaDeSilencio.medir($0) }
    vigia.segundo(muestras: salida.count, todasCero: medida.todasCero, pico: medida.pico)
    if !salida.isEmpty, let archivo, !fallo {
      do {
        try archivo.write(contentsOf: CabeceraWAV.pcm16(salida))
        bytesEnLaParte += salida.count * CabeceraWAV.bytesPorMuestra
        muestrasEscritas += Int64(salida.count)
      } catch {
        marcarFalla("No pude escribir \(pista.rawValue): \(error.localizedDescription)")
      }
    }
    alCambiar(
      Estado(
        vigia: vigia.estado, nivel: vigia.nivel, pareceFaltarPermiso: vigia.pareceFaltarPermiso,
        segundos: Double(muestrasEscritas) / RemuestreoA16k.tasa, yaSono: vigia.yaSono
      )
    )
  }

  private func escribirCabecera() {
    guard let archivo, !fallo else { return }
    do {
      try archivo.seek(toOffset: 0)
      try archivo.write(contentsOf: CabeceraWAV.datos(bytesDeDatos: bytesEnLaParte))
      try archivo.seekToEnd()
    } catch {
      marcarFalla("No pude escribir la cabecera de \(pista.rawValue): \(error.localizedDescription)")
    }
  }

  private func marcarFalla(_ motivo: String) {
    guard !fallo else { return }
    fallo = true
    // La ruta lleva el título de la reunión: va privada.
    Self.logger.error("Pista \(self.pista.rawValue, privacy: .public) dejó de escribir: \(motivo, privacy: .private)")
    alFallar(motivo)
  }
}

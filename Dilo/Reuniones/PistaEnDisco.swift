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
    /// Segundos seguidos en ceros exactos.
    var segundosEnCeros = 0
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
  /// Lo que se acaba de escribir, para el guion en vivo. No espera a nadie.
  private let alOir: @Sendable (TranscripcionEnVivo.Entrega) -> Void

  private var carpeta: URL
  private var archivo: FileHandle?
  private(set) var partes: [String] = []
  private var bytesEnLaParte = 0
  private var muestrasEscritas: Int64 = 0
  private var muestrasOidas: Int64 = 0
  private let remuestreo = RemuestreoA16k()
  /// La tasa de cada bloque del tap, medida: la que dice Core Audio envejece.
  /// El micrófono no la necesita: su formato llega con cada búfer.
  private var tasaMedida: TasaMedida?
  private var vigia: VigiaDeSilencio
  private var temporizador: DispatchSourceTimer?
  private var tics = 0
  private var anclaPendiente = true
  private var fallo = false
  private var perdidasAvisadas = 0
  /// Dónde tendría que empezar el próximo bloque en la hora del Mac. Un
  /// bloque que llega más tarde dejó un hueco: el tap deja de entregar
  /// mientras nada suena, y un motor que se reconstruye calla un momento.
  private var hostEsperado: Double?

  /// Un hueco más largo que esto se rellena con silencio en el WAV.
  static let huecoMinimo: Double = 0.2
  /// Y nunca más que esto de una vez: un reloj que salta no llena el disco.
  static let huecoMaximo: Double = 4 * 3600

  init(
    pista: Pista,
    carpeta: URL,
    bufer: BuferAnular,
    anotarAncla: @escaping @Sendable (AnclaDeReloj) -> Void,
    alCambiar: @escaping @Sendable (Estado) -> Void,
    alFallar: @escaping @Sendable (String) -> Void,
    alOir: @escaping @Sendable (TranscripcionEnVivo.Entrega) -> Void
  ) {
    self.pista = pista
    self.carpeta = carpeta
    self.bufer = bufer
    self.anotarAncla = anotarAncla
    self.alCambiar = alCambiar
    self.alFallar = alFallar
    self.alOir = alOir
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

  /// Lo del búfer al archivo. Un hueco en la entrega se escribe como
  /// silencio, para que el WAV siga el reloj del Mac: si no, las anclas
  /// interpolarían a través del hueco y correrían las palabras de antes. El
  /// relleno no cuenta para la vigía: un Mac callado no es una pista muerta.
  private func vaciar() {
    guard let remuestreo else { return }
    var salida: [Float] = []
    var reales = 0
    var medida = (todasCero: true, pico: Float(-160))
    var hostDeLaSalida: Double?
    bufer.vaciar { bloque in
      guard bloque.muestras.count > 0 else { return }
      let tasa = tasaDe(bloque)
      if let esperado = hostEsperado {
        let hueco = bloque.host - esperado
        if hueco > Self.huecoMinimo {
          salida += [Float](repeating: 0, count: Int(min(hueco, Self.huecoMaximo) * RemuestreoA16k.tasa))
        }
      }
      hostEsperado = bloque.host + Double(bloque.muestras.count) / tasa
      if hostDeLaSalida == nil { hostDeLaSalida = bloque.host - Double(salida.count) / RemuestreoA16k.tasa }
      if anclaPendiente {
        anclaPendiente = false
        anotarAncla(AnclaDeReloj(pista: pista, muestra: muestrasEscritas + Int64(salida.count), host: bloque.host))
      }
      let convertidas = remuestreo.convertir(bloque.muestras, tasa: tasa)
      let m = convertidas.withUnsafeBufferPointer { VigiaDeSilencio.medir($0) }
      medida = (medida.todasCero && m.todasCero, max(medida.pico, m.pico))
      reales += convertidas.count
      salida += convertidas
    }
    vigia.segundo(muestras: reales, todasCero: medida.todasCero, pico: medida.pico)
    if !salida.isEmpty, let archivo, !fallo {
      do {
        try archivo.write(contentsOf: CabeceraWAV.pcm16(salida))
        bytesEnLaParte += salida.count * CabeceraWAV.bytesPorMuestra
        muestrasEscritas += Int64(salida.count)
      } catch {
        marcarFalla("No pude escribir \(pista.rawValue): \(error.localizedDescription)")
      }
    }
    if !salida.isEmpty, let hostDeLaSalida {
      alOir(.init(pista: pista, muestras: salida, muestraInicial: muestrasOidas, host: hostDeLaSalida))
      muestrasOidas += Int64(salida.count)
    }
    alCambiar(
      Estado(
        vigia: vigia.estado, nivel: vigia.nivel, pareceFaltarPermiso: vigia.pareceFaltarPermiso,
        segundos: Double(muestrasEscritas) / RemuestreoA16k.tasa, yaSono: vigia.yaSono,
        segundosEnCeros: vigia.segundosEnCeros
      )
    )
  }

  private func tasaDe(_ bloque: BuferAnular.Bloque) -> Double {
    guard pista == .ellos else { return bloque.tasa }
    var medida = tasaMedida ?? TasaMedida(tasa: bloque.tasa)
    let tasa = medida.bloque(cuadros: bloque.muestras.count, host: bloque.host, declarada: bloque.tasa)
    if tasa != tasaMedida?.tasa, tasa != bloque.tasa {
      Self.logger.notice("La pista ellos llega a \(tasa, privacy: .public) Hz, no a \(bloque.tasa, privacy: .public) Hz")
    }
    tasaMedida = medida
    return tasa
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

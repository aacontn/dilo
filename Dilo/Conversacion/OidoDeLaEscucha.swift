import DiloModes
import Foundation
import os

/// Lo que hace la **escucha de nombres** con el audio, fuera del hilo
/// principal: lo guarda en el búfer que se pisa solo, le pregunta al
/// detector de voz por cada trozo de 256 ms y, cuando la ventana lo pide,
/// transcribe el principio del tramo con el **Motor de voz** y busca un
/// nombre.
///
/// Nada de lo oído sale de acá salvo el llamado: el agente y lo que siguió al
/// nombre, en texto. Ni el audio ni lo transcrito van a un log.
actor OidoDeLaEscucha {
  /// Cómo se pregunta si un trozo tiene voz: 4.096 muestras a 16 kHz, en
  /// orden, y la probabilidad de 0 a 1.
  typealias Detector = @Sendable ([Float]) async throws -> Float
  /// El Motor de voz sobre un tramo ya grabado. Parakeet, prestado del
  /// dictado (`ParakeetEngine.conElModelo`): un solo modelo en la RAM.
  typealias Transcribir = @Sendable ([Float]) async throws -> String

  static let trozo = 4_096
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "escucha")

  private let detector: Detector
  private let reiniciarDetector: @Sendable () async -> Void
  private let transcribir: Transcribir
  private let avisar: @Sendable (NombreQueDespierta.Llamado) -> Void

  private var regla: NombreQueDespierta
  private var bufer = BuferDeEscucha()
  private var ventana = VentanaDeEscucha()
  private var pendiente: [Float] = []
  /// Lo que dio la última búsqueda: su texto y, si lo hubo, el llamado.
  private var ultimaBusqueda: (texto: String, llamado: NombreQueDespierta.Llamado?)?
  /// Cuántas veces se transcribió algo desde que se prendió: para el log,
  /// sin el texto.
  private var busquedas = 0

  init(
    regla: NombreQueDespierta,
    detector: @escaping Detector,
    reiniciarDetector: @escaping @Sendable () async -> Void,
    transcribir: @escaping Transcribir,
    avisar: @escaping @Sendable (NombreQueDespierta.Llamado) -> Void
  ) {
    self.regla = regla
    self.detector = detector
    self.reiniciarDetector = reiniciarDetector
    self.transcribir = transcribir
    self.avisar = avisar
  }

  /// Cambiaron los agentes o sus nombres.
  func cambiarRegla(_ nueva: NombreQueDespierta) {
    regla = nueva
  }

  /// Lo que llega del micrófono, ya a 16 kHz mono, en orden y de a uno: el
  /// detector de voz arrastra estado de un trozo al siguiente, y dos trozos
  /// a la vez lo confundirían. Termina cuando el flujo se cierra.
  func escuchar(_ flujo: AsyncStream<[Float]>) async {
    for await muestras in flujo {
      pendiente += muestras
      while pendiente.count >= Self.trozo {
        let trozo = Array(pendiente.prefix(Self.trozo))
        pendiente.removeFirst(Self.trozo)
        await procesar(trozo)
      }
    }
  }

  /// Se pausó o se apagó: se borra todo lo oído.
  func olvidar() async {
    bufer.vaciar()
    ventana.olvidar()
    pendiente.removeAll()
    ultimaBusqueda = nil
    await reiniciarDetector()
    if busquedas > 0 { Self.logger.info("escucha en pausa tras \(self.busquedas, privacy: .public) búsquedas") }
    busquedas = 0
  }

  private func procesar(_ trozo: [Float]) async {
    let inicio = bufer.escritas
    bufer.agregar(trozo)
    let probabilidad: Float
    do {
      probabilidad = try await detector(trozo)
    } catch {
      Self.logger.error("el detector de voz falló: \(error.localizedDescription, privacy: .public)")
      return
    }
    var accion = ventana.trozo(probabilidad: probabilidad, inicio: inicio, fin: inicio + trozo.count)
    while accion != .nada {
      switch accion {
      case let .buscarNombre(rango):
        let texto = await transcribirSinFallar(rango)
        busquedas += 1
        let llamado = regla.oir(texto)
        ultimaBusqueda = (texto, llamado)
        accion = ventana.resolver(hayNombre: llamado != nil)
      case let .transcribirLlamado(rango):
        let texto = await transcribirSinFallar(rango)
        if let oido = ultimaBusqueda?.llamado { llamar(oido, tramoEntero: texto) }
        accion = .nada
      case .llamarConLoBuscado:
        if let oido = ultimaBusqueda?.llamado { avisarDel(oido) }
        accion = .nada
      case .nada:
        break
      }
    }
  }

  /// El nombre ya se oyó en la búsqueda; el tramo entero trae lo que siguió.
  /// Con más contexto el motor a veces pega el nombre al resto o lo cambia:
  /// el llamado vale igual, y el primer turno es lo mejor que se pueda sacar.
  private func llamar(_ oido: NombreQueDespierta.Llamado, tramoEntero texto: String) {
    let llamado = regla.oir(texto, exigirApartado: false)
      ?? NombreQueDespierta.Llamado(agente: oido.agente, primerTurno: NombreQueDespierta.limpiar(texto) ?? oido.primerTurno)
    avisarDel(llamado)
  }

  private func avisarDel(_ llamado: NombreQueDespierta.Llamado) {
    ultimaBusqueda = nil
    Self.logger.notice("oí un nombre: \(llamado.agente.id, privacy: .public)")
    avisar(llamado)
    // Lo dicho ya es un llamado: no se queda en el búfer.
    bufer.vaciar()
    ventana.olvidar()
  }

  /// Un motor que falla no apaga la escucha: ese tramo no tenía nombre.
  private func transcribirSinFallar(_ rango: Range<Int>) async -> String {
    var audio = bufer.tramo(rango)
    // Parakeet no acepta menos de un segundo: se rellena con silencio.
    if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
    do {
      return try await transcribir(audio)
    } catch {
      Self.logger.error("no pude transcribir lo oído: \(error.localizedDescription, privacy: .public)")
      return ""
    }
  }
}

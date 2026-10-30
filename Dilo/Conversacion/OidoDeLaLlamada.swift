import DiloEngines
import DiloModes
import Foundation
import os

/// El oído de la **Conversación**: un micrófono que queda abierto toda la
/// llamada, en vez de abrirse en cada turno.
///
/// Abrir un micrófono tarda (1,4 s la webcam de Alfonso, medido en el log de
/// `audio`), y lo dicho en ese rato no existía para nadie: contestarle rápido
/// a Dilo era perder las primeras palabras. Además, hablarle encima necesita un
/// micrófono andando mientras él habla. Lo oído vive en un búfer de RAM que se
/// pisa solo (`BuferDeEscucha`) y se borra al colgar o al silenciar: nunca va a
/// disco, a un log ni fuera del Mac. El turno es un tramo de ese búfer, que
/// transcribe Parakeet prestado del dictado.
///
/// Cumple el mismo contrato que el motor del dictado (`motor(desde:)`), así que
/// el controlador no cambia de forma; sin Parakeet o con un Bluetooth como único
/// micrófono, la llamada sigue con el motor de siempre.
actor OidoDeLaLlamada {
  typealias Transcribir = @Sendable ([Float]) async throws -> String

  /// Lo más largo que se le puede hablar en un turno.
  static let segundosEnLaRAM = 120.0
  static let tasa = 16_000
  /// Cada cuánta voz nueva se transcribe lo que va del turno: 0,6 s. Es lo que
  /// dice la barra, y dice si la frase quedó abierta.
  static let muestrasEntreParciales = 9_600

  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "conversacion")

  /// El turno que se está oyendo.
  private struct Turno {
    let id: Int
    let inicio: Int
    let handlers: EngineHandlers
    /// Dónde terminó la última voz.
    var finDeLaVoz: Int?
    /// Hasta dónde llega lo último que se mandó a transcribir.
    var pedidoHasta: Int
    /// Lo último transcrito y hasta dónde llega.
    var transcrito: (fin: Int, texto: String)?
  }

  private let transcribir: Transcribir
  private let alOir: @Sendable (_ nivel: Float, _ indice: Int) -> Void
  private var bufer = BuferDeEscucha(segundos: segundosEnLaRAM)
  private var turno: Turno?
  private var turnos = 0
  private var parcial: Task<Void, Never>?

  init(
    transcribir: @escaping Transcribir,
    alOir: @escaping @Sendable (_ nivel: Float, _ indice: Int) -> Void
  ) {
    self.transcribir = transcribir
    self.alOir = alOir
  }

  /// Lo que llega del micrófono, en orden. Termina cuando el flujo se cierra.
  func escuchar(_ flujo: AsyncStream<[Float]>) async {
    for await muestras in flujo { oir(muestras) }
  }

  /// El contrato del motor de voz para un turno, que empieza en `desde` (donde
  /// empezó la voz que interrumpió) o en este instante.
  nonisolated func motor(desde: Int?) -> MotorParaConversar {
    MotorParaConversar(
      empezar: { [self] _, _, handlers in await empezar(desde: desde, handlers) },
      terminar: { [self] in await terminar() },
      cancelar: { [self] in await cancelar() },
      locale: { Locale(identifier: $0) }
    )
  }

  /// Se colgó o se silenció: se borra todo lo oído.
  func olvidar() {
    parcial?.cancel()
    parcial = nil
    turno = nil
    bufer.vaciar()
  }

  private func empezar(desde: Int?, _ handlers: EngineHandlers) {
    turnos += 1
    let inicio = desde.map { max($0, bufer.desde) } ?? bufer.escritas
    turno = Turno(id: turnos, inicio: inicio, handlers: handlers, pedidoHasta: inicio)
  }

  private func cancelar() {
    turno = nil
  }

  private func terminar() async -> String {
    await parcial?.value
    guard let turno else { return "" }
    self.turno = nil
    // Lo último transcrito ya tiene toda la voz: lo que siguió fue silencio,
    // y transcribir otra vez sería hacer esperar a la persona por nada.
    if let transcrito = turno.transcrito, let fin = turno.finDeLaVoz, transcrito.fin >= fin {
      return transcrito.texto
    }
    return await texto(de: turno.inicio ..< bufer.escritas)
  }

  private func oir(_ muestras: [Float]) {
    guard !muestras.isEmpty else { return }
    let nivel = Self.nivel(de: muestras)
    let indice = bufer.escritas
    bufer.agregar(muestras)
    alOir(nivel, indice)
    guard var turno else { return }
    turno.handlers.nivel(nivel)
    let hayVoz = nivel >= FinDelTurno.nivelDeVoz
    if hayVoz { turno.finDeLaVoz = bufer.escritas }
    self.turno = turno
    transcribirLoQueVa(recienCallo: !hayVoz)
  }

  /// Transcribe lo que va del turno si hay voz nueva: cada tanto mientras se
  /// habla, y apenas se calla. Lo que se pide al callar suele ser ya el texto
  /// final.
  private func transcribirLoQueVa(recienCallo: Bool) {
    guard parcial == nil, let turno, let fin = turno.finDeLaVoz else { return }
    let nuevas = bufer.escritas - turno.pedidoHasta
    guard nuevas >= Self.muestrasEntreParciales || (recienCallo && fin > turno.pedidoHasta) else { return }
    let hasta = bufer.escritas
    let id = turno.id
    let rango = turno.inicio ..< hasta
    self.turno?.pedidoHasta = hasta
    parcial = Task {
      let texto = await texto(de: rango)
      llego(texto, hasta: hasta, turno: id)
    }
  }

  private func llego(_ texto: String, hasta: Int, turno id: Int) {
    parcial = nil
    guard var turno, turno.id == id else { return }
    turno.transcrito = (hasta, texto)
    self.turno = turno
    turno.handlers.parcial(EngineUpdate(finalizado: "", volatil: texto))
  }

  private func texto(de rango: Range<Int>) async -> String {
    var audio = bufer.tramo(rango)
    guard !audio.isEmpty else { return "" }
    // Parakeet no acepta menos de un segundo: se rellena con silencio.
    if audio.count < Self.tasa { audio += [Float](repeating: 0, count: Self.tasa - audio.count) }
    do {
      return try await transcribir(audio)
    } catch {
      Self.logger.error("no pude transcribir el turno: \(error.localizedDescription, privacy: .public)")
      return ""
    }
  }

  /// La escala de la muesca: 0 a 1 sobre 50 dB, como `MicrophoneInput`.
  static func nivel(de muestras: [Float]) -> Float {
    let suma = muestras.reduce(Float(0)) { $0 + $1 * $1 }
    let rms = (suma / Float(max(muestras.count, 1))).squareRoot()
    let db = 20 * log10(max(rms, .leastNormalMagnitude))
    return min(1, max(0, (db + 50) / 50))
  }
}

/// El micrófono abierto de una llamada y quien lo escucha.
@MainActor
struct OidoAbierto {
  let oido: OidoDeLaLlamada
  private let microfono: MicrofonoDeLaEscucha
  private let flujo: AsyncStream<[Float]>.Continuation
  private let tarea: Task<Void, Never>

  /// Abre el micrófono de la llamada, o nil si esta llamada tiene que seguir
  /// con el motor de siempre: no hay Parakeet, o sólo hay un Bluetooth que
  /// abierto toda la llamada dejaría los audífonos en el perfil de llamada.
  static func abrir(
    eleccion: EleccionDeMicrofono,
    transcribir: @escaping OidoDeLaLlamada.Transcribir,
    alFallar: @escaping @Sendable (String) -> Void,
    alOir: @escaping @Sendable (_ nivel: Float, _ indice: Int) -> Void
  ) async -> OidoAbierto? {
    let plan = await Task.detached(priority: .userInitiated) {
      PlanDeMicrofono.paraLaEscucha(
        eleccion: eleccion,
        entradas: DispositivosDeAudio.entradas(),
        entradaDelSistema: DispositivosDeAudio.entradaDelSistema(),
        tapaCerrada: Tapa.estaCerrada
      )
    }.value
    guard let plan else { return nil }
    let (flujo, continuacion) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(64))
    let oido = OidoDeLaLlamada(transcribir: transcribir, alOir: alOir)
    let microfono = MicrofonoDeLaEscucha { continuacion.yield($0) }
    microfono.alFallar = alFallar
    let entrada = plan.fijarA
    let abrio = await Task.detached(priority: .userInitiated) { () -> Bool in
      do {
        try microfono.empezar(entrada: entrada)
        return true
      } catch {
        return false
      }
    }.value
    guard abrio else {
      continuacion.finish()
      return nil
    }
    let tarea = Task.detached(priority: .userInitiated) { await oido.escuchar(flujo) }
    return OidoAbierto(oido: oido, microfono: microfono, flujo: continuacion, tarea: tarea)
  }

  /// Cierra el micrófono y borra lo oído.
  func cerrar() {
    microfono.detener()
    flujo.finish()
    let oido = oido
    let tarea = tarea
    Task.detached(priority: .userInitiated) {
      await tarea.value
      await oido.olvidar()
    }
  }
}

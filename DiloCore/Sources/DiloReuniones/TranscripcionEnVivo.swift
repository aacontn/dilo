import Foundation

/// El modelo de voz no está: no tiene sentido seguir pidiéndole nada.
public enum FallaDelVivo: Error, Sendable {
  case sinMotor
}

/// El guion en vivo: lo que cada **Pista** va diciendo, con el Motor de voz del
/// dictado y en el Mac. Recibe el audio que `PistaEnDisco` ya escribió, sin
/// tocar la grabación: si esto falla, la reunión sigue igual y la pasada final
/// deja el guion de siempre.
///
/// - **El audio vive en RAM** sólo mientras un tramo está abierto, y lo dicho
///   sale por `alCambiar`: nada de esto va a disco ni a un log.
/// - **Una transcripción a la vez**: lo firme antes que lo parcial, y un
///   parcial nuevo reemplaza al que no alcanzó a correr.
/// - **Un dictado manda.** Mientras dura no se le pide nada al modelo: soltar →
///   texto tiene que seguir bajo los 300 ms. Lo de `ellos` se junta y sale al
///   terminar; lo de `yo` en ese rato no es la reunión.
public actor TranscripcionEnVivo {
  public typealias Transcribir = @Sendable ([Float]) async throws -> String
  /// La probabilidad de voz de un trozo, con el estado de esa pista.
  public typealias Detectar = @Sendable (Pista, [Float]) async throws -> Float

  /// Audio de una pista a 16 kHz, tal como se escribió.
  public struct Entrega: Sendable {
    public var pista: Pista
    public var muestras: [Float]
    /// La muestra de la pista donde empieza la entrega.
    public var muestraInicial: Int64
    /// La hora del Mac de la primera muestra.
    public var host: Double

    public init(pista: Pista, muestras: [Float], muestraInicial: Int64, host: Double) {
      self.pista = pista
      self.muestras = muestras
      self.muestraInicial = muestraInicial
      self.host = host
    }
  }

  private final class Oido {
    var tramos: TramosDeVoz
    var audio: [Float] = []
    /// La muestra de `audio[0]`.
    var base = 0
    /// Hasta dónde se le pasó al detector.
    var leido = 0
    /// Cuánto después del inicio de la reunión empezó la pista.
    var desfase: Double?
    /// La línea del tramo abierto.
    var linea: Int?

    init(_ ajustes: TramosDeVoz.Ajustes) { tramos = TramosDeVoz(ajustes: ajustes) }
  }

  private struct Pedido: Sendable {
    var linea: Int
    var pista: Pista
    var desde: Double
    var hasta: Double
    var audio: [Float]
    var abierta: Bool
  }

  private let inicioHost: Double
  private let transcribir: Transcribir
  private let detectar: Detectar
  private let alCambiar: @Sendable (NovedadEnVivo) -> Void
  private let ajustes: TramosDeVoz.Ajustes
  private let flujo: AsyncStream<Entrega>
  private let continuacion: AsyncStream<Entrega>.Continuation
  private var oidos: [Pista: Oido]
  private var lineas = 0
  private var pendientes: [Pedido] = []
  private var trabajando = false
  private var dictando = false
  private var terminada = false
  private var sinMotor = false
  private var sinDetector = false

  public init(
    inicioHost: Double,
    ajustes: TramosDeVoz.Ajustes = TramosDeVoz.Ajustes(),
    transcribir: @escaping Transcribir,
    detectar: @escaping Detectar,
    alCambiar: @escaping @Sendable (NovedadEnVivo) -> Void
  ) {
    self.inicioHost = inicioHost
    self.ajustes = ajustes
    self.transcribir = transcribir
    self.detectar = detectar
    self.alCambiar = alCambiar
    oidos = [.yo: Oido(ajustes), .ellos: Oido(ajustes)]
    // Un minuto de audio de las dos pistas: el detector tarda milisegundos por
    // trozo, así que sólo se junta si el Mac se atoró.
    (flujo, continuacion) = AsyncStream.makeStream(of: Entrega.self, bufferingPolicy: .bufferingNewest(120))
  }

  /// Desde la cola que escribe cada pista: nunca espera.
  public nonisolated func recibir(_ entrega: Entrega) {
    continuacion.yield(entrega)
  }

  /// Atiende lo que llega hasta que la reunión termina.
  public func escuchar() async {
    for await entrega in flujo { await oir(entrega) }
  }

  public func dictado(enCurso: Bool) {
    dictando = enCurso
    guard enCurso else {
      despertar()
      return
    }
    // Lo que venías diciendo queda; lo que sigue es un dictado.
    pendientes.removeAll(where: \.abierta)
    if let oido = oidos[.yo], let accion = oido.tramos.cerrarAhora(fin: oido.leido) {
      atender(accion, oido, pista: .yo)
    }
  }

  /// La reunión terminó: desde aquí manda la pasada final, y lo que quedó
  /// abierto se ve firme.
  public func terminar() {
    guard !terminada else { return }
    terminada = true
    continuacion.finish()
    pendientes = []
    for oido in oidos.values {
      if let linea = oido.linea { alCambiar(.cerrar(id: linea)) }
      oido.linea = nil
      oido.audio = []
    }
  }

  private func oir(_ entrega: Entrega) async {
    guard !terminada, !sinMotor, let oido = oidos[entrega.pista], !entrega.muestras.isEmpty else { return }
    let inicial = Int(entrega.muestraInicial)
    if oido.desfase == nil {
      oido.desfase = entrega.host - inicioHost - entrega.muestraInicial.segundos(ajustes.tasa)
      oido.base = inicial
      oido.leido = inicial
    }
    if inicial > oido.base + oido.audio.count {
      // Se perdieron entregas: lo que viene no sigue a lo abierto.
      if let accion = oido.tramos.cerrarAhora(fin: oido.leido) { atender(accion, oido, pista: entrega.pista) }
      oido.audio = []
      oido.base = inicial
      oido.leido = inicial
    }
    oido.audio += entrega.muestras
    while oido.leido + ajustes.muestrasPorTrozo <= oido.base + oido.audio.count {
      let desde = oido.leido - oido.base
      let trozo = Array(oido.audio[desde ..< desde + ajustes.muestrasPorTrozo])
      oido.leido += ajustes.muestrasPorTrozo
      let probabilidad = await self.probabilidad(trozo, pista: entrega.pista)
      guard !terminada else { return }
      for accion in oido.tramos.trozo(fin: oido.leido, probabilidad: probabilidad) {
        atender(accion, oido, pista: entrega.pista)
      }
    }
    recortar(oido)
  }

  private func probabilidad(_ trozo: [Float], pista: Pista) async -> Float {
    if pista == .yo, dictando { return 0 }
    // El relleno de los huecos del tap: no vale una pasada por el modelo.
    if trozo.allSatisfy({ $0 == 0 }) { return 0 }
    if !sinDetector {
      do {
        return try await detectar(pista, trozo)
      } catch {
        sinDetector = true
      }
    }
    return TramosDeVoz.probabilidadPorNivel(trozo)
  }

  /// Una vez por entrega, no por trozo: un hueco largo del tap llega como
  /// horas de ceros en una sola, y correr el arreglo en cada trozo sería
  /// cuadrático.
  private func recortar(_ oido: Oido) {
    let desde = oido.tramos.retenerDesde(fin: oido.leido) - oido.base
    guard desde > 0 else { return }
    oido.audio.removeFirst(min(desde, oido.audio.count))
    oido.base += desde
  }

  private func atender(_ accion: TramosDeVoz.Accion, _ oido: Oido, pista: Pista) {
    switch accion {
    case let .parcial(rango):
      guard !dictando else { return }
      encolar(rango, oido, pista: pista, abierta: true)
    case let .cerrar(rango):
      encolar(rango, oido, pista: pista, abierta: false)
      oido.linea = nil
    case .descartar:
      if let linea = oido.linea {
        pendientes.removeAll { $0.linea == linea }
        alCambiar(.quitar(id: linea))
      }
      oido.linea = nil
    }
  }

  private func encolar(_ rango: Range<Int>, _ oido: Oido, pista: Pista, abierta: Bool) {
    let linea = oido.linea ?? nuevaLinea(oido)
    let desde = max(rango.lowerBound - oido.base, 0)
    let hasta = min(rango.upperBound - oido.base, oido.audio.count)
    guard desde < hasta else { return }
    let desfase = oido.desfase ?? 0
    pendientes.removeAll { $0.linea == linea }
    pendientes.append(
      Pedido(
        linea: linea, pista: pista,
        desde: desfase + Int64(rango.lowerBound).segundos(ajustes.tasa),
        hasta: desfase + Int64(rango.upperBound).segundos(ajustes.tasa),
        audio: Array(oido.audio[desde ..< hasta]), abierta: abierta
      )
    )
    despertar()
  }

  private func nuevaLinea(_ oido: Oido) -> Int {
    lineas += 1
    oido.linea = lineas
    return lineas
  }

  private func despertar() {
    guard !trabajando, !dictando, !terminada, !sinMotor, !pendientes.isEmpty else { return }
    trabajando = true
    Task { await trabajar() }
  }

  private func trabajar() async {
    while !dictando, !terminada, !sinMotor, let pedido = siguiente() {
      do {
        let texto = try await transcribir(Self.conRelleno(pedido.audio, tasa: Int(ajustes.tasa)))
        publicar(texto, de: pedido)
      } catch FallaDelVivo.sinMotor {
        sinMotor = true
        pendientes = []
        alCambiar(.sinMotor)
      } catch {
        // Un tramo que no salió no para la reunión: la pasada final lo tiene,
        // y lo que ya se veía de él se queda.
        if !pedido.abierta { alCambiar(.cerrar(id: pedido.linea)) }
      }
    }
    trabajando = false
    despertar()
  }

  private func siguiente() -> Pedido? {
    guard let indice = pendientes.firstIndex(where: { !$0.abierta }) ?? pendientes.indices.first else { return nil }
    return pendientes.remove(at: indice)
  }

  private func publicar(_ texto: String, de pedido: Pedido) {
    guard !terminada else { return }
    let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpio.isEmpty else {
      if !pedido.abierta { alCambiar(.quitar(id: pedido.linea)) }
      return
    }
    alCambiar(
      .linea(
        LineaEnVivo(
          id: pedido.linea, pista: pedido.pista, desde: pedido.desde, hasta: pedido.hasta, texto: limpio,
          abierta: pedido.abierta
        )
      )
    )
  }

  /// Parakeet no acepta menos de un segundo: se rellena con silencio.
  private static func conRelleno(_ audio: [Float], tasa: Int) -> [Float] {
    audio.count < tasa ? audio + [Float](repeating: 0, count: tasa - audio.count) : audio
  }
}

extension Int64 {
  fileprivate func segundos(_ tasa: Double) -> Double { Double(self) / tasa }
}

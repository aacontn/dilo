import DiloModes
import DiloText
import Foundation
import Observation
import os

/// Ordena Tus palabras y «Cuando digo…» con Claude (Sonnet 5.5 de fábrica),
/// en segundo plano, y lleva el registro de lo que cambió con su deshacer.
///
/// **Cuándo** lo decide `CuandoOrdenar`, puro: diez entradas aprendidas desde
/// la última vez, o una semana, o nunca ordenado; nunca con el mismo
/// diccionario que la última vez, y nunca dos intentos en menos de seis
/// horas. Se mira a los dos minutos de arrancar, cada seis horas mientras
/// Dilo está abierto, y después de aprender algo en la muesca. **Nunca
/// empieza durante un dictado**: si toca en medio de uno, espera un minuto y
/// vuelve a mirar. Una sesión congela sus ajustes al empezar (ADR-0004), así
/// que lo que se aplique mientras alguien dicta vale para el dictado que
/// sigue.
///
/// **Qué aplica**: lo seguro (`OrdenDelDiccionario`); lo demás queda
/// propuesto en Ajustes. Todo lo aplicado tiene deshacer, y lo deshecho no
/// se vuelve a proponer.
@MainActor
@Observable
final class OrdenadorDelDiccionario {
  enum Estado: Equatable {
    case quieto
    case ordenando
    /// La última pasada: cuántos cambios aplicó y cuántos dejó propuestos.
    case listo(aplicados: Int, propuestos: Int)
    /// Una falla, ya dicha para la persona.
    case fallo(String)
  }

  private(set) var estado: Estado = .quieto

  @ObservationIgnored private let settings: AppSettings
  /// Si hay un dictado en curso. Lo cablea `AppDelegate`.
  @ObservationIgnored var hayDictadoEnCurso: () -> Bool = { false }
  @ObservationIgnored var hayClave: () -> Bool = { AprendizajeConClaude.hayClave() }
  /// El viaje a Claude. Un test pone el suyo.
  @ObservationIgnored var pedir: @Sendable (Diccionario, String) async throws -> String = {
    try await AprendizajeConClaude.pedirOrden($0, modelo: $1)
  }
  @ObservationIgnored var ahora: () -> Date = { Date() }

  static let primeraMirada = Duration.seconds(120)
  static let cadaCuantoSeMira = Duration.seconds(6 * 3600)
  static let esperaSiSeEstaDictando = Duration.seconds(60)

  @ObservationIgnored private var reloj: Task<Void, Never>?
  @ObservationIgnored private var tarea: Task<Void, Never>?

  init(settings: AppSettings) {
    self.settings = settings
  }

  /// Empieza a mirar solo. Lo llama `AppDelegate` al arrancar.
  func empezar() {
    reloj?.cancel()
    reloj = Task { [weak self] in
      try? await Task.sleep(for: Self.primeraMirada)
      while !Task.isCancelled {
        self?.revisarSiToca()
        try? await Task.sleep(for: Self.cadaCuantoSeMira)
      }
    }
  }

  /// Ordena si toca. No hace nada sin el interruptor, sin clave o con una
  /// pasada en curso.
  func revisarSiToca() {
    guard settings.aprenderConClaude, tarea == nil else { return }
    guard CuandoOrdenar.toca(
      ahora: ahora(), ultimaPasada: settings.ultimaPasadaDelOrden,
      ultimoIntento: settings.ultimoIntentoDelOrden,
      aprendidasDesde: settings.aprendidasDesdeElOrden,
      diccionario: settings.diccionario, firmaDeLaUltima: settings.firmaDelOrden
    ), hayClave() else { return }
    if hayDictadoEnCurso() {
      tarea = Task { [weak self] in
        try? await Task.sleep(for: Self.esperaSiSeEstaDictando)
        guard !Task.isCancelled, let self else { return }
        tarea = nil
        revisarSiToca()
      }
      return
    }
    correr()
  }

  /// «Ordenar ahora», en Ajustes: sin mirar el calendario, pero tampoco
  /// sobre una pasada en curso ni a mitad de un dictado.
  func ordenarAhora() {
    guard tarea == nil, !hayDictadoEnCurso() else { return }
    guard hayClave() else {
      estado = .fallo(FallaDeClaude.faltaLaClave.avisoDelOrden)
      return
    }
    guard settings.diccionario.entradas > 0 else {
      estado = .listo(aplicados: 0, propuestos: 0)
      return
    }
    correr()
  }

  var ordenando: Bool { estado == .ordenando }

  private func correr() {
    let enviado = settings.diccionario
    let modelo = settings.modeloParaOrdenar
    let pedir = pedir
    settings.ultimoIntentoDelOrden = ahora()
    estado = .ordenando
    AppLog.aprendizaje.notice("Ordenar: \(enviado.entradas, privacy: .public) entradas")
    tarea = Task { [weak self] in
      let resultado: Result<String, Error>
      do {
        resultado = .success(try await pedir(enviado, modelo))
      } catch {
        resultado = .failure(error)
      }
      guard let self else { return }
      tarea = nil
      terminar(resultado, enviado: enviado, modelo: modelo)
    }
  }

  private func terminar(_ resultado: Result<String, Error>, enviado: Diccionario, modelo: String) {
    let respuesta: String
    switch resultado {
    case let .success(texto): respuesta = texto
    case let .failure(falla as FallaDeClaude):
      AppLog.aprendizaje.notice("Ordenar falló: \(falla.nombreEnElLog, privacy: .public)")
      estado = .fallo(falla.avisoDelOrden)
      return
    case .failure:
      estado = .fallo(FallaDeClaude.respuestaInutil.avisoDelOrden)
      return
    }
    var actual = settings.diccionario
    let yaVistos = Set(settings.registroDelOrden.flatMap(\.cambios).map(\.cambio))
    guard let pasada = OrdenDelDiccionario.ordenar(
      &actual, enviado: enviado, respuesta: respuesta, modelo: modelo, fecha: ahora(), yaVistos: yaVistos
    ) else {
      AppLog.aprendizaje.notice("Ordenar: respuesta ilegible")
      estado = .fallo(FallaDeClaude.respuestaInutil.avisoDelOrden)
      return
    }
    settings.diccionario = actual
    settings.ultimaPasadaDelOrden = pasada.fecha
    settings.firmaDelOrden = actual.firma
    settings.aprendidasDesdeElOrden = 0
    if !pasada.cambios.isEmpty {
      settings.registroDelOrden = Array(([pasada] + settings.registroDelOrden).prefix(AppSettings.pasadasEnElRegistro))
    }
    let aplicados = pasada.cambios.filter { $0.estado == .aplicado }.count
    AppLog.aprendizaje.notice(
      "Ordenar: \(aplicados, privacy: .public) aplicados, \(pasada.cambios.count - aplicados, privacy: .public) propuestos, \(pasada.descartados, privacy: .public) descartados"
    )
    estado = .listo(aplicados: aplicados, propuestos: pasada.cambios.count - aplicados)
  }

  /// Deshace un cambio aplicado, o aplica uno propuesto o deshecho.
  func alternar(_ cambio: CambioDelOrden.ID, en pasada: PasadaDelOrden.ID) {
    guard let p = settings.registroDelOrden.firstIndex(where: { $0.id == pasada }),
      let c = settings.registroDelOrden[p].cambios.firstIndex(where: { $0.id == cambio })
    else { return }
    var registro = settings.registroDelOrden
    var diccionario = settings.diccionario
    switch registro[p].cambios[c].estado {
    case .aplicado:
      diccionario.deshacer(registro[p].cambios[c].cambio)
      registro[p].cambios[c].estado = .deshecho
    case .propuesto, .deshecho:
      diccionario.aplicar(registro[p].cambios[c].cambio)
      registro[p].cambios[c].estado = .aplicado
    }
    settings.diccionario = diccionario
    settings.registroDelOrden = registro
    // Lo que la persona decidió a mano no es motivo para volver a ordenar.
    settings.firmaDelOrden = diccionario.firma
  }

  func detener() {
    reloj?.cancel()
    tarea?.cancel()
    reloj = nil
    tarea = nil
  }
}

extension FallaDeClaude {
  /// Lo que dice Ajustes cuando ordenar no pudo. Una línea.
  var avisoDelOrden: String {
    switch self {
    case .faltaLaClave: String(localized: "Falta la clave de Anthropic")
    case .claveRechazada: String(localized: "Anthropic no aceptó la clave")
    case .demasiadosPedidos: String(localized: "Anthropic pidió esperar")
    case .anthropicNoResponde: String(localized: "Anthropic no está respondiendo")
    case .pedidoRechazado: String(localized: "Anthropic rechazó el pedido")
    case .sinConexion: String(localized: "Sin conexión con Anthropic")
    case .tardoDemasiado: String(localized: "Claude tardó demasiado")
    case .seNego: String(localized: "Claude no quiso ordenar esto")
    case .cortada: String(localized: "El diccionario es muy largo para una pasada")
    case .respuestaInutil: String(localized: "Claude no devolvió algo que se pueda usar")
    }
  }
}

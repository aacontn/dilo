import AppKit
import EventKit

/// La próxima reunión del calendario, para el panel del hover.
///
/// Pedido del 2026-09-24 (el 3 de la lista): «Reunión en 5 min», como Boring
/// Notch y NotchNook, y además la puerta del notetaker que viene. Corre sólo
/// si se encendió en Ajustes y macOS dio permiso: refresca cada minuto —el
/// «en 12 min» tiene que avanzar— y cuando el calendario avisa que cambió.
@MainActor
final class LectorDelCalendario {
  var alCambiar: ((ProximaReunion?) -> Void)?

  private let almacen = EKEventStore()
  private var tarea: Task<Void, Never>?
  private var observador: (any NSObjectProtocol)?

  /// Cuánto hacia adelante se mira. Más allá de esto no es «la próxima
  /// reunión», es la agenda.
  static let horizonte: TimeInterval = 12 * 3600
  /// Una reunión que empezó hace menos que esto todavía cuenta como «ahora».
  static let yaEmpezada: TimeInterval = 10 * 60

  static var tienePermiso: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
  }

  static var permisoNegado: Bool {
    let estado = EKEventStore.authorizationStatus(for: .event)
    return estado == .denied || estado == .restricted
  }

  /// Pide permiso para leer el calendario. Lo llama Ajustes al encender la
  /// sección, que es cuando alguien lo pidió.
  func pedirPermiso() async -> Bool {
    (try? await almacen.requestFullAccessToEvents()) ?? false
  }

  func encender(_ encendido: Bool) {
    tarea?.cancel()
    tarea = nil
    if let observador { NotificationCenter.default.removeObserver(observador) }
    observador = nil
    guard encendido, Self.tienePermiso else {
      alCambiar?(nil)
      return
    }
    observador = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: almacen, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.leer() }
    }
    tarea = Task { [weak self] in
      while !Task.isCancelled {
        self?.leer()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  func leer(ahora: Date = Date()) {
    let predicado = almacen.predicateForEvents(
      withStart: ahora.addingTimeInterval(-Self.yaEmpezada),
      end: ahora.addingTimeInterval(Self.horizonte),
      calendars: nil
    )
    let eventos = almacen.events(matching: predicado)
    alCambiar?(Self.proxima(de: eventos.map(Self.evento), ahora: ahora))
  }

  /// Lo que se necesita de un evento, sin EventKit: para elegir la próxima
  /// en un test sin permisos de calendario.
  struct Evento: Equatable {
    let titulo: String
    let empieza: Date
    let termina: Date
    let todoElDia: Bool
    let cancelado: Bool
    let textos: [String]
    let url: URL?
  }

  static func evento(_ e: EKEvent) -> Evento {
    Evento(
      titulo: e.title ?? "",
      empieza: e.startDate,
      termina: e.endDate,
      todoElDia: e.isAllDay,
      cancelado: e.status == .canceled,
      textos: [e.location, e.notes].compactMap { $0 },
      url: e.url
    )
  }

  /// La primera que no terminó: la que está por empezar, o la que empezó
  /// hace poco. Los eventos de todo el día no son reuniones.
  static func proxima(de eventos: [Evento], ahora: Date) -> ProximaReunion? {
    eventos
      .filter { !$0.todoElDia && !$0.cancelado && $0.termina > ahora }
      .filter { $0.empieza >= ahora.addingTimeInterval(-yaEmpezada) }
      .sorted { $0.empieza < $1.empieza }
      .first
      .map {
        ProximaReunion(
          titulo: $0.titulo.isEmpty ? String(localized: "Reunión") : $0.titulo,
          empieza: $0.empieza,
          termina: $0.termina,
          enlace: enlaceDeVideollamada(url: $0.url, textos: $0.textos)
        )
      }
  }

  /// El enlace de la videollamada: el del evento si es de una, o el primero
  /// que aparezca en el lugar o las notas.
  static func enlaceDeVideollamada(url: URL?, textos: [String]) -> URL? {
    if let url, esVideollamada(url) { return url }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    for texto in textos {
      let rango = NSRange(texto.startIndex..., in: texto)
      for resultado in detector?.matches(in: texto, range: rango) ?? [] {
        if let enlace = resultado.url, esVideollamada(enlace) { return enlace }
      }
    }
    return nil
  }

  static let dominiosDeVideollamada = [
    "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
    "whereby.com", "around.co",
  ]

  static func esVideollamada(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    return dominiosDeVideollamada.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  /// Abre la videollamada si hay enlace; si no, Calendario.
  static func abrir(_ reunion: ProximaReunion?) {
    if let enlace = reunion?.enlace {
      NSWorkspace.shared.open(enlace)
      return
    }
    guard let calendario = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
    else { return }
    NSWorkspace.shared.openApplication(at: calendario, configuration: .init())
  }
}

import DiloReuniones
import EventKit
import Foundation

/// La reunión del calendario que está pasando ahora, con sus asistentes, para
/// el título y los nombres del guion (spec, «Nombres»: en 1:1, «Yo / Camila»
/// gratis). Sólo lee si el permiso ya está dado: grabar nunca pide permiso de
/// calendario por su cuenta.
enum EventoActualDelCalendario {
  /// Una reunión que empezó hace poco o empieza pronto sigue contando.
  static let margen: TimeInterval = 10 * 60

  static func leer(ahora: Date = Date()) -> EventoDeLaReunion? {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
    let almacen = EKEventStore()
    let predicado = almacen.predicateForEvents(
      withStart: ahora.addingTimeInterval(-margen), end: ahora.addingTimeInterval(margen), calendars: nil
    )
    let candidatos = almacen.events(matching: predicado).filter { !$0.isAllDay && $0.status != .canceled }
    guard let evento = candidatos.min(by: {
      abs($0.startDate.timeIntervalSince(ahora)) < abs($1.startDate.timeIntervalSince(ahora))
    }) else { return nil }
    return EventoDeLaReunion(
      titulo: evento.title ?? String(localized: "Reunión"),
      empieza: evento.startDate,
      termina: evento.endDate,
      asistentes: asistentes(de: evento)
    )
  }

  /// Los otros asistentes por nombre: sin quien graba, sin salas ni recursos.
  static func asistentes(de evento: EKEvent) -> [String] {
    (evento.attendees ?? [])
      .filter { !$0.isCurrentUser && $0.participantType == .person }
      .compactMap { participante in
        let nombre = participante.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nombre.isEmpty ? nil : nombre
      }
  }
}

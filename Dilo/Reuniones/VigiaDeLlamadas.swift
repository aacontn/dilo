import CoreAudio
import DiloReuniones
import Foundation

/// Qué apps de llamadas tienen el micrófono abierto, sin sondeo: Core Audio
/// avisa al cambiar la lista de procesos y al abrir o cerrar la entrada cada
/// uno. No abre el micrófono ni pide un permiso, y entre avisos no cuesta nada.
///
/// `@unchecked Sendable`: todo su estado vive en `cola`.
final class VigiaDeLlamadas: @unchecked Sendable {
  private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.llamadas", qos: .utility)
  private let alCambiar: @Sendable (Set<AppDeLlamada>) -> Void
  private var oyente: AudioObjectPropertyListenerBlock?
  private var mirados: Set<AudioObjectID> = []
  private var ultimas: Set<AppDeLlamada> = []

  init(alCambiar: @escaping @Sendable (Set<AppDeLlamada>) -> Void) {
    self.alCambiar = alCambiar
  }

  func empezar() {
    cola.async { [self] in
      let oyente: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.revisar() }
      self.oyente = oyente
      var lista = HALDeReuniones.direccion(kAudioHardwarePropertyProcessObjectList)
      AudioObjectAddPropertyListenerBlock(HALDeReuniones.sistema, &lista, cola, oyente)
      revisar()
    }
  }

  func detener() {
    cola.async { [self] in
      guard let oyente else { return }
      var lista = HALDeReuniones.direccion(kAudioHardwarePropertyProcessObjectList)
      AudioObjectRemovePropertyListenerBlock(HALDeReuniones.sistema, &lista, cola, oyente)
      mirar(procesos: [])
      self.oyente = nil
    }
  }

  private func revisar() {
    let procesos = HALDeReuniones.procesos
    mirar(procesos: Set(procesos))
    let activas = Set(
      procesos
        .filter(HALDeReuniones.abreElMicrofono)
        .compactMap { HALDeReuniones.paquete(de: $0).flatMap(AppsDeLlamadas.app(dePaquete:)) }
    )
    guard activas != ultimas else { return }
    ultimas = activas
    alCambiar(activas)
  }

  /// Deja un oyente en cada proceso que llegó y suelta los que se fueron.
  private func mirar(procesos: Set<AudioObjectID>) {
    guard let oyente else { return }
    var entrada = HALDeReuniones.direccion(kAudioProcessPropertyIsRunningInput)
    for nuevo in procesos.subtracting(mirados) {
      AudioObjectAddPropertyListenerBlock(nuevo, &entrada, cola, oyente)
    }
    for ido in mirados.subtracting(procesos) {
      AudioObjectRemovePropertyListenerBlock(ido, &entrada, cola, oyente)
    }
    mirados = procesos
  }
}

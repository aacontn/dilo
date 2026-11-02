import CoreAudio
import DiloEngines
import Foundation
import os

/// Calla las apps que suenan mientras dura un dictado y las suelta al
/// terminar. Qué se calla lo decide `SilencioAlDictar` (puro, con tests).
///
/// Es un tap de Core Audio en `.muted` sobre esos procesos: su audio deja de
/// llegar al parlante mientras el tap existe, sin tocar el volumen del sistema
/// ni pausar nada. Nadie lee el tap. Si Dilo se cae, el tap muere con el
/// proceso y el audio vuelve solo.
///
/// Todo pasa en una cola propia, en orden: callar y devolver nunca esperan a
/// la HAL desde el hilo principal, y un devolver que llega antes de que el tap
/// exista igual lo desarma después.
final class SilenciadorDeLoQueSuena: @unchecked Sendable {
  private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.silencio-al-dictar")
  /// Sólo se toca en `cola`.
  private var tapID = AudioObjectID(kAudioObjectUnknown)

  func callar() {
    cola.async { self.armar() }
  }

  func devolver() {
    cola.async { self.desarmar() }
  }

  private func armar() {
    guard tapID == kAudioObjectUnknown else { return }
    let procesos = HALDeReuniones.procesos.map { objeto in
      SilencioAlDictar.Proceso(
        objeto: objeto,
        pid: HALDeReuniones.leer(objeto, kAudioProcessPropertyPID, inicial: pid_t(0)) ?? 0,
        paquete: HALDeReuniones.paquete(de: objeto),
        suena: HALDeReuniones.leer(objeto, kAudioProcessPropertyIsRunningOutput, inicial: UInt32(0)) == 1,
        abreElMicrofono: HALDeReuniones.abreElMicrofono(objeto)
      )
    }
    let objetos = SilencioAlDictar.aCallar(procesos, pidPropio: getpid(), paquetePropio: Bundle.main.bundleIdentifier)
    guard !objetos.isEmpty else { return }

    let descripcion = CATapDescription(stereoMixdownOfProcesses: objetos)
    descripcion.uuid = UUID()
    descripcion.name = "Dilo · silencio al dictar"
    descripcion.isPrivate = true
    descripcion.muteBehavior = .muted

    var nuevo = AudioObjectID(kAudioObjectUnknown)
    let estado = AudioHardwareCreateProcessTap(descripcion, &nuevo)
    guard estado == noErr, nuevo != kAudioObjectUnknown else {
      AppLog.audio.notice("silencio al dictar: no se pudo crear el tap (\(estado, privacy: .public))")
      return
    }
    tapID = nuevo
    AppLog.audio.info("silencio al dictar: \(objetos.count, privacy: .public) apps calladas")
  }

  private func desarmar() {
    guard tapID != kAudioObjectUnknown else { return }
    let estado = AudioHardwareDestroyProcessTap(tapID)
    if estado != noErr {
      AppLog.audio.notice("silencio al dictar: no se pudo soltar el tap (\(estado, privacy: .public))")
    }
    tapID = kAudioObjectUnknown
  }
}

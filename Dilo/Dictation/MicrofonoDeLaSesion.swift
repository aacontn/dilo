import DiloEngines
import Foundation
import os

/// Lo que el micrófono de un dictado tiene que saber y contar, compartido por
/// las dos capturas (la de Apple y la de Parakeet) desde la raíz de
/// composición.
///
/// Existe para no tocar el contrato `SpeechEngine` ni `AudioCapture`: quien
/// arma la sesión deja acá lo que corresponde antes de arrancar, y cada
/// `MicrophoneInput` lo lee al abrirse. El detector de micrófono muerto avisa
/// por acá, ya en el hilo de audio.
///
/// `@unchecked Sendable` con candado, como `MicrophoneInput`: lo escriben el
/// hilo de audio y el de la sesión.
final class MicrofonoDeLaSesion: @unchecked Sendable {
  private let candado = NSLock()
  private var mudo = false
  private var entradaDeLaSesion: EntradaDeAudio?
  private var alAvisar: (@Sendable (DetectorDeMicMuerto.Evento) -> Void)?

  /// A quién se le cuenta lo que ve el detector. Lo pone la raíz de
  /// composición, una vez: el HUD.
  func alAvisar(_ manejador: @escaping @Sendable (DetectorDeMicMuerto.Evento) -> Void) {
    candado.withLock { alAvisar = manejador }
  }

  /// Un dictado nuevo empieza sin aviso a cuestas, y con el micrófono que
  /// decidió `PlanDeMicrofono` (sin fijar = seguir la entrada del sistema).
  func empezarSesion(_ plan: PlanDeMicrofono.Decision = .init(fijarA: nil, motivo: .delSistema)) {
    candado.withLock {
      mudo = false
      entradaDeLaSesion = plan.fijarA
    }
    switch plan.motivo {
    case .delSistema:
      break
    case .elegidoAusente:
      AppLog.audio.notice("el micrófono elegido no está conectado; uso el del sistema")
    case .elegido, .evitarBluetooth:
      AppLog.audio.info(
        "micrófono \(String(describing: plan.motivo), privacy: .public): \(plan.fijarA?.nombre ?? "", privacy: .public)"
      )
    }
  }

  /// El micrófono al que se fija el motor de este dictado; nil sigue al
  /// sistema. Lo lee `MicrophoneInput` al abrirse.
  var entrada: EntradaDeAudio? { candado.withLock { entradaDeLaSesion } }

  /// Si el micrófono de este dictado lleva cinco segundos o más entregando
  /// ceros y no revivió. Lo pregunta el corte por falta de voz, para decir
  /// por qué corta en vez de esconder la forma callada.
  var estaMudo: Bool { candado.withLock { mudo } }

  /// Lo que vio el detector, desde el hilo de audio.
  func detectorVio(_ evento: DetectorDeMicMuerto.Evento) {
    let manejador = candado.withLock { () -> (@Sendable (DetectorDeMicMuerto.Evento) -> Void)? in
      switch evento {
      case .avisar, .escalar: mudo = true
      case .revivio: mudo = false
      case .reabrir: break
      }
      return alAvisar
    }
    switch evento {
    case .reabrir:
      AppLog.audio.notice("el micrófono arrancó entregando ceros; lo reabro una vez")
    case .avisar:
      AppLog.audio.notice("cinco segundos de ceros: aviso que el micrófono no entrega sonido")
    case .escalar:
      AppLog.audio.notice("quince segundos de ceros: mando a elegir otro micrófono")
    case .revivio:
      AppLog.audio.notice("volvió el sonido del micrófono")
    }
    manejador?(evento)
  }
}

/// Lo que la muesca dice de un micrófono que no entrega sonido. Copy, en un
/// solo lugar para que el aviso, el escalado y el corte no digan tres cosas.
enum AvisoDelMicrofono {
  /// A los cinco segundos, en la forma mientras sigue escuchando. Corto: la
  /// muesca dictando mide 184 puntos.
  static var sinSonido: String { String(localized: "El micrófono no entrega sonido") }
  /// A los quince segundos.
  static var sigueSinSonido: String { String(localized: "Sigue sin sonido: cambia de micrófono") }
  /// Cuando el dictado se corta por no oír voz y el micrófono estaba mudo.
  /// Nombra el permiso porque es la causa más común —en sandbox, un permiso
  /// denegado entrega justamente ceros— y dice dónde se elige otro.
  static var cortadoSinSonido: String {
    String(localized: "El micrófono no entregó sonido. Revisa su permiso o elige otro en Ajustes → Dictado.")
  }

  /// La línea para cada evento; nil despeja.
  static func texto(para evento: DetectorDeMicMuerto.Evento) -> String? {
    switch evento {
    case .avisar: sinSonido
    case .escalar: sigueSinSonido
    case .reabrir, .revivio: nil
    }
  }
}

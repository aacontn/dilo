import DiloEngines
import Foundation
import os

/// Arma el motor doble con lo que la app ya tiene.
///
/// `AppleEngine` no reimplementa nada: le pasa los cuatro verbos del contrato
/// al actor de Talkify que ya maneja SpeechAnalyzer. `ParakeetEngine` usa la
/// misma captura de micrófono. Quien pide un dictado habla con el router y no
/// se entera de cuál de los dos contestó.
enum DiloSpeechStack {
  static func armar(apple servicio: SpeechRecognitionService) -> SpeechEngineRouter {
    let appleEngine = AppleEngine(
      bridge: AppleEngine.Bridge(
        prewarm: { try await servicio.prewarm(locale: $0) },
        start: { locale, handlers in
          try await servicio.start(
            locale: locale,
            updateHandler: { update in
              handlers.parcial(
                EngineUpdate(
                  finalizado: update.finalizedText,
                  volatil: update.volatileText
                )
              )
            },
            failureHandler: { handlers.falla($0) },
            levelHandler: { handlers.nivel($0) }
          )
        },
        finish: { try await servicio.finish() },
        cancel: { await servicio.cancel() }
      )
    )

    return SpeechEngineRouter(
      apple: appleEngine,
      parakeet: ParakeetEngine(captura: MicrophoneCapture()),
      elegido: .porDefecto,
      parakeetDescargado: { ParakeetModelStore.estaDescargado },
      avisar: { seleccion in
        guard let aviso = seleccion.aviso else { return }
        AppLog.speech.notice("\(aviso, privacy: .public)")
      }
    )
  }
}

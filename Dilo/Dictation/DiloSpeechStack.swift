import DiloEngines
import Foundation
import os

/// Arma el motor doble con lo que la app ya tiene.
///
/// `AppleEngine` no reimplementa nada: le pasa los cuatro verbos del contrato
/// al actor de la app que ya maneja SpeechAnalyzer. `ParakeetEngine` usa la
/// misma captura de micrófono. Quien pide un dictado habla con el router y no
/// se entera de cuál de los dos contestó.
enum DiloSpeechStack {
  /// El motor doble y, encima, la red que guarda la toma
  /// (`MotorConRespaldo`). Los dos motores escriben en la misma grabadora
  /// —la que el servicio de Apple ya recibió—, y los dos saben transcribir
  /// desde ella: el reintento y la segunda opinión no dependen de quién
  /// escuchó.
  static func armar(
    apple servicio: SpeechRecognitionService,
    grabadora: GrabadoraEnRAM,
    microfono: MicrofonoDeLaSesion? = nil
  ) -> (motores: SpeechEngineRouter, respaldo: MotorConRespaldo) {
    let parakeet = ParakeetEngine(
      captura: MicrophoneCapture(grabadora: grabadora, microfono: microfono),
      cargador: cargadorDeParakeet
    )
    let motores = armar(apple: servicio, parakeet: parakeet)
    let respaldo = MotorConRespaldo(
      motores: motores,
      grabadora: grabadora,
      transcribir: { motor, muestras, locale in
        switch motor {
        case .parakeet:
          return try await parakeet.transcribirSinSesion(muestras)
        case .apple:
          return try await TranscripcionAppleDesdeRAM.transcribir(
            muestras, locale: locale, tusPalabras: await servicio.terminosPropios()
          )
        }
      }
    )
    return (motores, respaldo)
  }

  /// Qué Parakeet carga el motor: el que resuelve lo que hay en disco y la
  /// elección de Ajustes, leída de `UserDefaults` en cada dictado (lo que
  /// `AppSettings` escribe). Un solo cargador para el motor y el router, así
  /// que los dos ven la misma variante.
  static let cargadorDeParakeet = CargadorDeParakeet(
    elegida: { PreferenciaDeVariante.leer(.standard) },
    // La segunda pasada de Tus palabras, con la misma lista que recibe
    // Apple. Cambiarla recarga el modelo en el próximo dictado.
    tusPalabras: {
      PreferenciaDeTusPalabrasEnParakeet.palabras(en: .standard, clave: AppSettings.claveDePalabrasPropias)
    }
  )

  static func armar(
    apple servicio: SpeechRecognitionService,
    parakeet: ParakeetEngine = ParakeetEngine(captura: MicrophoneCapture(), cargador: cargadorDeParakeet)
  ) -> SpeechEngineRouter {
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
      parakeet: parakeet,
      elegido: .porDefecto,
      parakeetDescargado: { cargadorDeParakeet.disponible },
      nombreDeParakeet: { cargadorDeParakeet.varianteEnUso?.nombre },
      avisar: { seleccion in
        guard let aviso = seleccion.aviso else { return }
        AppLog.speech.notice("\(aviso, privacy: .public)")
      }
    )
  }
}

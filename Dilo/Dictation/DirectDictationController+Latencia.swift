import DiloCapabilities
import Foundation

/// Dónde cae cada hito de `RelojDeFases` en una sesión. Aparte del
/// controlador para que medir no se mezcle con decidir: la máquina no sabe
/// que se la mide, y ningún hito cambia lo que pasa con el dictado.
extension DirectDictationController {
  /// Lo que una acción de la máquina dice del tiempo: el gatillo que abre una
  /// sesión, el micrófono que se abre y el soltar que la termina. Con el
  /// instante que trae la acción —el del tap, no el de cuando el main actor
  /// llegó a atenderla—, igual que el umbral del toque.
  func anotarLatencia(
    _ accion: DictationSessionMachine.Action,
    efectos: [DictationSessionMachine.Effect]
  ) {
    if efectos.contains(.checkAndBegin), let instante = accion.instante {
      relojDeFases = RelojDeFases()
      relojDeFases.marcar(.gatillo, en: instante)
    }
    if case let .recognitionStarted(now) = accion {
      relojDeFases.marcar(.microfonoAbierto, en: now)
    }
    if efectos.contains(where: \.terminaDeEscuchar) {
      relojDeFases.marcar(.soltar, en: accion.instante ?? .now)
    }
  }

  /// El texto ya revisado; el del motor fue `revision` antes.
  func anotarRevisado(revision: Duration?) {
    let ahora = ContinuousClock.now
    relojDeFases.marcar(.revisado, en: ahora)
    if let revision { relojDeFases.marcar(.textoDelMotor, en: ahora - revision) }
  }

  /// La entrega contestó. El ⌘V cuenta sólo si salió en esta sesión: el
  /// servicio de inserción recuerda el último, que puede ser de otra.
  func anotarEntrega(_ entrega: ResultadoDeEntrega, atajo: ContinuousClock.Instant?) {
    let ahora = ContinuousClock.now
    if let atajo, let soltar = relojDeFases.instante(de: .soltar), atajo > soltar {
      relojDeFases.marcar(.atajoEnviado, en: atajo)
    }
    relojDeFases.marcar(.entregado, en: ahora)
    relojDeFases.resultado = ResultadoMedido(entrega)
  }

  /// Lo medido hasta acá, y el reloj limpio para la sesión siguiente.
  func cerrarLaMedicion() -> RelojDeFases? {
    let reloj = relojDeFases
    relojDeFases = RelojDeFases()
    return reloj.valeLaPena ? reloj : nil
  }
}

extension DictationSessionMachine.Action {
  /// El instante que trae la acción, si trae uno.
  var instante: ContinuousClock.Instant? {
    switch self {
    case let .triggerPressed(now), let .triggerReleased(now), let .menuToggled(now),
      let .recognitionStarted(now), let .limiteAlcanzado(now):
      now
    default:
      nil
    }
  }
}

extension DictationSessionMachine.Effect {
  /// El efecto que para de escuchar y manda a terminar el reconocimiento.
  var terminaDeEscuchar: Bool {
    if case .finishRecognition = self { return true }
    return false
  }
}

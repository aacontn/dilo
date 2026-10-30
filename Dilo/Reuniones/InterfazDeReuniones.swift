import AppKit
import DiloReuniones
import Foundation
import Observation

/// Lo que une `ControlDeReuniones` con lo que se ve: la reunión en la muesca
/// (su actividad, las marcas, el check al terminar), los avisos con arreglo
/// y la ventana de la reunión.
///
/// Mira el control por Observation y no por sondeo: las marcas cambian cuando
/// una pista publica su segundo, y el reloj de la muesca corre solo
/// (`HUDReunionViva`). Con ninguna reunión grabando no cuesta nada.
@MainActor
final class InterfazDeReuniones {
  let control: ControlDeReuniones
  private weak var stage: HUDStage?
  /// Abre (o trae) la ventana de la reunión en curso, o de la última.
  var alAbrirLaVentana: (() -> Void)?

  init(control: ControlDeReuniones, stage: HUDStage) {
    self.control = control
    self.stage = stage
  }

  func empezar() {
    stage?.alAbrirLaReunion = { [weak self] in self?.alAbrirLaVentana?() }
    seguir()
    reflejar()
  }

  private func seguir() {
    withObservationTracking {
      _ = control.enCurso
      _ = control.aviso
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.reflejar()
        self?.seguir()
      }
    }
  }

  private func reflejar() {
    guard let stage else { return }
    let ahora = control.enCurso.map(ReunionEnLaMuesca.init)
    let antes = stage.dictationContent.reunionEnCurso
    // Una escena del arnés tiene la forma prestada: la reunión de verdad
    // entra cuando se suelte (la devuelve la muestra misma).
    guard !stage.enMuestra else { return }
    stage.mostrarReunion(ahora)
    // Terminó: la muesca vuelve a reposo con su check (spec, «Terminar»).
    if antes != nil, ahora == nil { stage.acusarElFinDeLaReunion() }
    if let aviso = control.aviso {
      decir(aviso, en: stage)
      control.olvidarAviso()
    }
  }

  /// Un aviso del control en la muesca, una vez. Sólo con la muesca libre:
  /// un aviso de la reunión no tapa un dictado en curso. Si no entra, la
  /// marca de la pista sigue en ámbar y lo dice igual.
  private func decir(_ aviso: ControlDeReuniones.Aviso, en stage: HUDStage) {
    guard stage.estado == .reposo, stage.occupant == .none else { return }
    switch Self.enLaMuesca(aviso) {
    case let .arreglo(conAccion): stage.mostrarAviso(conAccion)
    case let .frase(texto): stage.showMessage(texto)
    case nil: break
    }
  }

  enum LoQueDice: Equatable {
    case arreglo(AvisoConAccion)
    case frase(String)
  }

  /// Qué dice la muesca por cada aviso. Las vigías van con su arreglo: un
  /// clic abre el panel exacto de Ajustes del Sistema (spec, «Mientras
  /// graba»). El guion listo no interrumpe: la ventana y la lista lo dicen.
  static func enLaMuesca(_ aviso: ControlDeReuniones.Aviso) -> LoQueDice? {
    switch aviso {
    case .faltaPermisoDelAudioDelSistema:
      .arreglo(AvisoConAccion(
        texto: String(localized: "Sin audio de la llamada: falta un permiso"),
        accion: .abrirAjustes(ControlDeReuniones.panelDelAudioDelSistema)
      ))
    case .microfonoMudo:
      .arreglo(AvisoConAccion(
        texto: String(localized: "Tu micrófono no suena: revisa el permiso"),
        accion: .abrirAjustes(panelDelMicrofono)
      ))
    case .espacioBajo:
      .frase(String(localized: "Queda poco disco: la reunión sigue grabando"))
    case let .noEmpezo(motivo):
      .frase(motivo)
    case .pasadaFallo:
      .frase(String(localized: "El guion no salió: míralo en Reuniones"))
    case .guionListo:
      nil
    }
  }

  static let panelDelMicrofono = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
}

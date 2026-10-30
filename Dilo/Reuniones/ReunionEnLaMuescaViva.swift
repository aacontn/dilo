import DiloReuniones
import SwiftUI

/// La reunión de la muesca con su tiempo corriendo: un `TimelineView` a 4 Hz
/// sin shader, montado sólo mientras hay una reunión grabando. Es la única
/// cosa que se mueve con la muesca quieta, y a propósito: una grabación
/// tiene que verse viva (spec, «Mientras graba»). Las marcas cambian cuando
/// cambia la pista; el reloj de acá sólo las vuelve a dibujar.
struct HUDReunionViva: View {
  let reunion: ReunionEnLaMuesca
  let alto: CGFloat

  static let refresco: TimeInterval = 0.25

  var body: some View {
    TimelineView(.periodic(from: reunion.inicio, by: Self.refresco)) { contexto in
      HUDReunionEnLaMuesca(
        tiempo: RelojDeLaReunion.texto(contexto.date.timeIntervalSince(reunion.inicio)),
        microfono: reunion.microfono,
        parlante: reunion.parlante,
        alto: alto
      )
    }
  }
}

extension ReunionEnLaMuesca.Marca {
  /// La regla vive en `EstadoDeLaMarca` (con sus tests); esto la nombra en
  /// el vocabulario del dibujo.
  init(_ estado: EstadoDeLaMarca) {
    switch estado {
    case .apagada: self = .apagada
    case .encendida: self = .encendida
    case .ambar: self = .ambar
    case .sinAudio: self = .sinAudio
    }
  }

  init(_ pista: ControlDeReuniones.PistaEnVivo) {
    self.init(EstadoDeLaMarca.de(vigia: pista.vigia, nivel: pista.nivel, falla: pista.falla))
  }
}

extension ReunionEnLaMuesca {
  init(_ enCurso: ControlDeReuniones.EnCurso) {
    self.init(
      inicio: enCurso.inicio,
      titulo: enCurso.titulo,
      microfono: Marca(enCurso.yo),
      parlante: Marca(enCurso.ellos)
    )
  }
}

import DiloPlataforma
import Foundation

/// Cómo se ve en la muesca una sesión de un agente que avisa por su *hook*
/// (`RegistroDeAgentes`): con qué prioridad pide su costado y qué dice.
///
/// La palabra es el nombre del agente y nada más: el segmento mide a lo más
/// 100 puntos (`HUDNotchGeometry.anchoMaximoDeSegmento`) y «Claude te
/// espera» no cabe. Qué está haciendo lo dice el ícono —la mano levantada es
/// lo único en el acento—, y la frase entera, con el proyecto, va en el
/// tooltip y en VoiceOver.
enum SegmentoDeAgente {
  static func actividad(_ sesion: RegistroDeAgentes.Sesion) -> ActividadDeLaMuesca {
    ActividadDeLaMuesca(
      id: sesion.id,
      prioridad: prioridad(sesion.fase.urgencia),
      puedeSerPrincipal: false
    )
  }

  static func prioridad(_ urgencia: EventoDeAgente.Urgencia) -> PrioridadDeActividad {
    switch urgencia {
    case .baja: .baja
    case .normal: .normal
    case .alta: .alta
    }
  }

  static func simbolo(_ fase: EventoDeAgente.Fase) -> String {
    switch fase {
    case .trabajando: "ellipsis.circle"
    case .espera: "hand.raised.fill"
    case .listo: "checkmark.circle"
    case .error: "exclamationmark.triangle"
    case .fin: "xmark.circle"
    }
  }

  static func contenido(_ sesion: RegistroDeAgentes.Sesion) -> ContenidoDelSegmento {
    ContenidoDelSegmento(
      id: sesion.id,
      simbolo: simbolo(sesion.fase),
      texto: sesion.agente.nombre,
      // En el acento sólo lo que se atasca sin ti.
      destacada: sesion.fase == .espera,
      accesibilidad: frase(sesion)
    )
  }

  /// «Claude te espera en dilo-mac. Un clic lo quita.»
  static func frase(_ sesion: RegistroDeAgentes.Sesion) -> String {
    let agente = sesion.agente.nombre
    let que: String = switch sesion.fase {
    case .trabajando: String(localized: "\(agente) está trabajando")
    case .espera: String(localized: "\(agente) te espera")
    case .listo: String(localized: "\(agente) terminó")
    case .error: String(localized: "\(agente) se detuvo con un error")
    case .fin: String(localized: "\(agente) cerró la sesión")
    }
    let donde = sesion.proyecto.isEmpty ? que : String(localized: "\(que) en \(sesion.proyecto)")
    return String(localized: "\(donde). Un clic lo quita de la muesca.")
  }
}

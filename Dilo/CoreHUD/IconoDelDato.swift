import DiloConsumo
import SwiftUI

/// El ícono de cada dato de la muesca.
///
/// Pedido del 2026-09-24: «pondría el ícono de la IA más que el nombre; se ve
/// más bonito si usamos íconos en general». En el costado va sólo el ícono y
/// el número; el nombre queda para VoiceOver y para el encabezado del detalle
/// del hover, donde hay lugar.
///
/// **Los logos son de sus dueños.** El de Claude es de Anthropic y el de
/// Codex, de OpenAI; los SVG vienen de CodexBar (MIT), que los usa igual:
/// para decir de qué herramienta es el número, nunca como marca de Dilo. Van
/// como plantilla, así que toman el color del texto y no traen el suyo. El
/// día que la versión de App Store los lleve, se pide permiso o se cambian por
/// un SF Symbol (guía 5.2.1 de Apple).
struct IconoDelDato: View {
  let dato: DatoDeLaMuesca
  var lado: CGFloat = 11

  var body: some View {
    Group {
      switch dato {
      case .claude:
        Image("LogoClaude", bundle: Self.bundle).resizable().scaledToFit()
      case .codex:
        Image("LogoCodex", bundle: Self.bundle).resizable().scaledToFit()
      case .ninguno:
        EmptyView()
      default:
        Image(systemName: Self.simbolo(dato))
          .font(.system(size: lado * 0.86, weight: .semibold))
      }
    }
    .frame(width: lado, height: lado)
    .accessibilityHidden(true)
  }

  /// El bundle de Dilo, que es el que tiene los logos. No `Bundle.main`: en
  /// los tests y en los renders fuera de pantalla el ejecutable principal es
  /// otro, y ahí los logos salían vacíos sin avisar.
  private final class Ancla {}
  static let bundle = Bundle(for: Ancla.self)

  /// El SF Symbol de cada dato del sistema.
  static func simbolo(_ dato: DatoDeLaMuesca) -> String {
    switch dato {
    case .cpu: "cpu"
    case .ram: "memorychip"
    case .gpu: "square.stack.3d.up.fill"
    // La red muestra lo que baja: la flecha dice cuál de los dos números es.
    case .red: "arrow.down"
    case .disco: "internaldrive"
    case .claude, .codex, .ninguno: ""
    }
  }
}

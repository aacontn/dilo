import AppKit
import DiloConsumo
import Foundation
import Testing

@testable import Dilo

/// Íconos en vez de nombres, y avisos de límite (2026-09-24): «pondría el
/// ícono de la IA más que el nombre; se ve más bonito si usamos íconos en
/// general», y «aviso al acercarse al límite».
@MainActor
@Suite("Íconos y avisos de la muesca")
struct IconosYAvisosDeLaMuescaTests {
  /// Cada fuente tiene con qué dibujarse: un logo en el catálogo de Dilo o un
  /// SF Symbol que exista en este macOS. Un ícono vacío deja el costado con
  /// un número sin decir de qué es.
  @Test func cadaFuenteTieneIcono() {
    for dato in DatoDeLaMuesca.fuentes {
      switch dato {
      case .claude:
        #expect(IconoDelDato.bundle.image(forResource: "LogoClaude") != nil)
      case .codex:
        #expect(IconoDelDato.bundle.image(forResource: "LogoCodex") != nil)
      default:
        let simbolo = IconoDelDato.simbolo(dato)
        #expect(NSImage(systemSymbolName: simbolo, accessibilityDescription: nil) != nil, "\(dato): \(simbolo)")
      }
    }
  }

  /// Y un ejemplo para la vista previa de Ajustes, con su nombre.
  @Test func cadaFuenteTieneEjemploEnAjustes() {
    for dato in DatoDeLaMuesca.fuentes {
      let lado = VistaPreviaDeLosDatos.ejemplo(dato, conPlan: true, ahora: Date())
      #expect(lado?.dato == dato)
      #expect(lado?.etiqueta.isEmpty == false)
    }
  }

  @Test func elAvisoDiceCuantoYCuandoSeReinicia() {
    let ahora = Date()
    let cinco = AvisoDeLimite(
      dato: .claude, cual: .cincoHoras, umbral: 95, porcentaje: 95.4,
      seReiniciaEn: ahora.addingTimeInterval(20 * 60 + 5)
    )
    #expect(HUDStage.texto(de: cinco, ahora: ahora).contains("95%"))
    #expect(HUDStage.texto(de: cinco, ahora: ahora).contains("20 min"))
    let semana = AvisoDeLimite(dato: .codex, cual: .semana, umbral: 80, porcentaje: 81, seReiniciaEn: nil)
    #expect(HUDStage.texto(de: semana, ahora: ahora).contains("81%"))
    #expect(HUDStage.texto(de: semana, ahora: ahora).hasPrefix("Codex"))
  }
}

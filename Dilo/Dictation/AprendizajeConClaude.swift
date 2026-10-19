import DiloModes
import DiloText
import Foundation
import os

/// El aprendizaje contra la API de Anthropic de verdad: arma los pedidos con
/// los prompts de `DiloText` y los modelos de `DiloModes`, lee la clave del
/// Llavero en el momento —la misma de los modos y de traducir,
/// `proveedor.anthropic`— y no la guarda en ninguna otra parte.
///
/// **Qué se manda a Anthropic, y cuándo**:
/// - Al revisar (después de que corregiste un dictado a mano y el filtro
///   determinista encontró algo): cada par «oído → correcto» con unas ocho
///   palabras antes y después en lo pegado y en lo corregido. Nunca el campo
///   entero, nunca la app ni el sitio.
/// - Al ordenar (de vez en cuando, en segundo plano, o con «Ordenar ahora»):
///   Tus palabras y «Cuando digo…», con la marca de cuáles se aprendieron.
///   Nada de lo dictado.
///
/// Nada de eso pasa al log: sólo cuentas y el nombre de la falla.
enum AprendizajeConClaude {
  static func pedidoParaRevisar(
    _ candidatos: [CandidatoParaRevisar], modelo: String
  ) -> ConsultaAClaude.Pedido {
    ConsultaAClaude.Pedido(
      modelo: modelo,
      esfuerzo: ModelosDeAnthropic.esfuerzoParaRevisar,
      maximoDeTokens: RevisionDeCorrecciones.maximoDeTokens,
      sistema: RevisionDeCorrecciones.instrucciones,
      peticion: RevisionDeCorrecciones.peticion(candidatos),
      esquema: RevisionDeCorrecciones.esquema,
      plazo: RevisionDeCorrecciones.plazo
    )
  }

  static func pedidoParaOrdenar(_ diccionario: Diccionario, modelo: String) -> ConsultaAClaude.Pedido {
    ConsultaAClaude.Pedido(
      modelo: modelo,
      esfuerzo: ModelosDeAnthropic.esfuerzoParaOrdenar,
      maximoDeTokens: OrdenDelDiccionario.maximoDeTokens,
      sistema: OrdenDelDiccionario.instrucciones,
      peticion: OrdenDelDiccionario.peticion(diccionario),
      esquema: OrdenDelDiccionario.esquema,
      plazo: OrdenDelDiccionario.plazo
    )
  }

  static var cuenta: String { Proveedor.anthropicDeFabrica.cuentaEnElLlavero }

  /// El veredicto de cada candidato, o nil: sin clave, sin red, fuera de
  /// plazo o con una respuesta que no se entiende. Nil es «ofrece lo de
  /// siempre», nunca un error a la vista: el aprendizaje sin Claude sigue
  /// sirviendo.
  static func revisar(
    _ candidatos: [CandidatoParaRevisar], modelo: String
  ) async -> [ParDeCorreccion: TipoDeAprendizaje]? {
    guard !candidatos.isEmpty, let clave = Llavero().clave(para: cuenta),
      !clave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    do {
      let texto = try await ConsultaAClaude(clave: clave).pedir(pedidoParaRevisar(candidatos, modelo: modelo))
      guard let leido = RevisionDeCorrecciones.leer(texto, candidatos: candidatos) else {
        AppLog.aprendizaje.notice("Revisar: respuesta ilegible")
        return nil
      }
      let quedan = leido.values.filter { $0.tipo != .nada }.count
      AppLog.aprendizaje.notice(
        "Revisar: \(candidatos.count, privacy: .public) candidatos, quedan \(quedan, privacy: .public)"
      )
      return leido.mapValues(\.tipo)
    } catch let falla as FallaDeClaude {
      AppLog.aprendizaje.notice("Revisar falló: \(falla.nombreEnElLog, privacy: .public)")
      return nil
    } catch {
      return nil
    }
  }

  /// La respuesta del modelo que ordena, en JSON. La lee
  /// `OrdenDelDiccionario`; las fallas suben con su nombre.
  static func pedirOrden(_ diccionario: Diccionario, modelo: String) async throws -> String {
    let clave = Llavero().clave(para: cuenta)
    return try await ConsultaAClaude(clave: clave).pedir(pedidoParaOrdenar(diccionario, modelo: modelo))
  }

  static func hayClave() -> Bool {
    Llavero().tieneClave(para: cuenta)
  }
}

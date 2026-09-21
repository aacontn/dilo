/// Los tres estados que el HUD de Dilo va a tener que sostener: dictando,
/// en reunión y conversando (spec §5, "máquina de sesión con tres modos y un
/// solo escenario").
///
/// **Sólo `dictando` se dibuja en v1.** Los otros dos existen acá, hoy, por
/// una razón concreta: obligan a que cada `switch` sobre el estado del HUD sea
/// exhaustivo. Cuando llegue el notetaker (v2) o la conversación (v3), el
/// compilador va a nombrar uno por uno los lugares que tienen que decidir qué
/// dibujan, en vez de que un `default:` los deje mostrando la superficie de
/// dictado con datos de otra cosa.
///
/// Es la misma apuesta que hizo el spec al pedir dos targets desde el día uno:
/// el enum cuesta nada ahora y meses después.
enum HUDSessionKind: String, CaseIterable, Sendable {
  /// Dictado directo. El único con superficie en v1.
  case dictando
  /// Reunión en curso (v2): dos flujos, mic y audio del sistema.
  case reunion
  /// Conversación por voz (v3): el turno de Dilo y el de la persona.
  case conversando

  /// Qué superficie le toca dibujar a este estado.
  var surface: HUDSurfaceKind {
    switch self {
    case .dictando: .dictado
    // Previstos y sin UI a propósito: la superficie de reunión y la de
    // conversación son specs propios, no un ajuste de la de dictado.
    case .reunion, .conversando: .ninguna
    }
  }

  /// Si este estado ya tiene algo que mostrar. El HUD no se abre por un
  /// estado que todavía no dibuja nada: una forma negra vacía se lee como un
  /// cuelgue, no como "esto viene en camino".
  var isDrawn: Bool {
    surface != .ninguna
  }
}

/// La superficie que ocupa el escenario del HUD. Un tipo aparte del estado
/// porque dos estados pueden terminar compartiendo superficie (una reunión y
/// una conversación son ambas "dos voces") sin que eso los vuelva el mismo
/// estado.
enum HUDSurfaceKind: String, Sendable {
  case dictado
  case ninguna
}

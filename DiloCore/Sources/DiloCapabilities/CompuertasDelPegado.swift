// Técnica observada en AeriVoice 0.2.5 (IsSecureEventInputEnabled y
// modificadores sostenidos antes de pegar) e imnotpayingforwisprflow (esperar
// hasta 2 s a que se suelten, sondeando cada 25 ms); implementación propia.
import Carbon
import CoreGraphics

/// Por qué un dictado no se pegó. Cada caso termina en la tarjeta del notch
/// con el texto: ninguno pierde el dictado.
public enum MotivoParaNoPegar: String, Equatable, Sendable, CaseIterable {
  /// Alguna app pidió que nadie vea ni simule teclas: casi siempre un campo
  /// de contraseña. En el target MAS es la única señal de contraseña que hay.
  case entradaSegura
  /// La persona sigue sosteniendo ⇧, ⌥, ⌃ o fn después de esperarla.
  case teclasSostenidas
  /// El foco o el cursor ya no están donde empezó el dictado.
  case focoCambio
  /// Alguien escribió en el portapapeles entre la foto y el ⌘V.
  case portapapelesAjeno
  /// La foto del portapapeles no se pudo tomar sin romper nada, así que no
  /// se tocó.
  case sinRespaldo
  /// No se pudieron crear los eventos del atajo.
  case sinAtajo
  /// Se pegó, y se tecleó si correspondía, y el campo no cambió.
  case noEntro
}

/// Lo que se mira del teclado antes de apretar algo por la persona.
/// Inyectable: un test no puede depender de lo que tenga apretado quien lo
/// corre, ni de si su Terminal tiene encendida la entrada segura.
public struct LecturasDelTeclado: Sendable {
  public var entradaSegura: @Sendable () -> Bool
  /// Del teclado físico, no de la sesión: un modificador que otra app dejó
  /// colgado no es de la persona (la misma razón de `AtajoSimulado`).
  public var modificadores: @Sendable () -> CGEventFlags

  public init(
    entradaSegura: @escaping @Sendable () -> Bool,
    modificadores: @escaping @Sendable () -> CGEventFlags
  ) {
    self.entradaSegura = entradaSegura
    self.modificadores = modificadores
  }

  public static let delSistema = LecturasDelTeclado(
    entradaSegura: { IsSecureEventInputEnabled() },
    modificadores: { CGEventSource.flagsState(.hidSystemState) }
  )

  /// Nadie apretando nada y sin entrada segura: lo que los tests necesitan
  /// para que el pegado no dependa del teclado de la máquina que los corre.
  public static let libre = LecturasDelTeclado(
    entradaSegura: { false },
    modificadores: { [] }
  )

  /// ⌘ no está: `AtajoSimulado` ya pega bien con ⌘ sostenida. Bloq Mayús
  /// tampoco: es un estado, no una tecla apretada.
  public static let teclasQueEstorbanAlPegar: CGEventFlags = [
    .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
  ]

  /// Para teclear el texto letra por letra sí estorba ⌘: una «h» tecleada
  /// con ⌘ abajo es ⌘H, y esconde la app.
  public static let teclasQueEstorbanAlTeclear: CGEventFlags =
    teclasQueEstorbanAlPegar.union(.maskCommand)

  /// Si se puede teclear ahora mismo, sin esperar.
  public var sePuedeTeclear: Bool {
    !entradaSegura()
      && modificadores().intersection(Self.teclasQueEstorbanAlTeclear).isEmpty
  }

  /// Espera a que el teclado esté libre para pegar, o dice por qué no.
  ///
  /// ⇧ o ⌥ encima de ⌘V cambian el comando (⌥⇧⌘V es «pegar con el estilo
  /// del destino»), y una V que llega mientras alguien sostiene ⌃ es otra
  /// cosa. Se espera antes de rendirse porque casi siempre es la mano
  /// soltando el gatillo: ⌃⌥Espacio se suelta de a una tecla.
  ///
  /// La entrada segura no se espera: si está encendida al pegar, el foco
  /// está en una contraseña y el dictado no va ahí.
  public func esperarTecladoLibre(
    plazo: Duration = .seconds(2),
    cada intervalo: Duration = .milliseconds(25),
    ahora: @Sendable () -> Duration,
    dormir: @Sendable (Duration) async throws -> Void
  ) async -> MotivoParaNoPegar? {
    let limite = ahora() + plazo
    while true {
      if entradaSegura() { return .entradaSegura }
      if modificadores().intersection(Self.teclasQueEstorbanAlPegar).isEmpty { return nil }
      guard ahora() < limite else { return .teclasSostenidas }
      do { try await dormir(intervalo) } catch { return .teclasSostenidas }
    }
  }
}

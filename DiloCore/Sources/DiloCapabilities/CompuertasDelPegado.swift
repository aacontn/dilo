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
  /// La persona sigue sosteniendo ⇧, ⌥ o ⌃ después de esperarla.
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
  /// Si la tecla fn/🌐 está físicamente abajo, por su estado de tecla y no
  /// por el bit `.maskSecondaryFn`: ese bit lo llevan también F13–F20, las
  /// flechas e Inicio/Fin, y en el estado del HID se queda marcado después
  /// de soltarlas. Con F19 de gatillo el bit seguía ahí al pegar.
  public var fnAbajo: @Sendable () -> Bool

  public init(
    entradaSegura: @escaping @Sendable () -> Bool,
    modificadores: @escaping @Sendable () -> CGEventFlags,
    fnAbajo: @escaping @Sendable () -> Bool = { false }
  ) {
    self.entradaSegura = entradaSegura
    self.modificadores = modificadores
    self.fnAbajo = fnAbajo
  }

  /// `kVK_Function`: la tecla fn/🌐.
  public static let teclaFn: CGKeyCode = 63

  public static let delSistema = LecturasDelTeclado(
    entradaSegura: { IsSecureEventInputEnabled() },
    modificadores: { CGEventSource.flagsState(.hidSystemState) },
    fnAbajo: { CGEventSource.keyState(.hidSystemState, key: teclaFn) }
  )

  /// Nadie apretando nada y sin entrada segura: lo que los tests necesitan
  /// para que el pegado no dependa del teclado de la máquina que los corre.
  public static let libre = LecturasDelTeclado(
    entradaSegura: { false },
    modificadores: { [] }
  )

  /// ⌘ no está: `AtajoSimulado` ya pega bien con ⌘ sostenida. Bloq Mayús
  /// tampoco: es un estado, no una tecla apretada. **fn tampoco**: no cambia
  /// lo que significa ⌘V —los menús no la miran; por eso ⌘← funciona aunque
  /// toda flecha lleve el bit de fn—, y su bit es el que se queda colgado
  /// tras una tecla de función. Con fn adentro, el gatillo F19 dejaba cada
  /// dictado dos segundos esperando y después en la tarjeta.
  public static let teclasQueEstorbanAlPegar: CGEventFlags = [
    .maskShift, .maskAlternate, .maskControl,
  ]

  /// Para teclear el texto letra por letra sí estorba ⌘: una «h» tecleada
  /// con ⌘ abajo es ⌘H, y esconde la app. Y fn también, pero mirada por su
  /// tecla (`fnAbajo`): el texto viaja en la tecla A, y 🌐A lleva el foco al
  /// Dock, 🌐E abre los emojis, 🌐F pone pantalla completa.
  public static let teclasQueEstorbanAlTeclear: CGEventFlags =
    teclasQueEstorbanAlPegar.union(.maskCommand)

  /// Si se puede teclear ahora mismo, sin esperar.
  public var sePuedeTeclear: Bool {
    !entradaSegura()
      && modificadores().intersection(Self.teclasQueEstorbanAlTeclear).isEmpty
      && !fnAbajo()
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
    await esperarTeclado(plazo: plazo, cada: intervalo, ahora: ahora, dormir: dormir).motivo
  }

  /// Lo mismo que `esperarTecladoLibre`, con lo que vio: la entrega lo
  /// anota cuando se rinde, para que un «teclas sostenidas» diga cuáles.
  public func esperarTeclado(
    plazo: Duration = .seconds(2),
    cada intervalo: Duration = .milliseconds(25),
    ahora: @Sendable () -> Duration,
    dormir: @Sendable (Duration) async throws -> Void
  ) async -> EsperaDelTeclado {
    let inicio = ahora()
    let limite = inicio + plazo
    var interrumpida = false
    while true {
      if entradaSegura() {
        return EsperaDelTeclado(
          motivo: .entradaSegura, vistas: modificadores(), esperado: ahora() - inicio,
          interrumpida: interrumpida)
      }
      let vistas = modificadores()
      if vistas.intersection(Self.teclasQueEstorbanAlPegar).isEmpty {
        return EsperaDelTeclado(
          motivo: nil, vistas: vistas, esperado: ahora() - inicio, interrumpida: interrumpida)
      }
      // Cancelada, la tarea ya no puede dormir: antes eso devolvía «teclas
      // sostenidas» al instante, sin volver a mirar. Ahora se mira una vez
      // más, se decide con esa lectura y el log dice que fue una cancelación.
      guard ahora() < limite, !interrumpida else {
        return EsperaDelTeclado(
          motivo: .teclasSostenidas, vistas: vistas, esperado: ahora() - inicio,
          interrumpida: interrumpida)
      }
      do { try await dormir(intervalo) } catch { interrumpida = true }
    }
  }
}

/// Lo que la compuerta vio al esperar el teclado.
public struct EsperaDelTeclado: Sendable, Equatable {
  /// Nil si se puede pegar.
  public let motivo: MotivoParaNoPegar?
  /// Los modificadores de la última lectura, enteros: lo que se anota.
  public let vistas: CGEventFlags
  public let esperado: Duration
  /// La tarea se canceló a media espera y se decidió sin esperar más.
  public let interrumpida: Bool

  public init(motivo: MotivoParaNoPegar?, vistas: CGEventFlags, esperado: Duration, interrumpida: Bool) {
    self.motivo = motivo
    self.vistas = vistas
    self.esperado = esperado
    self.interrumpida = interrumpida
  }

  /// Los modificadores en símbolos y en hexadecimal, para el log:
  /// «⇧ fn (0x820100)». Lo que no tiene símbolo queda en el número.
  public static func describir(_ flags: CGEventFlags) -> String {
    let nombres: [(CGEventFlags, String)] = [
      (.maskShift, "⇧"), (.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskCommand, "⌘"),
      (.maskSecondaryFn, "fn"), (.maskAlphaShift, "⇪"), (.maskNumericPad, "num"),
    ]
    let simbolos = nombres.filter { flags.contains($0.0) }.map(\.1)
    let hex = "0x" + String(flags.rawValue, radix: 16)
    return simbolos.isEmpty ? "ninguna (\(hex))" : "\(simbolos.joined(separator: " ")) (\(hex))"
  }

  /// La línea del log cuando la compuerta no deja pegar.
  public var lineaDelLog: String {
    let ms = esperado.components.seconds * 1_000 + esperado.components.attoseconds / 1_000_000_000_000_000
    return "compuerta del pegado: \(motivo?.rawValue ?? "libre") tras \(ms) ms; "
      + "vi \(Self.describir(vistas))\(interrumpida ? ", la tarea se canceló" : "")"
  }
}

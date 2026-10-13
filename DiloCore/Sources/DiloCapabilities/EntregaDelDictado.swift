// Técnica observada en AeriVoice 0.2.5 (acuse de lectura que no cuenta antes
// del ⌘V, devolver 500 ms después del acuse, estados con nombre) y Spokenly
// 2.31 (promesa con TransientType); implementación propia. Todo lo de acá es
// puro: las reglas de tiempo y de decisión del pegado, para probarlas sin un
// portapapeles ni una app viva.
import Foundation

/// Cómo terminó la entrega de un dictado, para la muesca, el log y las
/// métricas. Reemplaza a un «insertado» que sólo quería decir «se mandó el
/// ⌘V».
public enum ResultadoDeEntrega: Equatable, Sendable {
  /// Con qué se supo que el texto entró.
  public enum Confirmacion: String, Equatable, Sendable {
    /// La app de destino leyó el dictado del portapapeles después del ⌘V.
    case lectura
    /// Accesibilidad vio el texto entrar al campo.
    case campo
    /// El ⌘V no entró y entró tecleado.
    case tecleo
  }

  /// Entró, y se sabe cómo.
  case pegado(Confirmacion)
  /// El ⌘V salió y nada lo confirmó ni lo desmintió. El dictado se queda en
  /// el portapapeles mientras dura la tarjeta, por si hay que pegar a mano.
  case pegadoSinConfirmar
  /// Quedó copiado a propósito: el destino de Ajustes es «Copiar al
  /// portapapeles».
  case copiado
  /// No se pegó. El texto está en la tarjeta del notch, en el portapapeles
  /// mientras ella dure si se pudo, y en «Copiar el último dictado».
  case retenido(MotivoParaNoPegar)
  /// El dictado vino vacío: no hay nada que hacer ni que decir.
  case nadaQueEntregar

  /// Si el texto llegó adonde se pidió, o con toda probabilidad llegó: suena
  /// el pegado y la sesión cuenta en las métricas. Lo retenido no llegó a
  /// ningún lado todavía.
  public var llego: Bool {
    if case .retenido = self { return false }
    return true
  }

  /// Para el log: una palabra que se lee igual en un Mac en inglés.
  public var nombreEnElLog: String {
    switch self {
    case let .pegado(confirmacion): "pegado(\(confirmacion.rawValue))"
    case .pegadoSinConfirmar: "pegadoSinConfirmar"
    case .copiado: "copiado"
    case let .retenido(motivo): "retenido(\(motivo.rawValue))"
    case .nadaQueEntregar: "nadaQueEntregar"
    }
  }
}

/// Lo que se sabe de las lecturas de un dictado prometido en el portapapeles.
///
/// La promesa siempre entrega; lo único que esto decide es si una lectura
/// **cuenta** como acuse del pegado. Una lectura antes del ⌘V es de un gestor
/// de portapapeles o del vigía de alguien, no de la app donde se pegó.
/// Comprobado en macOS 26: AppKit guarda en caché lo entregado y la segunda
/// lectura ya no llama al proveedor, así que esa lectura temprana puede
/// esconder la del pegado de verdad. Por eso no confirma: el pegado cae a
/// «sin señal», que no pierde nada.
public struct AcuseDeLectura: Equatable, Sendable {
  /// Si el ⌘V ya salió. Se marca justo antes de publicarlo, sin ningún
  /// `await` en el medio.
  public private(set) var despachado = false
  /// Alguien leyó sin que contara.
  public private(set) var lecturaQueNoCuenta = false
  /// La promesa se dio por terminada: otro pegado la heredó, se devolvió el
  /// portapapeles o Dilo se está cerrando.
  public private(set) var detenido = false
  /// El instante de la primera lectura que cuenta.
  public private(set) var primeraLectura: Duration?

  public init() {}

  public mutating func despachar() { despachado = true }

  public mutating func detener() { detenido = true }

  /// Anota una lectura de la promesa.
  ///
  /// - Parameter pareceUnPegado: con el ⌘V de Dilo, siempre sí. Queda como
  ///   parámetro para cuando el ⌘V lo aprieta la persona y hay que adivinar
  ///   si fue ella.
  public mutating func anotarLectura(en instante: Duration, pareceUnPegado: Bool = true) {
    guard !detenido else { return }
    guard despachado, pareceUnPegado else {
      lecturaQueNoCuenta = true
      return
    }
    if primeraLectura == nil { primeraLectura = instante }
  }
}

/// Lo que el vigilante alcanzó a saber del pegado.
public enum SenalDeEntrega: Equatable, Sendable {
  /// La app de destino leyó la promesa después del ⌘V.
  case leido(en: Duration)
  /// Accesibilidad vio entrar el dictado.
  case campoCambio
  /// Accesibilidad leyó en todas las lecturas, nada cambió y la persona no
  /// tocó nada: el ⌘V no entró.
  case campoIgual
  /// Alguien escribió en el portapapeles: no se sabe y no se toca.
  case ajeno
  /// Otro dictado heredó este pegado, o la espera se canceló.
  case cancelado
  /// Ni acuse ni campo concluyente.
  case sinSenal
}

/// Por qué y cuándo volvió lo que la persona tenía en el portapapeles. Va al
/// log tal cual; la muesca mira `ResultadoDeEntrega`, no esto.
public enum MotivoDeDevolucion: String, Equatable, Sendable {
  case trasLectura
  case trasConfirmarElCampo
  case trasEsperar
  /// Alguien copió otra cosa: lo suyo no se toca.
  case ajeno
  /// No se pudo escribir la foto; quedó el dictado para no dejarlo vacío.
  case fallidoQuedoElDictado
  /// Otro dictado heredó la foto y se va a encargar él.
  case heredado
  /// Dilo se cerró con el dictado en el portapapeles.
  case alCerrar
}

/// Cuándo devolver el portapapeles.
///
/// Sin señal, el dictado se queda lo que dura la tarjeta para que ⌘V a mano
/// funcione. Si en ese rato la persona pega, el acuse llega y se adelanta a
/// la gracia de siempre: lo suyo vuelve medio segundo después de que lo usó.
public struct PlanDeDevolucion: Equatable, Sendable {
  public private(set) var limite: Duration
  public private(set) var motivo: MotivoDeDevolucion

  public init(limite: Duration, motivo: MotivoDeDevolucion) {
    self.limite = limite
    self.motivo = motivo
  }

  /// Una lectura que llegó mientras se esperaba. Sólo adelanta: una lectura
  /// nunca hace esperar más.
  public mutating func anotarLectura(en instante: Duration, gracia: Duration) {
    guard motivo == .trasEsperar else { return }
    let nuevo = instante + gracia
    guard nuevo < limite else { return }
    limite = nuevo
    motivo = .trasLectura
  }
}

/// El vigilante del pegado como reducer: dice qué hacer en cada vuelta y
/// cuándo ya sabe lo suficiente. El bucle que duerme y lee es del servicio.
public struct VigiaDelPegado: Equatable, Sendable {
  public enum Paso: Equatable, Sendable {
    /// Dormir esto y volver a preguntar.
    case esperar(Duration)
    /// Tomar una foto del campo y pasársela a `anotar(_:)`.
    case leerElCampo
    /// Ya se sabe.
    case terminar(SenalDeEntrega)
  }

  public let inicio: Duration
  public let tiempos: TiemposDePegado
  public let verificaElCampo: Bool
  public private(set) var lecturasPendientes: [Duration]
  public private(set) var ultimoVeredicto: VeredictoDelCampo?

  /// - Parameters:
  ///   - inicio: el instante del ⌘V.
  ///   - verificaElCampo: si hay ancla y foto de antes. Sin ellas sólo cuenta
  ///     el acuse.
  public init(inicio: Duration, tiempos: TiemposDePegado, verificaElCampo: Bool) {
    self.inicio = inicio
    self.tiempos = tiempos
    self.verificaElCampo = verificaElCampo
    lecturasPendientes = verificaElCampo ? tiempos.lecturasDelCampo : []
  }

  /// La vuelta siguiente.
  ///
  /// - Parameters:
  ///   - esDeDilo: si el portapapeles sigue teniendo este dictado y nada
  ///     encima.
  ///   - lectura: el acuse que cuenta, si llegó.
  ///   - huboEntradaDeLaPersona: si la persona tecleó o hizo clic desde el
  ///     ⌘V. Sólo se pregunta al final: un campo distinto que es obra suya
  ///     no prueba nada.
  public mutating func siguiente(
    ahora: Duration,
    esDeDilo: Bool,
    lectura: Duration?,
    huboEntradaDeLaPersona: () -> Bool
  ) -> Paso {
    if let lectura { return .terminar(.leido(en: lectura)) }
    if !esDeDilo { return .terminar(.ajeno) }
    if ultimoVeredicto == .entro { return .terminar(.campoCambio) }
    if let proxima = lecturasPendientes.first, ahora >= inicio + proxima {
      lecturasPendientes.removeFirst()
      return .leerElCampo
    }
    let fin = inicio + tiempos.ventana
    guard ahora >= fin else {
      // Sin dormir de más: la próxima lectura del campo, si viene antes que
      // el sondeo, manda.
      let proxima = lecturasPendientes.first.map { inicio + $0 - ahora }
      return .esperar(min(tiempos.sondeo, proxima ?? tiempos.sondeo, fin - ahora))
    }
    let todasLasLecturas = verificaElCampo && lecturasPendientes.isEmpty
    guard todasLasLecturas, ultimoVeredicto == .noCambio, !huboEntradaDeLaPersona() else {
      return .terminar(.sinSenal)
    }
    return .terminar(.campoIgual)
  }

  /// Lo que dijo la última foto del campo. «Entró» termina en la vuelta
  /// siguiente; los otros dos sólo pesan si son el último.
  public mutating func anotar(_ veredicto: VeredictoDelCampo) {
    ultimoVeredicto = veredicto
  }
}

/// Qué hacer cuando el vigilante ya sabe.
public enum DecisionTrasLaSenal: Equatable, Sendable {
  /// Contestar con este resultado y devolver el portapapeles según el plan.
  /// Sin plan, el portapapeles ya no es de Dilo y no se toca.
  case terminar(ResultadoDeEntrega, PlanDeDevolucion?)
  /// El ⌘V no entró: teclearlo una vez y volver a mirar.
  case reintentarTecleando

  public static func para(
    _ senal: SenalDeEntrega,
    ahora: Duration,
    tiempos: TiemposDePegado,
    puedeTeclear: Bool
  ) -> DecisionTrasLaSenal {
    let esperar = PlanDeDevolucion(limite: ahora + tiempos.esperaSinSenal, motivo: .trasEsperar)
    switch senal {
    case let .leido(en: instante):
      return .terminar(
        .pegado(.lectura),
        PlanDeDevolucion(limite: instante + tiempos.graciaTrasLectura, motivo: .trasLectura))
    case .campoCambio:
      return .terminar(
        .pegado(.campo),
        PlanDeDevolucion(limite: ahora + tiempos.graciaTrasElCampo, motivo: .trasConfirmarElCampo))
    case .ajeno, .cancelado:
      return .terminar(.pegadoSinConfirmar, nil)
    case .sinSenal:
      return .terminar(.pegadoSinConfirmar, esperar)
    case .campoIgual:
      return puedeTeclear ? .reintentarTecleando : .terminar(.retenido(.noEntro), esperar)
    }
  }

  /// Después de teclear: qué dijo el campo.
  public static func trasTeclear(
    _ veredicto: VeredictoDelCampo,
    ahora: Duration,
    tiempos: TiemposDePegado
  ) -> DecisionTrasLaSenal {
    let esperar = PlanDeDevolucion(limite: ahora + tiempos.esperaSinSenal, motivo: .trasEsperar)
    switch veredicto {
    case .entro:
      // Lo que entró, entró tecleado: el portapapeles ya no hace falta.
      return .terminar(.pegado(.tecleo), PlanDeDevolucion(limite: ahora, motivo: .trasConfirmarElCampo))
    case .noSeSabe:
      return .terminar(.pegadoSinConfirmar, esperar)
    case .noCambio:
      return .terminar(.retenido(.noEntro), esperar)
    }
  }
}

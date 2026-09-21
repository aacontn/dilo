import Foundation

/// Con qué proveedor corre un modo, y qué pasa si ése falla.
///
/// Función pura, testeable sin red. Las reglas son las del spec 2026-07-29,
/// incluidos los tres hallazgos de su implementación:
///
/// 1. Un proveedor sin modelo **no está disponible**. Sin ese corte, los
///    ajustes de fábrica —que dejan el modelo en vacío— mandaban la
///    transcripción a `api.openai.com` sin modelo ni clave.
/// 2. "No reintentar el mismo proveedor" compara el par (proveedor, modelo),
///    no sólo el id: mismo proveedor con otro modelo es otra llamada.
/// 3. Si la caída cruza de local a nube, se avisa. Tarde, porque el texto ya
///    viajó, pero enterarse tarde es mejor que no enterarse.
public enum ResolucionDeProveedor {
  public struct Resuelto: Equatable, Sendable {
    public var proveedor: Proveedor
    public var modelo: String
    public var esLocal: Bool

    public init(proveedor: Proveedor, modelo: String, esLocal: Bool) {
      self.proveedor = proveedor
      self.modelo = modelo
      self.esLocal = esLocal
    }
  }

  /// Lo que hay que intentar, en orden, y si avisar cuando el respaldo entre.
  public struct Plan: Equatable, Sendable {
    public var primario: Resuelto?
    public var respaldo: Resuelto?
    /// Verdadero cuando el texto termina saliendo de esta compu aunque el modo
    /// se había configurado local. Es el único caso que avisa.
    public var avisaCruceALaNube: Bool

    public init(
      primario: Resuelto?, respaldo: Resuelto?, avisaCruceALaNube: Bool
    ) {
      self.primario = primario
      self.respaldo = respaldo
      self.avisaCruceALaNube = avisaCruceALaNube
    }

    /// Sin nada que intentar: el texto sale con el piso local aplicado, que es
    /// exactamente lo que pasaba antes de que existieran los proveedores.
    public var noHayNadaQueIntentar: Bool { primario == nil && respaldo == nil }
  }

  /// Un proveedor concreto, si está en condiciones de correr.
  static func resolver(
    _ proveedorID: String?,
    catalogo: [Proveedor],
    tieneClave: (Proveedor) -> Bool
  ) -> Resuelto? {
    // Un id que ya no existe —la persona borró el proveedor— no es una falla:
    // es configuración vieja, y hereda el general en silencio.
    guard let proveedor = catalogo.proveedor(proveedorID) else { return nil }
    let modelo = proveedor.modelo.trimmingCharacters(in: .whitespacesAndNewlines)
    if proveedor.dialecto != .enElChip, modelo.isEmpty { return nil }
    if proveedor.necesitaClave, !tieneClave(proveedor) { return nil }
    return Resuelto(proveedor: proveedor, modelo: modelo, esLocal: proveedor.esLocal)
  }

  public static func plan(
    para modo: Modo,
    general proveedorGeneralID: String?,
    catalogo: [Proveedor],
    tieneClave: (Proveedor) -> Bool
  ) -> Plan {
    let general = resolver(
      proveedorGeneralID, catalogo: catalogo, tieneClave: tieneClave
    )
    guard let propio = resolver(
      modo.proveedorID, catalogo: catalogo, tieneClave: tieneClave
    ) else {
      // El modo pidió un proveedor que no resuelve: lo borraron, le falta la
      // clave o le falta el modelo. Corre el general. Que "era local" se
      // deduce del id que el modo pidió y no de la resolución, que acá está
      // vacía: deducirlo de la resolución dejaba este caso —justo uno de los
      // que el aviso existe para cubrir— cruzando a la nube en silencio.
      let eraLocal = catalogo.proveedor(modo.proveedorID)?.esLocal ?? false
      return Plan(
        primario: general,
        respaldo: nil,
        avisaCruceALaNube: eraLocal && general?.esLocal == false
      )
    }

    let mismaLlamada = general.map {
      $0.proveedor.id == propio.proveedor.id && $0.modelo == propio.modelo
    } ?? false
    let respaldo = mismaLlamada ? nil : general

    // El cruce se deduce del modo, no de la resolución: un modo local cuyo
    // proveedor quedó sin modelo también cruza, y ése era justo el caso que
    // el aviso se perdía (pendiente conocido del spec, arreglado acá).
    let cruza = propio.esLocal && (respaldo?.esLocal == false)
    return Plan(primario: propio, respaldo: respaldo, avisaCruceALaNube: cruza)
  }

  /// El aviso, en las palabras que ve la persona.
  public static func avisoDeCruce(modo: Modo, respaldo: Resuelto) -> String {
    "\(modo.nombre) se procesó con \(respaldo.proveedor.nombre) porque el "
      + "proveedor que elegiste no respondió. El texto salió de esta compu."
  }

  /// Con qué corre este modo en esta sesión, y con **ninguno más**.
  ///
  /// El `Plan` de arriba describe una cadena con respaldo, que es lo que el
  /// spec 2026-07-29 pedía. Dictando se vio que no sirve: un modo local que
  /// falla y cae a una nube manda a un tercero lo que alguien dictó creyendo
  /// que no salía de su Mac, y enterarse después no lo deshace. Acá la sesión
  /// se congela en un proveedor al empezar; si ése falla, se dice qué pasó y
  /// el texto crudo queda recuperable. No hay segundo intento.
  ///
  /// El que se congela es el del modo, o el general cuando el modo no eligió
  /// ninguno. Que el general sea de otra naturaleza no le quita nada al que
  /// sí va a correr: la regla prohíbe el **reintento** que cruza, no el
  /// primer intento.
  public enum DeSesion: Equatable, Sendable {
    /// Corre con éste, y sale o no de la compu según él diga.
    case corre(Resuelto)
    /// Hay un proveedor usable, pero usarlo sería sacar de la compu un texto
    /// que el modo pidió local. No se hace: se dice y el dictado sale limpio.
    /// Pasa **sólo** cuando el proveedor local del modo no resolvió y el que
    /// quedó es de otra naturaleza; un local disponible nunca se bloquea.
    case seNiegaACruzar(aviso: String)
    /// Nada configurado que pueda correr. El dictado sale como salía antes de
    /// que existieran los proveedores: limpio, sin pasar por ninguna IA.
    case sinProveedor
  }

  public static func deSesion(
    para modo: Modo,
    general proveedorGeneralID: String?,
    catalogo: [Proveedor],
    tieneClave: (Proveedor) -> Bool
  ) -> DeSesion {
    let plan = plan(
      para: modo, general: proveedorGeneralID, catalogo: catalogo,
      tieneClave: tieneClave
    )
    guard let primario = plan.primario else { return .sinProveedor }

    // La regla se mira sobre el proveedor que **esta** sesión va a usar, no
    // sobre el respaldo que el `Plan` dejó anotado por si el primario falla.
    // Confundir los dos bloqueaba de entrada un local disponible: con el
    // general en una nube, un modo en el chip se negaba a correr aunque nada
    // iba a salir de la compu.
    if primario.esLocal { return .corre(primario) }

    // Acá el que corre es una nube. Sólo se corta si el modo había pedido
    // local: su proveedor no resolvió —borrado, sin modelo o sin clave— y lo
    // que quedó fue el general, afuera de la compu. Ése, y nada más, es el
    // cruce silencioso que el spec 2026-07-29 manda evitar.
    guard catalogo.proveedor(modo.proveedorID)?.esLocal == true else {
      return .corre(primario)
    }
    return .seNiegaACruzar(aviso: avisoDeNegativa(modo: modo, enVezDe: primario))
  }

  /// Lo que dice la píldora cuando Dilo se niega a cruzar.
  public static func avisoDeNegativa(modo: Modo, enVezDe: Resuelto) -> String {
    "\(modo.nombre) pedía un proveedor de esta compu y no está disponible. No "
      + "lo mandé a \(enVezDe.proveedor.nombre): tu dictado salió tal cual."
  }

  /// Lo que dice la píldora cuando el proveedor congelado falló.
  public static func avisoDeFalla(modo: Modo, proveedor: Proveedor) -> String {
    "\(modo.nombre) no pudo reescribir: \(proveedor.nombre) no respondió. Tu "
      + "dictado salió tal cual, y lo tienes en «Copiar el último dictado»."
  }
}

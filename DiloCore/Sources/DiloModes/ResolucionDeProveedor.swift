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
}

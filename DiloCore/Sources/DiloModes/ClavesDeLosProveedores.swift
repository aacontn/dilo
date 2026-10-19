import Foundation
import Observation

/// Si hay clave de cada proveedor, como la ve la ventana de Ajustes: leído una
/// vez, fuera del hilo principal, y compartido por todas las secciones.
///
/// Nace del congelamiento de Ajustes (Alfonso, 2026-10-19: «la ventana de
/// configuración se congela»). Modos leía el Llavero en el `get:` del
/// `SecureField` —una consulta síncrona en cada evaluación del `body`— y
/// escribía en cada tecla; Idioma y Tus palabras preguntaban otra vez al
/// aparecer, en el hilo principal. Cada consulta cruza a `securityd`, y con
/// una firma ad hoc nueva puede quedarse esperando el diálogo de permiso del
/// Llavero. Ahora la pregunta se hace una vez por cuenta, en otro hilo, y la
/// respuesta queda acá hasta que alguien guarde, borre u `olvidar()`.
///
/// Nunca guarda el secreto: sólo si existe. Guardar recibe el texto, lo
/// escribe y lo suelta.
@MainActor
@Observable
public final class ClavesDeLosProveedores {
  public enum Estado: Equatable, Sendable {
    /// Nadie preguntó todavía.
    case sinLeer
    /// La consulta está en camino.
    case leyendo
    case hay
    case falta
  }

  public private(set) var estados: [String: Estado] = [:]

  @ObservationIgnored private let almacen: any AlmacenDeClaves
  /// Las consultas en camino, por cuenta: tres secciones que preguntan a la
  /// vez esperan la misma.
  @ObservationIgnored private var lecturas: [String: Task<Bool, Never>] = [:]

  public init(almacen: any AlmacenDeClaves) {
    self.almacen = almacen
  }

  public func estado(de cuenta: String) -> Estado {
    estados[cuenta] ?? .sinLeer
  }

  /// `true` sólo cuando se sabe que hay. Mientras se lee, la respuesta es
  /// «no»: las vistas que la usan muestran el aviso de que falta apenas
  /// un instante, nunca un campo que no hace nada.
  public func hay(_ cuenta: String) -> Bool {
    estado(de: cuenta) == .hay
  }

  /// Lee si todavía no se sabe y devuelve si hay. Barato de llamar desde
  /// cualquier `.task`: lo ya sabido vuelve sin tocar el almacén.
  @discardableResult
  public func mirar(_ cuenta: String) async -> Bool {
    switch estado(de: cuenta) {
    case .hay: return true
    case .falta: return false
    case .sinLeer, .leyendo: break
    }
    if let enCamino = lecturas[cuenta] { return await enCamino.value }

    estados[cuenta] = .leyendo
    let almacen = almacen
    let lectura = Task.detached(priority: .userInitiated) {
      almacen.tieneClave(para: cuenta)
    }
    lecturas[cuenta] = lectura
    let hay = await lectura.value
    lecturas[cuenta] = nil
    // Si mientras tanto alguien guardó o borró, lo suyo es más nuevo.
    guard estados[cuenta] == .leyendo else { return self.hay(cuenta) }
    estados[cuenta] = hay ? .hay : .falta
    return hay
  }

  /// Guarda la clave, ya limpia de espacios; una en blanco borra. Se llama al
  /// confirmar (Intro o «Guardar»), nunca por tecla.
  public func guardar(_ clave: String, para cuenta: String) async throws {
    let limpia = clave.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpia.isEmpty else {
      try await borrar(cuenta)
      return
    }
    let almacen = almacen
    try await Task.detached(priority: .userInitiated) {
      try almacen.guardar(limpia, para: cuenta)
    }.value
    estados[cuenta] = .hay
  }

  public func borrar(_ cuenta: String) async throws {
    let almacen = almacen
    try await Task.detached(priority: .userInitiated) {
      try almacen.borrar(cuenta)
    }.value
    estados[cuenta] = .falta
  }

  /// Trae el secreto para usarlo **una vez** —«Probar conexión»—, fuera
  /// del hilo principal. No se guarda acá ni en ningún lado: quien lo pide
  /// lo usa y lo suelta.
  public func secreto(_ cuenta: String) async -> String? {
    let almacen = almacen
    return await Task.detached(priority: .userInitiated) {
      almacen.clave(para: cuenta)
    }.value
  }

  /// Olvida lo sabido: la próxima pregunta vuelve a leer. Ajustes lo llama
  /// al abrir la ventana, por si la clave cambió por fuera (Acceso a
  /// Llaveros, otra copia de Dilo).
  public func olvidar() {
    estados = estados.filter { $0.value == .leyendo }
  }

  /// Fija el estado sin leer: para los renders y las vistas previas, que no
  /// tocan el Llavero de nadie.
  public func fijar(_ hay: Bool, para cuenta: String) {
    estados[cuenta] = hay ? .hay : .falta
  }
}

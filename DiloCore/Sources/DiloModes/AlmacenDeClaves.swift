import Foundation
#if canImport(Security)
  import Security
#endif

/// Dónde viven las claves de API.
///
/// En el Llavero de macOS y en ninguna otra parte: ni en `UserDefaults`, ni en
/// un JSON de ajustes, ni en un `.env`, ni en un log. Es una restricción
/// transversal del spec y la regla de la casa. El protocolo existe para que
/// las reglas que dependen de "¿hay clave?" se testeen sin tocar el Llavero
/// real, no para dejar abierta la puerta a otro almacén.
public protocol AlmacenDeClaves: Sendable {
  func clave(para cuenta: String) -> String?
  func guardar(_ clave: String, para cuenta: String) throws
  func borrar(_ cuenta: String) throws
}

public extension AlmacenDeClaves {
  func tieneClave(para cuenta: String) -> Bool {
    guard let clave = clave(para: cuenta) else { return false }
    return !clave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

#if canImport(Security)
  /// El Llavero de macOS, con un ítem de contraseña genérica por proveedor.
  public struct Llavero: AlmacenDeClaves {
    public enum Falla: Error, Equatable {
      case elLlaveroDijoQueNo(OSStatus)
    }

    /// El servicio bajo el que se agrupan los ítems. No cambia nunca:
    /// renombrarlo deja las claves guardadas invisibles y a la persona
    /// creyendo que Dilo las perdió.
    public let servicio: String

    public init(servicio: String = "cl.espaciodigital.dilo.proveedores") {
      self.servicio = servicio
    }

    public func clave(para cuenta: String) -> String? {
      var consulta = baseDeConsulta(cuenta)
      consulta[kSecReturnData as String] = true
      consulta[kSecMatchLimit as String] = kSecMatchLimitOne

      var resultado: CFTypeRef?
      let estado = SecItemCopyMatching(consulta as CFDictionary, &resultado)
      guard estado == errSecSuccess, let datos = resultado as? Data else { return nil }
      return String(data: datos, encoding: .utf8)
    }

    public func guardar(_ clave: String, para cuenta: String) throws {
      let datos = Data(clave.utf8)
      let consulta = baseDeConsulta(cuenta)
      let cambio = [kSecValueData as String: datos]

      let actualizado = SecItemUpdate(consulta as CFDictionary, cambio as CFDictionary)
      if actualizado == errSecSuccess { return }
      guard actualizado == errSecItemNotFound else {
        throw Falla.elLlaveroDijoQueNo(actualizado)
      }

      var nuevo = consulta
      nuevo[kSecValueData as String] = datos
      // Sólo mientras esta Mac está desbloqueada, y sólo en esta Mac: una
      // clave de API no tiene por qué viajar a iCloud ni estar disponible
      // antes de que la persona entre a su sesión.
      nuevo[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let agregado = SecItemAdd(nuevo as CFDictionary, nil)
      guard agregado == errSecSuccess else {
        throw Falla.elLlaveroDijoQueNo(agregado)
      }
    }

    public func borrar(_ cuenta: String) throws {
      let estado = SecItemDelete(baseDeConsulta(cuenta) as CFDictionary)
      guard estado == errSecSuccess || estado == errSecItemNotFound else {
        throw Falla.elLlaveroDijoQueNo(estado)
      }
    }

    private func baseDeConsulta(_ cuenta: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: servicio,
        kSecAttrAccount as String: cuenta,
      ]
    }
  }
#endif

/// Un almacén de mentira, para los tests. No persiste nada.
public final class AlmacenEnMemoria: AlmacenDeClaves, @unchecked Sendable {
  private let candado = NSLock()
  private var claves: [String: String]

  public init(_ claves: [String: String] = [:]) {
    self.claves = claves
  }

  public func clave(para cuenta: String) -> String? {
    candado.withLock { claves[cuenta] }
  }

  public func guardar(_ clave: String, para cuenta: String) throws {
    candado.withLock { claves[cuenta] = clave }
  }

  public func borrar(_ cuenta: String) throws {
    _ = candado.withLock { claves.removeValue(forKey: cuenta) }
  }
}

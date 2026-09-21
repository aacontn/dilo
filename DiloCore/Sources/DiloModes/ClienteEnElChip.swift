#if canImport(FoundationModels)
  import FoundationModels
#endif
import Foundation

/// El proveedor que no necesita nada: el modelo de Apple corriendo en el chip.
///
/// Sin clave, sin cuenta, sin internet y sin que el texto salga de la compu.
/// Es el único que funciona recién instalado, y por eso encabeza el catálogo.
///
/// Es el único lugar de `DiloModes` que importa FoundationModels: si el
/// framework no está —una máquina sin Apple Intelligence, o `swift test` en
/// otro sitio— el tipo sigue existiendo y dice por qué no puede.
public struct ClienteEnElChip: ClienteDeProveedor {
  public init() {}

  /// Nil mientras el modelo puede contestar; si no, una frase que explica por
  /// qué no, en las palabras que ve la persona.
  public static func porQueNoSePuede() -> String? {
    #if canImport(FoundationModels)
      switch SystemLanguageModel.default.availability {
      case .available:
        return nil
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Prende Apple Intelligence en Ajustes del Sistema para usar el "
          + "modelo que corre acá mismo."
      case .unavailable(.modelNotReady):
        return "Apple Intelligence todavía está preparando su modelo."
      case .unavailable:
        return "Esta Mac no tiene el modelo de Apple disponible."
      }
    #else
      return "Esta compilación no trae el modelo de Apple."
    #endif
  }

  public func responder(
    instrucciones: String, peticion: String, modelo _: String
  ) async throws -> String {
    #if canImport(FoundationModels)
      // Sesión nueva cada vez: reescribir es de un turno, y no hay ninguna
      // razón para que se acumule un transcript de lo que alguien dictó.
      let sesion = LanguageModelSession(instructions: instrucciones)
      let respuesta = try await sesion.respond(to: peticion)
      let texto = respuesta.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !texto.isEmpty else { throw FallaDelProveedor.respuestaVacia }
      return texto
    #else
      throw FallaDelProveedor.respondioMal(codigo: -1)
    #endif
  }
}

/// El cliente que corresponde a un proveedor ya resuelto.
public enum FabricaDeClientes {
  public static func cliente(
    para resuelto: ResolucionDeProveedor.Resuelto,
    claves: some AlmacenDeClaves
  ) -> any ClienteDeProveedor {
    guard resuelto.proveedor.dialecto != .enElChip else { return ClienteEnElChip() }
    return ClienteHTTP(
      proveedor: resuelto.proveedor,
      clave: claves.clave(para: resuelto.proveedor.cuentaEnElLlavero)
    )
  }
}

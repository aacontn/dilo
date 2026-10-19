import Foundation

/// Lo que cambia en los proveedores guardados con la llegada de Claude Haiku
/// 5.5 de fábrica (2026-10-19). Puro e idempotente, como `MigracionDeModos`:
/// quien lo llama guarda el resultado y anota la marca.
public enum MigracionDeProveedores {
  /// El Anthropic guardado con el modelo vacío pasa a Haiku 5.5. Un modelo
  /// que alguien escribió no se toca nunca, aunque no esté en la lista.
  ///
  /// Vacío quería decir «sin configurar» (`Proveedor.modelo`), y un
  /// Anthropic sin modelo no corría aunque tuviera clave. Con el modelo de
  /// fábrica, pegar la clave basta.
  public static func conModeloDeFabrica(_ proveedores: [Proveedor]) -> [Proveedor] {
    proveedores.map { proveedor in
      guard proveedor.id == Proveedor.anthropicDeFabrica.id,
        proveedor.modelo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return proveedor }
      var conModelo = proveedor
      conModelo.modelo = ModelosDeAnthropic.deFabrica.id
      return conModelo
    }
  }

  /// El proveedor general que corresponde, o nil si se queda como está.
  ///
  /// **El criterio**: pasa a Anthropic **una sola vez**, si el general sigue
  /// siendo el de fábrica (el modelo de Apple), nadie lo cambió desde que
  /// existe esta regla y hay clave de Anthropic en el Llavero. Quien después
  /// vuelve al modelo de Apple se queda ahí: cualquier cambio del general
  /// —en Modos o por esta misma regla— anota que ya se decidió
  /// (`yaSeDecidio`), y esta regla no vuelve a mirar.
  ///
  /// Que el de fábrica esté guardado no prueba que alguien lo eligió: hasta
  /// hoy era la única opción que funcionaba sin configurar nada. Y quien no
  /// tiene clave no pierde nada: sin clave no hay cambio, y la regla vuelve a
  /// mirar en el arranque siguiente.
  ///
  /// - Parameter hayClaveDeAnthropic: se llama sólo si lo demás ya dice que
  ///   sí, para no preguntarle al Llavero en cada arranque de quien ya decidió.
  public static func generalConClave(
    actual: String, yaSeDecidio: Bool, hayClaveDeAnthropic: () -> Bool
  ) -> String? {
    guard !yaSeDecidio, actual == Proveedor.deFabrica[0].id, hayClaveDeAnthropic() else {
      return nil
    }
    return Proveedor.anthropicDeFabrica.id
  }
}

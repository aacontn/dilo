import DiloModes
import DiloText
import Foundation
import os

/// Corre un modo sobre lo dictado, con el proveedor que la sesión congeló.
///
/// Reemplaza al `PromptShapingService` heredado del árbol de origen, que hacía lo
/// mismo pero contra la otra biblioteca y siempre en el chip. Lo que se
/// conserva de él es lo que costó aprender: el marco que impide que el modelo
/// conteste la transcripción (ahora en `PromptDeLimpieza`) y el timeout, que
/// FoundationModels no ofrece y sin el cual una reescritura colgada se queda
/// con las palabras de alguien.
///
/// Lo que **no** se conserva es el paso de largo silencioso. Antes cualquier
/// falla devolvía el texto crudo sin decir nada, que está bien cuando el
/// modelo corre en el chip y mal cuando el proveedor es una nube: la persona
/// no tiene cómo saber si su modo corrió o no. Ahora la falla se cuenta.
struct TransformacionDeModo: Sendable {
  /// Más largo que cualquier reescritura sana, corto para lo que aguanta
  /// alguien mirando la píldora. El framework no trae timeout propio.
  static let timeoutPorDefecto = Duration.seconds(10)

  /// Cómo se llega al proveedor ya resuelto. Es una costura para que los
  /// tests no abran un socket ni pidan Apple Intelligence.
  typealias Fabrica = @Sendable (ResolucionDeProveedor.Resuelto)
    -> any ClienteDeProveedor

  var fabrica: Fabrica = { resuelto in
    FabricaDeClientes.cliente(para: resuelto, claves: Llavero())
  }
  var timeout = Self.timeoutPorDefecto
  /// La misma costura de tiempo que usan los plazos del pegado: contra el
  /// reloj de pared, un test de timeout afirma que la máquina fue rápida.
  var reloj = DeadlineClock.continuous

  /// Lo que salió de correr un modo.
  enum Resultado: Equatable, Sendable {
    /// El modo reescribió. El texto es el suyo.
    case transformado(String)
    /// No corrió, y por esto. El dictado sale como salió y la píldora lo
    /// dice; quien quiera el original lo tiene en "Copiar el último dictado".
    case salioTalCual(aviso: String)
    /// El modo contestó, pero lo que devolvió cambiaba el sentido de lo
    /// dictado. Va lo de la capa de reglas, la píldora dice por qué y la
    /// propuesta queda en el menú por si el validador se equivocó.
    case rechazado(propuesta: String, motivo: ValidadorDeLimpieza.Rechazo)
    /// No había nada que correr: ningún modo, o ningún proveedor configurado.
    /// No es una falla y no se avisa nada.
    case sinModo
  }

  /// - Parameter deSesion: el proveedor congelado al empezar el dictado.
  ///   **No hay segundo intento**: si ése falla, no se prueba otro. Mandarle
  ///   a una nube lo que alguien dictó creyendo que no salía de su Mac no se
  ///   arregla avisando después.
  func correr(
    _ texto: String,
    con modo: Modo,
    deSesion: ResolucionDeProveedor.DeSesion
  ) async -> Resultado {
    guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .sinModo
    }

    let resuelto: ResolucionDeProveedor.Resuelto
    switch deSesion {
    case .sinProveedor:
      return .sinModo
    case let .seNiegaACruzar(aviso):
      AppLog.delivery.notice(
        "modo \(modo.id, privacy: .public): no se cruza a la nube, sale tal cual"
      )
      return .salioTalCual(aviso: aviso)
    case let .corre(uno):
      resuelto = uno
    }

    let cliente = fabrica(resuelto)
    // El dictado viaja como dato dentro de un JSON. En el chip la ventana es
    // de 4.096 tokens y las instrucciones se ajustan al largo del dictado.
    let enElChip = resuelto.proveedor.dialecto == .enElChip
    let instrucciones = PromptDeLimpieza.instrucciones(
      para: modo,
      largoDelDictado: texto.count,
      ventana: enElChip ? PromptDeLimpieza.ventanaDelChip : nil
    )
    let peticion = PromptDeLimpieza.peticion(
      para: modo,
      sobre: SobreDelDictado(dictado: texto),
      topeDeContexto: enElChip
        ? PromptDeLimpieza.topeDeContextoEnElChip : PromptDeLimpieza.topeDeContextoEnLinea
    )
    let modelo = resuelto.modelo
    let timeout = timeout
    let reloj = reloj

    // El primero que conteste gana; el resume del perdedor se descarta. Una
    // petición abandonada puede seguir corriendo: ése es el precio de
    // devolver a tiempo las palabras de alguien.
    let respuesta: String? = await withCheckedContinuation { continuacion in
      let listo = OSAllocatedUnfairLock(initialState: false)
      let terminar: @Sendable (String?) -> Void = { valor in
        let esElPrimero = listo.withLock { bandera in
          guard !bandera else { return false }
          bandera = true
          return true
        }
        if esElPrimero { continuacion.resume(returning: valor) }
      }
      let trabajo = Task {
        terminar(
          try? await cliente.reescribir(
            instrucciones: instrucciones, peticion: peticion, modelo: modelo
          )
        )
      }
      Task {
        try? await reloj.sleep(timeout)
        trabajo.cancel()
        terminar(nil)
      }
    }

    let limpio = respuesta?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let limpio, !limpio.isEmpty else {
      AppLog.delivery.notice(
        "modo \(modo.id, privacy: .public) no reescribió con \(resuelto.proveedor.id, privacy: .public)"
      )
      return .salioTalCual(
        aviso: ResolucionDeProveedor.avisoDeFalla(
          modo: modo, proveedor: resuelto.proveedor
        )
      )
    }
    return Self.juzgar(limpio, contra: texto, modo: modo)
  }

  /// Ninguna respuesta del modelo se pega sin pasar por acá. Se juzga contra
  /// lo que el modelo recibió —el dictado ya limpio por las reglas—, con la
  /// vara que declara el modo. Rechazar no reintenta en otro proveedor.
  static func juzgar(_ respuesta: String, contra dictado: String, modo: Modo) -> Resultado {
    do throws(ValidadorDeLimpieza.Rechazo) {
      let aceptado = try ValidadorDeLimpieza.validar(
        respuesta, contra: dictado, perfil: .init(modo.cuidado)
      )
      return .transformado(aceptado)
    } catch {
      // El motivo sí, el texto nunca: es lo que dice qué afinar.
      AppLog.delivery.notice(
        "modo \(modo.id, privacy: .public): el validador rechazó (\(error.rawValue, privacy: .public))"
      )
      return .rechazado(
        propuesta: ValidadorDeLimpieza.lavar(respuesta, fuente: dictado), motivo: error
      )
    }
  }
}

extension ValidadorDeLimpieza.Perfil {
  /// `DiloModes` no conoce al validador y `DiloText` no conoce los modos:
  /// la traducción entre los dos vive acá, en la app, que enlaza a ambos.
  init(_ cuidado: Cuidado) {
    switch cuidado {
    case .limpieza: self = .limpieza
    case .ligera: self = .ligera
    case .reescritura: self = .reescritura
    case .libre: self = .libre
    }
  }
}

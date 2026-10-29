import DiloEngines
import Foundation
import Observation

/// Phonon tal como lo ven Ajustes y «Leer»: qué está instalado, la descarga
/// en curso y su avance.
///
/// Compartido y no de la vista, como `DescargaDeParakeet`: cambiar de sección
/// en Ajustes reemplaza la vista, y una descarga que arrancó «Leer» tiene que
/// verse en Ajustes. Nada de esto toca el disco en el hilo principal: el
/// estado se mira en `Task.detached`.
@MainActor
@Observable
final class PhononEnDilo {
  static let compartido = PhononEnDilo()

  @ObservationIgnored let instalacion = InstalacionDePhonon()

  /// Nil hasta la primera mirada: Ajustes dice «Revisando…» en vez de
  /// afirmar que falta algo que quizás está.
  private(set) var estado: InstalacionDePhonon.Estado?
  private(set) var progreso: ProgresoDeDescarga?
  private(set) var error: String?

  /// Mira el disco por la voz elegida.
  func refrescar(voz: VozDePhonon) {
    Task {
      let estado = await Task.detached(priority: .userInitiated) {
        InstalacionDePhonon.estado(voz: voz)
      }.value
      self.estado = estado
    }
  }

  /// Baja el runtime y la voz si faltan. Vuelve cuando terminó o falló; dos
  /// llamadas seguidas esperan la misma descarga (`InstalacionDePhonon`).
  @discardableResult
  func preparar(voz: VozDePhonon) async -> Bool {
    error = nil
    if progreso == nil { progreso = ProgresoDeDescarga(fraccion: 0, fase: "Viendo qué falta…") }
    defer {
      progreso = nil
      refrescar(voz: voz)
    }
    do {
      try await instalacion.preparar(voz: voz) { avance in
        Task { @MainActor in
          if self.progreso != nil { self.progreso = avance }
        }
      }
      return true
    } catch InstalacionDePhonon.Falla.faltaElModelo {
      // No es un error de la descarga: lo dice la fila del modelo.
      return false
    } catch is CancellationError {
      return false
    } catch {
      self.error = Self.frase(de: error)
      return false
    }
  }

  func cancelar(voz: VozDePhonon) {
    Task {
      await instalacion.cancelar()
      progreso = nil
      refrescar(voz: voz)
    }
  }

  func borrar(voz: VozDePhonon) {
    Task {
      try? await instalacion.borrar()
      refrescar(voz: voz)
    }
  }

  static func frase(de error: any Error) -> String {
    switch error {
    case InstalacionDePhonon.Falla.hashNoCalza:
      String(localized: "Lo bajado no calza con lo publicado y no se instaló.")
    case InstalacionDePhonon.Falla.descomprimir:
      String(localized: "No se pudo abrir el motor bajado.")
    case InstalacionDePhonon.Falla.sinConexion, is URLError:
      String(localized: "Sin conexión. Vuelve a intentarlo.")
    default:
      String(localized: "No se pudo bajar.")
    }
  }
}

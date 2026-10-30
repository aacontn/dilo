import AVFoundation
import DiloReuniones
import Foundation

/// Un clic en una línea del guion reproduce la reunión desde ahí, mientras el
/// audio exista (spec, «El guion»): las dos pistas a la vez, cada una desde
/// su propio segundo —el reloj del Mac no es el de cada pista
/// (`AlineacionDeRelojes`)—, como sonó la llamada.
///
/// Nada se carga hasta el primer clic, y todo se suelta al parar.
@MainActor
final class ReproductorDelGuion {
  private var reproductores: [AVAudioPlayer] = []

  var sonando: Bool { reproductores.contains(where: \.isPlaying) }

  /// Reproduce desde `segundo` (del reloj del Mac, desde que empezó la
  /// reunión). Devuelve false si no hay audio que reproducir.
  @discardableResult
  func reproducir(_ enDisco: ReunionEnDisco, desde segundo: Double) -> Bool {
    parar()
    guard ReproduccionDelGuion.hayAudio(enDisco.reunion) else { return false }
    let alineacion = AlineacionDeRelojes(LectorDeReuniones.relojes(de: enDisco))
    var listos: [(AVAudioPlayer, TimeInterval)] = []
    for pista in Pista.allCases {
      let partes = (enDisco.reunion.pista(pista)?.partes ?? []).map { parte in
        enDisco.reunion.audio == .aac ? RetencionDelAudio.nombreAAC(de: parte) : parte
      }
      let abiertos = partes.compactMap { try? AVAudioPlayer(contentsOf: enDisco.archivo($0)) }
      guard abiertos.count == partes.count, !abiertos.isEmpty else { continue }
      // Una pista que empezó después que la reunión —el tap del Mac no corre
      // hasta que algo suena— entra con su retraso.
      let local = alineacion.local(segundos: segundo, pista: pista)
      if local < 0 {
        listos.append((abiertos[0], -local))
      } else if let tramo = ReproduccionDelGuion.tramo(desde: local, duraciones: abiertos.map(\.duration)) {
        let reproductor = abiertos[tramo.parte]
        reproductor.currentTime = tramo.segundo
        listos.append((reproductor, 0))
      }
    }
    guard let primero = listos.first?.0 else { return false }
    let ahora = primero.deviceCurrentTime + 0.05
    for (reproductor, retraso) in listos {
      reproductor.prepareToPlay()
      reproductor.play(atTime: ahora + retraso)
    }
    reproductores = listos.map(\.0)
    return true
  }

  func parar() {
    reproductores.forEach { $0.stop() }
    reproductores = []
  }
}

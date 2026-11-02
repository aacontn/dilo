import Foundation
import Testing

@testable import DiloEngines

/// Mientras dictas se calla lo que suena, salvo Dilo y una llamada.
struct SilencioAlDictarTests {
  typealias Proceso = SilencioAlDictar.Proceso

  let spotify = Proceso(objeto: 11, pid: 500, paquete: "com.spotify.client", suena: true, abreElMicrofono: false)
  let youtube = Proceso(objeto: 12, pid: 501, paquete: "com.apple.WebKit.GPU", suena: true, abreElMicrofono: false)
  let enPausa = Proceso(objeto: 13, pid: 502, paquete: "com.apple.Music", suena: false, abreElMicrofono: false)
  let zoom = Proceso(objeto: 14, pid: 503, paquete: "us.zoom.xos", suena: true, abreElMicrofono: true)
  let dilo = Proceso(objeto: 15, pid: 900, paquete: "cl.espaciodigital.dilo", suena: true, abreElMicrofono: true)

  private func aCallar(_ procesos: [Proceso]) -> [UInt32] {
    SilencioAlDictar.aCallar(procesos, pidPropio: 900, paquetePropio: "cl.espaciodigital.dilo")
  }

  @Test func callaLoQueSuena() {
    #expect(aCallar([spotify, youtube]) == [11, 12])
  }

  @Test func loQueNoSuenaNoSeToca() {
    #expect(aCallar([enPausa]).isEmpty)
  }

  /// Sus sonidos de empezar y terminar dicen en qué está el dictado.
  @Test func nuncaCallaADilo() {
    #expect(aCallar([dilo, spotify]) == [11])
  }

  /// El objeto de proceso puede no tener el pid de Dilo (un ayudante), pero sí
  /// su paquete.
  @Test func nuncaCallaAlPaqueteDeDilo() {
    let ayudante = Proceso(objeto: 16, pid: 901, paquete: "cl.espaciodigital.dilo", suena: true, abreElMicrofono: false)
    #expect(aCallar([ayudante]).isEmpty)
  }

  /// Callar una llamada es perderte lo que te dicen mientras escribes en el
  /// chat.
  @Test func unaLlamadaNoSeCalla() {
    #expect(aCallar([zoom, spotify]) == [11])
  }

  @Test func unPidInvalidoNoSeCalla() {
    let raro = Proceso(objeto: 17, pid: 0, paquete: nil, suena: true, abreElMicrofono: false)
    #expect(aCallar([raro]).isEmpty)
  }

  @Test func sinPaqueteIgualSeCallaSiSuena() {
    let sinPaquete = Proceso(objeto: 18, pid: 600, paquete: nil, suena: true, abreElMicrofono: false)
    #expect(aCallar([sinPaquete]) == [18])
  }
}

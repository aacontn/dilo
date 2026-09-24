import Foundation
import Testing

@testable import DiloConsumo

/// GPU, red, disco y los avisos de límite (2026-09-24).
@Suite("Más datos y avisos")
struct MasDatosYAvisosTests {
  @Test func laRedSeMideComoDiferencia() {
    let muestra = MuestraDelSistema()
    let t0 = Date(timeIntervalSince1970: 1_000)
    #expect(muestra.intercambiarRed((1_000, 500, t0)) == nil, "la primera no tiene contra qué comparar")
    let velocidad = muestra.intercambiarRed((3_000_000, 1_500, t0.addingTimeInterval(2)))
    #expect(velocidad == VelocidadDeRed(baja: 1_499_500, sube: 500))
    // Un contador que retrocede no da una velocidad negativa.
    #expect(muestra.intercambiarRed((10, 10, t0.addingTimeInterval(4))) == nil)
  }

  @Test func elSistemaDeVerdadDaRedYDisco() {
    let muestra = MuestraDelSistema()
    #expect(MuestraDelSistema.bytesDeRed() != nil)
    let disco = muestra.disco()
    #expect(disco.map { $0.ocupado > 0 && $0.ocupado <= 100 && $0.libre > 0 } == true)
    // La GPU puede no estar en una máquina virtual de CI; si está, en rango.
    if let gpu = muestra.gpu() { #expect((0...100).contains(gpu)) }
  }

  @Test func losNuevosSeEscribenCorto() {
    #expect(TextoDelDato.velocidad(850) == "850B")
    #expect(TextoDelDato.velocidad(12_400) == "12K")
    #expect(TextoDelDato.velocidad(3_400_000) == "3,4M")
    #expect(TextoDelDato.gigas(312_400_000_000) == "312 GB")
    #expect(DetalleDelDato.red(VelocidadDeRed(baja: 12_400, sube: 850)).map(\.valor) == ["12K/s", "850B/s"])
  }

  // MARK: Avisos

  private let reinicio = Date(timeIntervalSince1970: 1_790_200_000)
  private var ahora: Date { reinicio.addingTimeInterval(-3600) }

  private func ventana(_ porcentaje: Double, reinicio: Date? = nil) -> VentanaDeUso {
    VentanaDeUso(porcentaje: porcentaje, seReiniciaEn: reinicio ?? self.reinicio, duracion: 18_000)
  }

  @Test func avisaUnaVezPorUmbral() throws {
    var vigia = VigiaDeLimites()
    #expect(vigia.revisar(.codex, .cincoHoras, ventana(79), ahora: ahora) == nil)
    let al80 = try #require(vigia.revisar(.codex, .cincoHoras, ventana(81), ahora: ahora))
    #expect(al80.umbral == 80)
    vigia.marcar(al80)
    #expect(vigia.revisar(.codex, .cincoHoras, ventana(85), ahora: ahora) == nil, "el 80 ya se dijo")
    let al95 = try #require(vigia.revisar(.codex, .cincoHoras, ventana(96), ahora: ahora))
    #expect(al95.umbral == 95)
  }

  @Test func sinMarcarSeVuelveAOfrecer() {
    let vigia = VigiaDeLimites()
    #expect(vigia.revisar(.claude, .cincoHoras, ventana(90), ahora: ahora) != nil)
    #expect(vigia.revisar(.claude, .cincoHoras, ventana(90), ahora: ahora) != nil, "esperando su turno")
  }

  @Test func saltarDirectoAl95AvisaUnaSolaVez() throws {
    var vigia = VigiaDeLimites()
    let aviso = try #require(vigia.revisar(.codex, .semana, ventana(97), ahora: ahora))
    #expect(aviso.umbral == 95)
    vigia.marcar(aviso)
    #expect(vigia.revisar(.codex, .semana, ventana(97), ahora: ahora) == nil)
  }

  @Test func unaVentanaNuevaVuelveAArmarLosUmbrales() throws {
    var vigia = VigiaDeLimites()
    vigia.marcar(try #require(vigia.revisar(.codex, .cincoHoras, ventana(96), ahora: ahora)))
    let siguiente = reinicio.addingTimeInterval(5 * 3600)
    #expect(vigia.revisar(.codex, .cincoHoras, ventana(82, reinicio: siguiente), ahora: reinicio.addingTimeInterval(60)) != nil)
  }

  @Test func unosSegundosDeDiferenciaNoSonUnaVentanaNueva() throws {
    var vigia = VigiaDeLimites()
    vigia.marcar(try #require(vigia.revisar(.claude, .cincoHoras, ventana(81), ahora: ahora)))
    #expect(vigia.revisar(.claude, .cincoHoras, ventana(83, reinicio: reinicio.addingTimeInterval(3)), ahora: ahora) == nil)
  }

  @Test func losTokensNoAvisan() {
    let vigia = VigiaDeLimites()
    let tokens = VentanaDeUso(tokens: 9_000_000, seReiniciaEn: reinicio, duracion: 18_000)
    #expect(vigia.revisar(.claude, .tokensDelBloque, tokens, ahora: ahora) == nil)
  }
}

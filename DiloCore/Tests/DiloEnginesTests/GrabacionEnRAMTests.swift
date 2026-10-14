import Foundation
import Testing

@testable import DiloEngines

struct PoliticaDeGrabacionTests {
  @Test func cuentaHaciaAtrasLosUltimosQuinceSegundos() {
    #expect(PoliticaDeGrabacion.fase(transcurrido: .seconds(284)) == .normal)
    #expect(PoliticaDeGrabacion.fase(transcurrido: .seconds(285)) == .terminaEn(segundos: 15))
    #expect(PoliticaDeGrabacion.fase(transcurrido: .milliseconds(285_500)) == .terminaEn(segundos: 15))
    #expect(PoliticaDeGrabacion.fase(transcurrido: .seconds(299)) == .terminaEn(segundos: 1))
    #expect(PoliticaDeGrabacion.fase(transcurrido: .milliseconds(299_900)) == .terminaEn(segundos: 1))
    #expect(PoliticaDeGrabacion.fase(transcurrido: .seconds(300)) == .tope)
    #expect(PoliticaDeGrabacion.fase(transcurrido: .seconds(400)) == .tope)
  }

  @Test func elRelojDelMenu() {
    #expect(PoliticaDeGrabacion.reloj(299.9) == "4:59")
    #expect(PoliticaDeGrabacion.reloj(42) == "0:42")
    #expect(PoliticaDeGrabacion.reloj(-1) == "0:00")
  }

  /// Cinco minutos a 16 kHz son justo el tope de muestras: los dos números
  /// no pueden decir cosas distintas.
  @Test func elTopeDeMuestrasEsElDeTiempo() {
    #expect(Double(PoliticaDeGrabacion.muestrasMaximas)
      == PoliticaDeGrabacion.segundos(PoliticaDeGrabacion.duracionMaxima) * PoliticaDeGrabacion.tasa)
  }
}

struct GrabadoraEnRAMTests {
  @Test func avisaElTopeYNoPasaDeEl() {
    let grabadora = GrabadoraEnRAM(tope: 6)
    let trozo: [Float] = [0.5, -0.5, 2, .nan]
    #expect(trozo.withUnsafeBufferPointer { grabadora.agregar($0) })
    #expect(!trozo.withUnsafeBufferPointer { grabadora.agregar($0) })
    #expect(!trozo.withUnsafeBufferPointer { grabadora.agregar($0) })
    let toma = grabadora.tomar()
    #expect(toma.muestras.count == 6)
    #expect(toma.muestras[2] == Int16.max)  // acotado, no desbordado
    #expect(toma.muestras[3] == 0)  // NaN a cero
  }

  @Test func tomarLaDejaVaciaYDescartarBota() {
    let grabadora = GrabadoraEnRAM()
    let trozo = AudioDePrueba.tono(segundos: 0.5)
    trozo.withUnsafeBufferPointer { _ = grabadora.agregar($0) }
    #expect(grabadora.tomar().muestras.count == 8_000)
    #expect(grabadora.tomar().muestras.isEmpty)

    trozo.withUnsafeBufferPointer { _ = grabadora.agregar($0) }
    grabadora.descartar()
    #expect(grabadora.tomar().muestras.isEmpty)
  }

  /// Int16 y de vuelta: lo que el motor recibe en un reintento es lo que se
  /// dijo, con un error que ningún motor oye.
  @Test func laTomaVuelveAFloatSinPerderNada() {
    let original = AudioDePrueba.tono(segundos: 1, amplitud: 0.3)
    let grabadora = GrabadoraEnRAM()
    original.withUnsafeBufferPointer { _ = grabadora.agregar($0) }
    let vuelta = grabadora.tomar().comoFloat()
    #expect(vuelta.count == original.count)
    let peor = zip(original, vuelta).map { abs($0 - $1) }.max() ?? 1
    #expect(peor < 0.000_1)
  }

  /// La grabadora se llena desde el hilo de audio mientras otro hilo la
  /// toma; el candado es lo único que separa eso de un crash.
  @Test func aguantaQueLaLlenenYLaTomenALaVez() async {
    let grabadora = GrabadoraEnRAM()
    let trozo = [Float](repeating: 0.1, count: 341)
    await withTaskGroup(of: Void.self) { grupo in
      for _ in 0..<8 {
        grupo.addTask {
          for _ in 0..<200 { trozo.withUnsafeBufferPointer { _ = grabadora.agregar($0) } }
        }
      }
      grupo.addTask {
        for _ in 0..<50 { _ = grabadora.tomar() }
      }
    }
    #expect(grabadora.cuenta <= 8 * 200 * 341)
  }

  @Test func unaTomaFallidaVenceALosDiezMinutos() {
    let t0 = ContinuousClock.now
    let toma = TomaFallida(audio: TomaDeAudio(muestras: []), idioma: Locale(identifier: "es-CL"), cuando: t0)
    #expect(!toma.vencida(ahora: t0.advanced(by: .seconds(599))))
    #expect(toma.vencida(ahora: t0.advanced(by: .seconds(601))))
  }

  /// Cinco minutos de toma pasan a `Float` en lo que no se nota al soltar.
  @Test func pasarCincoMinutosAFloatEsBarato() {
    let toma = TomaDeAudio(muestras: [Int16](repeating: 1_000, count: PoliticaDeGrabacion.muestrasMaximas))
    let duro = CostoDeCPU.medir { _ = toma.comoFloat() }
    print("TomaDeAudio.comoFloat, 5 min: \(duro)")
    #expect(duro < .milliseconds(40))
  }
}

struct MedidaDeTomaTests {
  private func toma(segundosDeVoz: Double, total: Double, amplitud: Float = 0.1) -> [Float] {
    var audio = AudioDePrueba.ruido(segundos: total, amplitud: 0.000_2)
    let voz = AudioDePrueba.tono(segundos: segundosDeVoz, amplitud: amplitud)
    audio.replaceSubrange(0..<voz.count, with: voz)
    return audio
  }

  @Test func cuentaLaVozYNoElSilencio() {
    let medida = MedidaDeToma.medir(toma(segundosDeVoz: 1.5, total: 3))
    #expect(abs(medida.segundosConVoz - 1.5) < 0.15)
    #expect(medida.huboVoz)
    #expect(!medida.casiMuda)
  }

  @Test func unaSalaCalladaEsMuda() {
    let medida = MedidaDeToma.medir(AudioDePrueba.ruido(segundos: 3, amplitud: 0.000_5))
    #expect(medida.casiMuda)
    #expect(!medida.huboVoz)
    #expect(medida.segundosConVoz == 0)
  }

  /// Un ventilador parejo sube el piso y con él el umbral: el ruido de la
  /// sala no cuenta como voz aunque esté por encima de −50 dBFS.
  @Test func elRuidoParejoDeLaSalaNoEsVoz() {
    let ventilador = AudioDePrueba.ruido(segundos: 4, amplitud: 0.02)
    let medida = MedidaDeToma.medir(ventilador)
    #expect(medida.segundosConVoz < 0.3)
    #expect(!medida.huboVoz)
  }

  /// Sin audio no hay opinión: una toma que nadie midió no se llama muda.
  @Test func sinAudioNoEsMudaNiTieneVoz() {
    let medida = MedidaDeToma.medir([])
    #expect(!medida.hayAudio)
    #expect(!medida.casiMuda)
    #expect(!medida.huboVoz)
  }

  @Test(.enabled(if: AudioDePrueba.haySintesis, "esta máquina no tiene `say`"))
  func vozDeVerdadCuentaComoVoz() throws {
    let voz = try AudioDePrueba.voz("Hola, mañana te mando el informe sin falta.")
    let medida = MedidaDeToma.medir(AudioDePrueba.ruido(segundos: 1, amplitud: 0.000_3) + voz)
    #expect(medida.huboVoz)
    #expect(medida.segundosConVoz > 1)
    #expect(!medida.casiMuda)
  }

  /// Voz de punta a punta, sin un respiro antes ni después: el piso sale de
  /// los huecos entre sílabas, no de la sala.
  @Test(.enabled(if: AudioDePrueba.haySintesis, "esta máquina no tiene `say`"))
  func vozSinSalaAlrededorTambienCuenta() throws {
    let voz = try AudioDePrueba.voz("Te mando el informe mañana temprano, antes de la reunión con el cliente.")
    var desde = 0
    var hasta = voz.count
    while desde < hasta, abs(voz[desde]) < 0.01 { desde += 1 }
    while hasta > desde, abs(voz[hasta - 1]) < 0.01 { hasta -= 1 }
    let medida = MedidaDeToma.medir(Array(voz[desde..<hasta]))
    #expect(medida.huboVoz)
    #expect(medida.segundosConVoz > medida.duracion * 0.5)
  }

  @Test func medirCincoMinutosEsBarato() {
    let audio = AudioDePrueba.ruido(segundos: 150, amplitud: 0.000_5) + AudioDePrueba.tono(segundos: 150)
    let duro = CostoDeCPU.medir { _ = MedidaDeToma.medir(audio) }
    print("MedidaDeToma, 5 min: \(duro)")
    #expect(duro < .milliseconds(60))
  }
}

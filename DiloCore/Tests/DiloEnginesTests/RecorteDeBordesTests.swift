import Foundation
import Testing

@testable import DiloEngines

/// El VAD de bordes: recorta el silencio de las puntas sin comerse palabras,
/// deja las pausas de adentro y no le agrega al soltar nada que se note.
struct RecorteDeBordesTests {
  @Test func recortaLasPuntasConColchon() {
    var audio = AudioDePrueba.silencio(segundos: 3)
    for i in 20_000..<28_000 { audio[i] = 0.05 * Float(sin(Double(i) * 0.1)) }
    // La primera ventana activa empieza en 19 840 y la última termina en
    // 28 160; 250 ms (4 000 muestras) de colchón a cada lado.
    #expect(RecorteDeBordes.preparar(&audio) == 15_840..<32_160)
  }

  @Test func sinVozNoHayTramo() {
    var sala = [Float](repeating: 0.000_5, count: 48_000)
    #expect(RecorteDeBordes.preparar(&sala) == nil)
    var vacio: [Float] = []
    #expect(RecorteDeBordes.preparar(&vacio) == nil)
  }

  /// Un clic del teclado son una o dos ventanas: no califica.
  @Test func unClicNoEsVoz() {
    var audio = AudioDePrueba.silencio(segundos: 2)
    for i in 16_000..<16_640 { audio[i] = 0.3 }
    #expect(RecorteDeBordes.preparar(&audio) == nil)
  }

  @Test func unaPausaAdentroQuedaIntacta() {
    var audio = AudioDePrueba.silencio(segundos: 4)
    for i in 8_000..<16_000 { audio[i] = 0.05 * Float(sin(Double(i) * 0.1)) }
    for i in 40_000..<48_000 { audio[i] = 0.05 * Float(sin(Double(i) * 0.1)) }
    let tramo = RecorteDeBordes.preparar(&audio)
    #expect(tramo?.contains(28_000) == true)
    #expect(tramo?.contains(47_999) == true)
  }

  @Test func saneaLoQueElMicrofonoNoDeberiaMandar() {
    var audio = AudioDePrueba.tono(segundos: 1)
    audio[100] = .nan
    audio[200] = .infinity
    audio[300] = 3
    #expect(RecorteDeBordes.preparar(&audio) != nil)
    #expect(audio[100] == 0)
    #expect(audio[200] == 1)
    #expect(audio[300] == 1)
  }

  /// Voz de verdad, con el ruido de una sala callada alrededor: el tramo
  /// tiene que contener cada muestra audible de la frase.
  @Test(.enabled(if: AudioDePrueba.haySintesis, "esta máquina no tiene `say`"))
  func noSeComePalabras() throws {
    let voz = try AudioDePrueba.voz("Hola, mañana te mando el informe sin falta.")
    let antes = AudioDePrueba.ruido(segundos: 1.5, amplitud: 0.000_3)
    var audio = antes + voz + AudioDePrueba.ruido(segundos: 1.5, amplitud: 0.000_3, semilla: 11)
    let audibles = voz.indices.filter { abs(voz[$0]) > 0.002 }
    let primera = try #require(audibles.first) + antes.count
    let ultima = try #require(audibles.last) + antes.count

    let tramo = try #require(RecorteDeBordes.preparar(&audio))
    #expect(tramo.contains(primera))
    #expect(tramo.contains(ultima))
    // Y sí recortó: casi todo el silencio de las puntas se fue.
    #expect(audio.count - tramo.count > 30_000)
  }

  /// El recorte corre entre soltar y el texto, que tiene 300 ms en total
  /// (spec §3). Cinco minutos —el tope de una toma— tienen que pasar en una
  /// fracción chica de eso aun en Debug.
  @Test func cincoMinutosSeRecortanEnPocosMilisegundos() {
    let original = AudioDePrueba.ruido(segundos: 150, amplitud: 0.000_5)
      + AudioDePrueba.tono(segundos: 150)
    // Cada pasada recorta una copia: `preparar` cambia el audio que recibe.
    var audio = original
    let duro = CostoDeCPU.medir {
      audio = original
      _ = RecorteDeBordes.preparar(&audio)
    }
    print("RecorteDeBordes, 5 min de audio: \(duro)")
    #expect(duro < .milliseconds(40))
  }
}

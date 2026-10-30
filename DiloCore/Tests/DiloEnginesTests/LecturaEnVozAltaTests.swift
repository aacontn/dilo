import Foundation
import Testing

@testable import DiloEngines

struct MotorDeLecturaTests {
  private let listo = InstalacionDePhonon.Estado(runtime: true, modelo: true, voz: true)

  @Test func loGuardadoYElDeFabrica() {
    #expect(MotorDeLectura(guardado: "") == .phonon)
    #expect(MotorDeLectura(guardado: "apple") == .apple)
    #expect(MotorDeLectura(guardado: "kokoro") == .phonon)
    // El rawValue viaja en UserDefaults: renombrarlo borra la elección.
    #expect(MotorDeLectura.phonon.rawValue == "phonon")
    #expect(MotorDeLectura.apple.rawValue == "apple")
  }

  @Test func conTodoInstaladoLeePhonon() {
    #expect(DecisionDeLectura.decidir(elegido: .phonon, estado: listo, idioma: "es") == .phonon)
    // Sin saber el idioma se le cree a la persona.
    #expect(DecisionDeLectura.decidir(elegido: .phonon, estado: listo, idioma: nil) == .phonon)
  }

  @Test func appleElegidaLeeApple() {
    #expect(DecisionDeLectura.decidir(elegido: .apple, estado: listo, idioma: "es") == .apple(nil))
  }

  @Test func loQueNoEsEspanolLoLeeApple() {
    #expect(DecisionDeLectura.decidir(elegido: .phonon, estado: listo, idioma: "en") == .apple(.otroIdioma))
  }

  @Test func mientrasBajaLeeAppleYLoDice() {
    let sinVoz = InstalacionDePhonon.Estado(runtime: true, modelo: true, voz: false)
    let decision = DecisionDeLectura.decidir(elegido: .phonon, estado: sinVoz, idioma: "es")
    #expect(decision == .apple(.bajandoPhonon))
    #expect(decision.bajaPhonon)
  }

  @Test func sinModeloNoSeBajaNadaDesdeLaApp() {
    let sinModelo = InstalacionDePhonon.Estado(runtime: false, modelo: false, voz: false)
    let decision = DecisionDeLectura.decidir(elegido: .phonon, estado: sinModelo, idioma: "es")
    #expect(decision == .apple(.faltaElModelo))
    #expect(!decision.bajaPhonon)
  }
}

struct VocesDePhononTests {
  @Test func veinticincoVocesSinRepetir() {
    #expect(VocesDePhonon.todas.count == 25)
    #expect(Set(VocesDePhonon.todas.map(\.nombre)).count == 25)
    #expect(Set(VocesDePhonon.todas.map(\.archivo)).count == 25)
    #expect(VocesDePhonon.todas.filter { $0.acento == .espana }.count == 13)
    #expect(VocesDePhonon.todas.allSatisfy { $0.sha256.count == 64 })
  }

  @Test func laGuardadaOLaDeFabrica() {
    #expect(VocesDePhonon.voz("Iker").nombre == "Iker")
    #expect(VocesDePhonon.voz("").nombre == VocesDePhonon.deFabrica)
    #expect(VocesDePhonon.voz("Pepito").nombre == VocesDePhonon.deFabrica)
  }

  @Test func laURLVaFijaALaRevision() {
    let url = VocesDePhonon.url(de: VocesDePhonon.voz("Regina")).absoluteString
    #expect(url.contains(VocesDePhonon.revision))
    #expect(url.hasSuffix("/voices/s58clrg2fe0MO7Y-.safetensors"))
  }
}

struct SintetizadorPhononTests {
  @Test func argumentosDelCLI() {
    let args = SintetizadorPhonon.argumentos(
      texto: "Hola.", voz: URL(fileURLWithPath: "/v.safetensors"),
      modelo: URL(fileURLWithPath: "/m"), salida: URL(fileURLWithPath: "/s.wav")
    )
    #expect(args == [
      "--model", "/m", "--lang", "es", "--quant", "q8", "--threads", "2",
      "--voice", "/v.safetensors", "Hola.", "-o", "/s.wav",
    ])
  }

  /// Phonon 40m no dice la ñ ni la ú, y sí «ni» y «u» (medido con Parakeet).
  @Test func laEnieYLaUConTildeSeReescriben() {
    #expect(SintetizadorPhonon.paraPhonon("el último número de música") == "el ultimo numero de musica")
    #expect(SintetizadorPhonon.paraPhonon("ÚLTIMO") == "ULTIMO")
    #expect(SintetizadorPhonon.paraPhonon("Mañana el niño de la señora Muñoz") == "Maniana el ninio de la seniora Munioz")
    #expect(SintetizadorPhonon.paraPhonon("Ñuñoa") == "Niunioa")
    #expect(SintetizadorPhonon.paraPhonon("ÑUÑOA") == "NIUNIOA")
    #expect(SintetizadorPhonon.paraPhonon("añil") == "anil")
    #expect(SintetizadorPhonon.paraPhonon("sin ene") == "sin ene")
  }

  @Test func elProcesoNoSaleAInternet() {
    let entorno = SintetizadorPhonon.entorno
    #expect(entorno["HF_HUB_OFFLINE"] == "1")
    #expect(entorno["HF_TOKEN"] == nil)
    #expect(entorno["RUST_LOG"] == "off")
  }

  @Test func elEstadoMiraLosTamanosDelModelo() {
    #expect(InstalacionDePhonon.archivosDelModelo.map(\.nombre).contains("model.q8.gguf"))
    #expect(InstalacionDePhonon.archivosDelModelo.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
  }

  @Test func elHashSeCalculaPorTrozos() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
    try Data("hola".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try InstalacionDePhonon.sha256(de: url)
      == "b221d9dbb083a7f33428d7c2a3c3198ae925614d70210e28716ccaa7cd4ddb79")
  }
}

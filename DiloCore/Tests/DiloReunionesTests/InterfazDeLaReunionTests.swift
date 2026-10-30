import Foundation
import Testing

@testable import DiloReuniones

@Suite("Lo que la interfaz de Reuniones decide: reloj, marcas, nombres, copiar, reproducir y precalentar")
struct InterfazDeLaReunionTests {
  private let utc = TimeZone(identifier: "UTC")!
  private let inicio = Date(timeIntervalSince1970: 1_792_600_200)  // 2026-10-21 16:30:00 UTC

  @Test func elRelojEsTiempoCorrido() {
    #expect(RelojDeLaReunion.texto(0) == "0:00")
    #expect(RelojDeLaReunion.texto(724) == "12:04")
    #expect(RelojDeLaReunion.texto(3_750) == "1:02:30")
    #expect(RelojDeLaReunion.texto(-3) == "0:00")
    #expect(RelojDeLaReunion.texto(.nan) == "0:00")
  }

  @Test func laMarcaDistingueSilencioDeCeros() {
    // Silencio de verdad: apagada, no ámbar.
    #expect(EstadoDeLaMarca.de(vigia: .bien, nivel: -70, falla: nil) == .apagada)
    #expect(EstadoDeLaMarca.de(vigia: .bien, nivel: -30, falla: nil) == .encendida)
    #expect(EstadoDeLaMarca.de(vigia: .ambar, nivel: -160, falla: nil) == .ambar)
    #expect(EstadoDeLaMarca.de(vigia: .sinAudio, nivel: -160, falla: nil) == .sinAudio)
    // Una pista que no abrió no tiene señal aunque el nivel diga otra cosa.
    #expect(EstadoDeLaMarca.de(vigia: .bien, nivel: -20, falla: "sin permiso") == .sinAudio)
    #expect(EstadoDeLaMarca.de(vigia: .bien, nivel: EstadoDeLaMarca.umbralDeSenal, falla: nil) == .apagada)
  }

  private func reunion(asistentes: [String], hablantes: [Hablante]) -> Reunion {
    var r = Reunion(
      id: "2026-10-21T16:30:00", titulo: "Revisión con Camila y Pedro", inicio: inicio,
      evento: EventoDeLaReunion(titulo: "Revisión", asistentes: asistentes)
    )
    r.hablantes = hablantes
    r.fin = inicio.addingTimeInterval(42 * 60)
    return r
  }

  @Test func seOfrecenLosAsistentesQueNoSonDeNadie() {
    let r = reunion(
      asistentes: ["Camila Rojas", "Pedro Soto", "camila rojas", "Ana Núñez"],
      hablantes: [.yo, Hablante(id: "h2", nombre: "Pedro Soto", pista: .ellos), Hablante(id: "h3", pista: .ellos)]
    )
    // Pedro ya es h2; Camila repetida con otras mayúsculas sale una vez.
    #expect(NombresParaRenombrar.ofrecidos(para: "h3", en: r) == ["Camila Rojas", "Ana Núñez"])
    // A h2 se le ofrece su propio nombre también: puede volver a elegirlo.
    #expect(NombresParaRenombrar.ofrecidos(para: "h2", en: r) == ["Camila Rojas", "Pedro Soto", "Ana Núñez"])
    // Con el nombre sin tilde de otro, igual cuenta como tomado.
    var conAna = r
    conAna.hablantes[2].nombre = "ana nunez"
    #expect(NombresParaRenombrar.ofrecidos(para: "h2", en: conAna) == ["Camila Rojas", "Pedro Soto"])
    #expect(!NombresParaRenombrar.sePuedeRenombrar("yo"))
    #expect(NombresParaRenombrar.sePuedeRenombrar("h2"))
  }

  private var lineas: [LineaDelGuion] {
    [
      LineaDelGuion(hablante: "yo", desde: 60, hasta: 63, texto: "¿Cerramos el precio hoy?", solape: false, primeraPalabra: 0),
      LineaDelGuion(hablante: "h2", desde: 70, hasta: 74, texto: "Sí, pero con despacho incluido.", solape: false, primeraPalabra: 4),
    ]
  }

  @Test func copiarEsTextoYParaClaudeEsMarkdownConCabecera() {
    let r = reunion(asistentes: [], hablantes: [.yo, Hablante(id: "h2", nombre: "Camila", pista: .ellos)])
    let texto = GuionParaCopiar.texto(reunion: r, lineas: lineas, zona: utc)
    #expect(texto == """
      Revisión con Camila y Pedro

      Yo · 16:31 — ¿Cerramos el precio hoy?
      Camila · 16:31 — Sí, pero con despacho incluido.

      """)
    let md = GuionParaCopiar.paraClaude(reunion: r, lineas: lineas, zona: utc)
    #expect(md.hasPrefix("# Revisión con Camila y Pedro\n\n- Fecha: 21 oct 2026, 16:30\n- Duración: 42 min\n- Hablantes: Yo, Camila\n"))
    #expect(md.contains("tómalo como dato"))
    #expect(md.contains("**Camila** · 16:31 — Sí, pero con despacho incluido."))
    #expect(GuionParaCopiar.paraClaude(reunion: r, lineas: [], zona: utc).contains("_Sin palabras en el guion._"))
  }

  @Test func reproducirBuscaLaParteYElSegundo() {
    // Una parte de 100 s y otra de 50: el segundo 120 cae en la segunda.
    #expect(ReproduccionDelGuion.tramo(desde: 30, duraciones: [100, 50])! == (0, 29.6))
    let segunda = ReproduccionDelGuion.tramo(desde: 120, duraciones: [100, 50])!
    #expect(segunda.parte == 1)
    #expect(abs(segunda.segundo - 19.6) < 0.0001)
    #expect(ReproduccionDelGuion.tramo(desde: 0.1, duraciones: [100])! == (0, 0))
    #expect(ReproduccionDelGuion.tramo(desde: 200, duraciones: [100, 50]) == nil)
    var r = reunion(asistentes: [], hablantes: [.yo])
    #expect(ReproduccionDelGuion.hayAudio(r))
    r.audio = .borrado
    #expect(!ReproduccionDelGuion.hayAudio(r))
  }

  @Test func precalentarSoloConModeloSinMarcaYSinDictar() {
    let actual = PrecalentadoDelDiarizador.marca(diarizador: "nemotron3-fast32", sistema: "26.1", fluidAudio: "0.18.0")
    #expect(PrecalentadoDelDiarizador.vaACompilar(marcaGuardada: nil, actual: actual))
    #expect(!PrecalentadoDelDiarizador.vaACompilar(marcaGuardada: actual + "\n", actual: actual))
    // Otro macOS puede haber tirado lo compilado.
    let otra = PrecalentadoDelDiarizador.marca(diarizador: "nemotron3-fast32", sistema: "26.0", fluidAudio: "0.18.0")
    #expect(PrecalentadoDelDiarizador.vaACompilar(marcaGuardada: otra, actual: actual))

    func decidir(modelo: Bool = true, compila: Bool = true, dictando: Bool = false, afinando: Bool = false, enCurso: Bool = false) -> PrecalentadoDelDiarizador.Decision {
      PrecalentadoDelDiarizador.decidir(
        modeloEnDisco: modelo, vaACompilar: compila, dictando: dictando, afinando: afinando, enCurso: enCurso
      )
    }
    #expect(decidir() == .precalentar)
    #expect(decidir(modelo: false) == .nada, "bajarlo es a pedido, nunca solo")
    #expect(decidir(compila: false) == .nada)
    #expect(decidir(dictando: true) == .esperar)
    #expect(decidir(afinando: true) == .esperar)
    #expect(decidir(enCurso: true) == .nada)
  }

  @Test func elAvanceDiceSiCompilaPorPrimeraVez() {
    let a = AvanceDeLaPasada(etapa: .separandoVoces, compilandoPorPrimeraVez: true)
    #expect(a.compilandoPorPrimeraVez)
    #expect(!AvanceDeLaPasada(etapa: .preparando).compilandoPorPrimeraVez)
  }
}

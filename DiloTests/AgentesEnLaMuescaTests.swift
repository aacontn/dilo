import CoreGraphics
import DiloPlataforma
import Foundation
import Testing

@testable import Dilo

/// Del URL scheme a los segmentos: lo que un *hook* manda termina sentado
/// en la muesca con su ícono y su frase, y se va cuando debe. El escenario
/// es un registro; la hora, una variable.
@MainActor
@Suite("Agentes en la muesca")
struct AgentesEnLaMuescaTests {
  @MainActor
  final class Muesca {
    var sentados: [String: (ActividadDeLaMuesca, ContenidoDelSegmento)] = [:]
    var publicaciones = 0
  }

  private func armar(_ settings: AppSettings? = nil) -> (AgentesEnLaMuesca, Muesca, AppSettings) {
    let muesca = Muesca()
    let ajustes = settings ?? AppSettings(defaults: UserDefaults(suiteName: "agentes-\(UUID())")!)
    let agentes = AgentesEnLaMuesca(
      settings: ajustes,
      publicar: { actividad, contenido in
        muesca.sentados[actividad.id] = (actividad, contenido)
        muesca.publicaciones += 1
      },
      retirar: { id in muesca.sentados[id] = nil }
    )
    return (agentes, muesca, ajustes)
  }

  private func url(_ texto: String) -> URL { URL(string: texto)! }

  @Test func unHookPoneSuSegmento() throws {
    let (agentes, muesca, _) = armar()
    agentes.abrir(url("dilo://agente?de=claude&fase=espera&proyecto=dilo-mac"))
    let (actividad, contenido) = try #require(muesca.sentados["agente.claude.dilo-mac"])
    #expect(actividad.prioridad == .alta)
    #expect(!actividad.puedeSerPrincipal)
    #expect(contenido.texto == "Claude")
    #expect(contenido.simbolo == "hand.raised.fill")
    #expect(contenido.destacada)
    #expect(contenido.accesibilidad.contains("dilo-mac"))
  }

  /// Una URL que no se entiende no pone nada (y queda en el log).
  @Test func unaURLMalaNoPoneNada() {
    let (agentes, muesca, _) = armar()
    agentes.abrir(url("dilo://agente?de=claude&fase=pensando"))
    agentes.abrir(url("dilo://dictar"))
    #expect(muesca.sentados.isEmpty)
  }

  @Test func trabajarEsBajoYNoSeDestaca() throws {
    let (agentes, muesca, _) = armar()
    agentes.abrir(url("dilo://agente?de=codex&fase=trabajando&proyecto=web"))
    let (actividad, contenido) = try #require(muesca.sentados["agente.codex.web"])
    #expect(actividad.prioridad == .baja)
    #expect(!contenido.destacada)
  }

  /// Cada herramienta que corre Claude avisa «trabajando» otra vez: el
  /// segmento no se vuelve a publicar por eso.
  @Test func laMismaFaseNoVuelveAPublicar() {
    let (agentes, muesca, _) = armar()
    agentes.abrir(url("dilo://agente?de=claude&fase=trabajando&proyecto=a"))
    agentes.abrir(url("dilo://agente?de=claude&fase=trabajando&proyecto=a"))
    #expect(muesca.publicaciones == 1)
  }

  @Test func finYElClicLoQuitan() {
    let (agentes, muesca, _) = armar()
    agentes.abrir(url("dilo://agente?de=claude&fase=espera&proyecto=a"))
    agentes.abrir(url("dilo://agente?de=claude&fase=fin&proyecto=a"))
    #expect(muesca.sentados.isEmpty)

    agentes.abrir(url("dilo://agente?de=claude&fase=espera&proyecto=b"))
    agentes.tocar(id: "agente.claude.b")
    #expect(muesca.sentados.isEmpty)
  }

  @Test func listoSeVaSolo() {
    let (agentes, muesca, _) = armar()
    var ahora = Date(timeIntervalSince1970: 1_800_000_000)
    agentes.ahora = { ahora }
    agentes.abrir(url("dilo://agente?de=claude&fase=listo&proyecto=a"))
    ahora += RegistroDeAgentes.duracionDeListo - 1
    agentes.limpiar()
    #expect(muesca.sentados.count == 1)
    ahora += 1
    agentes.limpiar()
    #expect(muesca.sentados.isEmpty)
  }

  @Test func apagadosNoMuestranNada() {
    let ajustes = AppSettings(defaults: UserDefaults(suiteName: "agentes-\(UUID())")!)
    ajustes.hudAgentes = false
    let (agentes, muesca, _) = armar(ajustes)
    agentes.abrir(url("dilo://agente?de=claude&fase=espera&proyecto=a"))
    agentes.probar()
    #expect(muesca.sentados.isEmpty)
  }

  /// Apagarlos en Ajustes retira lo que había.
  @Test func apagarlosRetiraLoQueHabia() async {
    let (agentes, muesca, ajustes) = armar()
    agentes.abrir(url("dilo://agente?de=claude&fase=espera&proyecto=a"))
    #expect(muesca.sentados.count == 1)
    ajustes.hudAgentes = false
    for _ in 0..<50 where !muesca.sentados.isEmpty { await Task.yield() }
    #expect(muesca.sentados.isEmpty)
  }

  @Test func probarPoneAClaudeEsperando() {
    let (agentes, muesca, _) = armar()
    agentes.probar()
    #expect(muesca.sentados.values.first?.1.simbolo == "hand.raised.fill")
  }

  /// Los segmentos de afuera nunca piden la forma, aunque quien publique se
  /// equivoque.
  @Test func elEscenarioNoLesDaLaForma() {
    let stage = HUDStage(settings: AppSettings.previewStore(), punteroEn: { .zero })
    let pide = ActividadDeLaMuesca(id: "agente.claude.x", prioridad: .alta, exigeElPrincipal: true)
    let contenido = ContenidoDelSegmento(id: pide.id, simbolo: "bell", texto: "Claude", destacada: true, accesibilidad: "")
    stage.publicarDeAfuera(pide, contenido: contenido)
    #expect(stage.asientos.principal == nil)
    #expect(stage.asientos.asiento(de: pide.id) != .principal)
    stage.retirarDeAfuera(id: pide.id)
    #expect(stage.segmentosDeAfuera.isEmpty)
  }
}

import Foundation
import Testing

@testable import DiloPlataforma

/// El URL scheme `dilo://`: qué se entiende, qué se rechaza y por qué. Lo
/// que llega por acá lo puede escribir cualquiera, así que lo que importa
/// tanto como leer bien es no leer de más.
@Suite("Enlaces dilo://")
struct EnlaceDeDiloTests {
  private func leer(_ texto: String) -> Result<EnlaceDeDilo, EnlaceDeDilo.Rechazo> {
    EnlaceDeDilo.leer(URL(string: texto)!)
  }

  private func evento(_ texto: String) -> EventoDeAgente? {
    guard case let .success(.agente(evento)) = leer(texto) else { return nil }
    return evento
  }

  @Test func leeLaLineaDelPlan() {
    let e = evento("dilo://agente?de=claude&fase=espera&proyecto=dilo-mac")
    #expect(e == EventoDeAgente(agente: .claude, fase: .espera, proyecto: "dilo-mac"))
  }

  @Test(arguments: EventoDeAgente.Fase.allCases)
  func cadaFaseSeLee(_ fase: EventoDeAgente.Fase) {
    #expect(evento("dilo://agente?de=codex&fase=\(fase.rawValue)&proyecto=x")?.fase == fase)
  }

  /// Escrito a mano en una terminal, nadie se acuerda de las mayúsculas ni
  /// de si van dos barras.
  @Test func mayusculasYLaFormaSinBarrasDanLoMismo() {
    let esperado = EventoDeAgente(agente: .claude, fase: .listo, proyecto: "dilo")
    #expect(evento("DILO://Agente?De=Claude&Fase=LISTO&proyecto=dilo") == esperado)
    #expect(evento("dilo:agente?de=claude&fase=listo&proyecto=dilo") == esperado)
    #expect(evento("dilo://agente/?de=claude&fase=listo&proyecto=dilo") == esperado)
  }

  /// Una herramienta que Dilo no nombra igual se ve, como «Agente».
  @Test func unAgenteDesconocidoEsAgente() {
    let e = evento("dilo://agente?de=gemini&fase=trabajando&proyecto=web")
    #expect(e?.agente == .otro)
    #expect(e?.agente.nombre == "Agente")
    #expect(evento("dilo://agente?fase=trabajando")?.agente == .otro)
  }

  @Test func sinProyectoQuedaVacio() {
    #expect(evento("dilo://agente?de=claude&fase=espera")?.proyecto == "")
  }

  @Test func unaFaseDesconocidaSeRechazaConSuNombre() {
    #expect(leer("dilo://agente?de=claude&fase=pensando") == .failure(.faseDesconocida("pensando")))
    #expect(leer("dilo://agente?de=claude") == .failure(.faseDesconocida(nil)))
  }

  /// Lo que abre el micrófono o toca el portapapeles no entra por una URL
  /// que cualquier página puede abrir: va por App Intents.
  @Test(arguments: ["dictar", "nota", "copiar", "modo", "muesca"])
  func lasAccionesNoEntranPorURL(_ ruta: String) {
    #expect(leer("dilo://\(ruta)?modo=correo") == .failure(.rutaDesconocida(ruta)))
  }

  @Test func otroEsquemaNoEsDeDilo() {
    #expect(leer("https://agente?de=claude&fase=espera") == .failure(.otroEsquema))
  }

  @Test func unaURLEnormeNoSeLee() {
    let largo = String(repeating: "a", count: EnlaceDeDilo.largoMaximo)
    #expect(leer("dilo://agente?de=claude&fase=espera&proyecto=\(largo)") == .failure(.demasiadoLarga))
  }

  /// Lo que el script codifica byte a byte vuelve entero.
  @Test func elProyectoLlegaDecodificado() {
    let e = evento("dilo://agente?de=claude&fase=espera&proyecto=Mi%20caf%c3%a9%20%26%20co")
    #expect(e?.proyecto == "Mi café co")
  }

  @Test func elProyectoSeLimpiaAntesDeDibujarse() {
    let e = evento("dilo://agente?de=claude&fase=espera&proyecto=%3Cscript%3E%0Aalerta%E2%80%AE")
    #expect(e?.proyecto == "scriptalerta")
  }
}

@Suite("Evento de un agente")
struct EventoDeAgenteTests {
  @Test func limpiarDejaLetrasNumerosYSeparadores() {
    #expect(EventoDeAgente.limpiar("dilo-mac_2.0 beta") == "dilo-mac_2.0 beta")
    #expect(EventoDeAgente.limpiar("  a\nb\t<c>\"d\"  ") == "abcd")
    #expect(EventoDeAgente.limpiar("Diseño 🚀") == "Diseño")
  }

  /// El Finder escribe «café» como «e» más el acento suelto.
  @Test func unaTildeDescompuestaNoSePierde() {
    #expect(EventoDeAgente.limpiar("cafe\u{301}") == "café")
  }

  @Test func elNombreTieneTope() {
    let largo = String(repeating: "x", count: 80)
    #expect(EventoDeAgente.limpiar(largo).count == EventoDeAgente.largoMaximoDelProyecto)
  }

  @Test func soloEsperarSubeDePrioridad() {
    #expect(EventoDeAgente.Fase.espera.urgencia == .alta)
    #expect(EventoDeAgente.Fase.listo.urgencia == .normal)
    #expect(EventoDeAgente.Fase.error.urgencia == .normal)
    #expect(EventoDeAgente.Fase.trabajando.urgencia == .baja)
  }
}

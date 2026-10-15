import Foundation
import Testing

@testable import DiloPlataforma

/// Quién está vivo entre los agentes que avisan. Puro: cada test lleva su
/// hora y nada espera de verdad.
@Suite("Registro de agentes")
struct RegistroDeAgentesTests {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private func ev(_ fase: EventoDeAgente.Fase, _ agente: EventoDeAgente.Agente = .claude, _ proyecto: String = "dilo")
    -> EventoDeAgente
  {
    EventoDeAgente(agente: agente, fase: fase, proyecto: proyecto)
  }

  private func ids(_ cambios: [RegistroDeAgentes.Cambio]) -> [String] {
    cambios.map {
      switch $0 {
      case let .publicar(sesion): "+\(sesion.id)"
      case let .retirar(id): "-\(id)"
      }
    }
  }

  @Test func unAvisoPublicaLaSesion() {
    var r = RegistroDeAgentes()
    let cambios = r.recibir(ev(.trabajando), ahora: t0)
    #expect(ids(cambios) == ["+agente.claude.dilo"])
    #expect(r.sesiones["agente.claude.dilo"]?.fase == .trabajando)
  }

  @Test func finRetira() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.espera), ahora: t0)
    #expect(ids(r.recibir(ev(.fin), ahora: t0)) == ["-agente.claude.dilo"])
    #expect(r.sesiones.isEmpty)
  }

  /// Un fin de una sesión que no se conoce no mueve nada.
  @Test func finDeUnaDesconocidaNoHaceNada() {
    var r = RegistroDeAgentes()
    #expect(r.recibir(ev(.fin), ahora: t0).isEmpty)
  }

  /// Con `PostToolUse` cada herramienta avisa «trabajando»: repetir la fase
  /// sólo estira el plazo, no vuelve a sentar el segmento.
  @Test func laMismaFaseNoVuelveAPublicar() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.trabajando), ahora: t0)
    #expect(r.recibir(ev(.trabajando), ahora: t0 + 60).isEmpty)
    #expect(r.sesiones["agente.claude.dilo"]?.ultimaNoticia == t0 + 60)
  }

  @Test func cambiarDeFaseVuelveAPublicar() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.trabajando), ahora: t0)
    let cambios = r.recibir(ev(.espera), ahora: t0 + 5)
    #expect(ids(cambios) == ["+agente.claude.dilo"])
    guard case let .publicar(sesion) = cambios.first else { Issue.record(); return }
    #expect(sesion.fase == .espera)
  }

  @Test func dosProyectosDelMismoAgenteSonDos() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.trabajando, .claude, "dilo"), ahora: t0)
    _ = r.recibir(ev(.trabajando, .claude, "web"), ahora: t0)
    _ = r.recibir(ev(.trabajando, .codex, "dilo"), ahora: t0)
    #expect(r.sesiones.count == 3)
  }

  @Test func listoSeVaALosTreintaSegundos() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.listo), ahora: t0)
    #expect(r.limpiar(ahora: t0 + 29).isEmpty)
    #expect(ids(r.limpiar(ahora: t0 + RegistroDeAgentes.duracionDeListo)) == ["-agente.claude.dilo"])
  }

  @Test func unErrorDuraMasQueUnListo() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.error), ahora: t0)
    #expect(r.limpiar(ahora: t0 + RegistroDeAgentes.duracionDeListo + 1).isEmpty)
    #expect(!r.limpiar(ahora: t0 + RegistroDeAgentes.duracionDeError).isEmpty)
  }

  /// Se cerró la terminal y el fin nunca llegó.
  @Test func sinNoticiasSeOlvida() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.espera), ahora: t0)
    #expect(r.limpiar(ahora: t0 + RegistroDeAgentes.olvido - 1).isEmpty)
    #expect(ids(r.limpiar(ahora: t0 + RegistroDeAgentes.olvido)) == ["-agente.claude.dilo"])
  }

  /// La app duerme hasta el próximo vencimiento en vez de sondear.
  @Test func proximoVencimientoEsElMasCercano() {
    var r = RegistroDeAgentes()
    #expect(r.proximoVencimiento == nil)
    _ = r.recibir(ev(.trabajando, .claude, "a"), ahora: t0)
    _ = r.recibir(ev(.listo, .codex, "b"), ahora: t0 + 10)
    #expect(r.proximoVencimiento == t0 + 10 + RegistroDeAgentes.duracionDeListo)
  }

  @Test func descartarLaQuitaHastaQueVuelvaAAvisar() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.espera), ahora: t0)
    #expect(ids(r.descartar(id: "agente.claude.dilo")) == ["-agente.claude.dilo"])
    #expect(r.descartar(id: "agente.claude.dilo").isEmpty)
    #expect(ids(r.recibir(ev(.espera), ahora: t0 + 1)) == ["+agente.claude.dilo"])
  }

  /// Una página que abre `dilo://` en bucle con proyectos inventados no
  /// llena la memoria: la más vieja se va.
  @Test func conElTopeSeVaLaMasVieja() {
    var r = RegistroDeAgentes()
    for i in 0..<RegistroDeAgentes.maximoDeSesiones {
      _ = r.recibir(ev(.trabajando, .claude, "p\(i)"), ahora: t0 + Double(i))
    }
    let cambios = r.recibir(ev(.trabajando, .claude, "nuevo"), ahora: t0 + 100)
    #expect(ids(cambios) == ["-agente.claude.p0", "+agente.claude.nuevo"])
    #expect(r.sesiones.count == RegistroDeAgentes.maximoDeSesiones)
  }

  @Test func vaciarLasRetiraTodas() {
    var r = RegistroDeAgentes()
    _ = r.recibir(ev(.espera, .claude, "b"), ahora: t0)
    _ = r.recibir(ev(.espera, .claude, "a"), ahora: t0)
    #expect(ids(r.vaciar()) == ["-agente.claude.a", "-agente.claude.b"])
    #expect(r.sesiones.isEmpty)
  }
}

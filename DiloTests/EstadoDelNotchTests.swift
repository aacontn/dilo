import Foundation
import Testing

@testable import Dilo

/// El contrato del notch como máquina: las cinco transiciones, sus tiempos y
/// las dos reglas que no se negocian —reposo no captura y reposo no anima—.
///
/// Todo puro: ni ventana, ni micrófono, ni GUI. El tiempo entra por
/// `DeadlineClock` y lo adelanta el test, siguiendo el precedente de #82 —
/// contra el reloj de pared esto afirmaría que el runner fue rápido.
@Suite("Contrato del notch")
struct EstadoDelNotchTests {
  // MARK: Las reglas que valen para los cinco estados

  /// La primera línea del contrato: **reposo no escucha**. Sólo dictando
  /// tiene el micrófono abierto.
  @Test func soloDictandoCaptura() {
    #expect(EstadoDelNotch.dictando.captura)
    #expect(!EstadoDelNotch.reposo.captura)
    #expect(!EstadoDelNotch.preparando(.cargandoModelo).captura)
    #expect(!EstadoDelNotch.procesando.captura)
    #expect(!EstadoDelNotch.resultado(.listo).captura)
  }

  /// El reposo del spec §3 (~0 % de CPU) depende de que nada se mueva solo
  /// mientras nadie dicta: ningún `TimelineView`, ningún shader.
  @Test func enReposoNadaAnima() {
    #expect(!EstadoDelNotch.reposo.anima)
    // Preparando tampoco: el contrato prohíbe la onda ficticia mientras se
    // espera un modelo o un permiso.
    #expect(!EstadoDelNotch.preparando(.cargandoModelo).anima)
    #expect(!EstadoDelNotch.resultado(.listo).anima)
    #expect(EstadoDelNotch.dictando.anima)
    #expect(EstadoDelNotch.procesando.anima)
  }

  /// La forma toma el mouse donde hace algo con él: abrir el menú en reposo,
  /// copiar en resultado. Mientras se dicta, el clic es del documento.
  @Test func soloReposoYResultadoTomanElMouse() {
    #expect(EstadoDelNotch.reposo.tomaElMouse)
    #expect(EstadoDelNotch.resultado(.copiado).tomaElMouse)
    #expect(!EstadoDelNotch.dictando.tomaElMouse)
    #expect(!EstadoDelNotch.procesando.tomaElMouse)
    #expect(!EstadoDelNotch.preparando(.permisoDeMicrofono).tomaElMouse)
  }

  /// Preparando dice qué falta, con palabras; procesando y resultado también.
  /// Dictando no: ahí lo que se lee es el texto parcial.
  ///
  /// Sin comparar contra el copy en español: la suite corre con el idioma de
  /// la máquina, y afirmar la traducción sería probar el catálogo, no el
  /// contrato. Lo que importa es que cada estado tenga su línea, que sean
  /// distintas entre sí, y que un aviso pase su texto tal cual.
  @Test func cadaEstadoDiceLoSuyo() {
    #expect(EstadoDelNotch.preparando(.cargandoModelo).texto == FaltaDelNotch.cargandoModelo.texto)
    #expect(EstadoDelNotch.preparando(.aviso("Bajando es-CL, 40 %")).texto == "Bajando es-CL, 40 %")
    #expect(EstadoDelNotch.resultado(.listo).texto == ResultadoDelNotch.listo.texto)
    #expect(EstadoDelNotch.resultado(.copiado).texto == ResultadoDelNotch.copiado.texto)
    #expect(ResultadoDelNotch.listo.texto != ResultadoDelNotch.copiado.texto)
    #expect(!ResultadoDelNotch.listo.texto.isEmpty)
    #expect(!FaltaDelNotch.cargandoModelo.texto.isEmpty)
    #expect(EstadoDelNotch.procesando.texto?.isEmpty == false)
    // Dictando no dice nada: ahí lo que se lee es el texto parcial.
    #expect(EstadoDelNotch.dictando.texto == nil)
    #expect(EstadoDelNotch.reposo.texto == nil)
  }

  /// Un aviso no ofrece copiar: no hay nada que copiar en «No se pudo pegar
  /// el texto».
  @Test func soloLoEntregadoOfreceCopiar() {
    #expect(ResultadoDelNotch.listo.ofreceCopiar)
    #expect(ResultadoDelNotch.copiado.ofreceCopiar)
    #expect(!ResultadoDelNotch.aviso("No se pudo pegar el texto").ofreceCopiar)
  }

  // MARK: Las transiciones

  @Test func elRecorridoCompletoVuelveAReposo() {
    var maquina = MaquinaDelNotch()
    #expect(maquina.estado == .reposo)

    _ = maquina.recibir(.preparar(.cargandoModelo))
    #expect(maquina.estado == .preparando(.cargandoModelo))

    _ = maquina.recibir(.escuchar)
    #expect(maquina.estado == .dictando)

    _ = maquina.recibir(.procesar)
    #expect(maquina.estado == .procesando)

    let efectos = maquina.recibir(.entregar(.listo))
    #expect(maquina.estado == .resultado(.listo))
    #expect(
      efectos == [
        .programarVueltaAReposo(MaquinaDelNotch.duracionDelResultado, turno: 1)
      ]
    )

    _ = maquina.recibir(.expiroElResultado(turno: 1))
    #expect(maquina.estado == .reposo)
  }

  /// Desde reposo no se procesa nada: un evento perdido de una sesión que ya
  /// terminó dejaría la forma abierta diciendo que trabaja sin nada que hacer.
  @Test func desdeReposoNoSeProcesa() {
    var maquina = MaquinaDelNotch()
    #expect(maquina.recibir(.procesar).isEmpty)
    #expect(maquina.estado == .reposo)
  }

  /// Cancelar vuelve a reposo desde donde sea, y apaga el temporizador.
  @Test func cancelarVuelveAReposoDesdeDondeSea() {
    for evento in [
      MaquinaDelNotch.Evento.escuchar,
      .preparar(.permisoDeMicrofono),
      .entregar(.copiado),
    ] {
      var maquina = MaquinaDelNotch()
      _ = maquina.recibir(evento)
      let efectos = maquina.recibir(.cancelar)
      #expect(maquina.estado == .reposo)
      #expect(efectos == [.cancelarVuelta])
    }
  }

  /// Un vencimiento viejo no baja un resultado nuevo. Es el caso de dictar
  /// dos veces seguidas rápido: el temporizador del primero llega cuando el
  /// segundo ya está en pantalla.
  @Test func unVencimientoViejoNoBajaUnResultadoNuevo() {
    var maquina = MaquinaDelNotch()
    _ = maquina.recibir(.entregar(.listo))
    _ = maquina.recibir(.entregar(.copiado))
    #expect(maquina.turnoDelResultado == 2)

    _ = maquina.recibir(.expiroElResultado(turno: 1))
    #expect(maquina.estado == .resultado(.copiado))

    _ = maquina.recibir(.expiroElResultado(turno: 2))
    #expect(maquina.estado == .reposo)
  }

  /// Y tampoco cierra una sesión que ya empezó de nuevo.
  @Test func unVencimientoNoCierraLaSesionSiguiente() {
    var maquina = MaquinaDelNotch()
    _ = maquina.recibir(.entregar(.listo))
    _ = maquina.recibir(.escuchar)
    _ = maquina.recibir(.expiroElResultado(turno: 1))
    #expect(maquina.estado == .dictando)
  }

  // MARK: Los tiempos

  /// El resultado se va solo, y se va cuando se cumple el plazo — ni antes.
  @MainActor
  @Test func elResultadoVuelveAReposoCuandoSeCumpleElPlazo() async {
    let reloj = DrivenClock()
    let control = ControlDelNotch(reloj: reloj.deadlineClock)
    var vistos: [EstadoDelNotch] = []
    control.alCambiar = { _, nuevo in vistos.append(nuevo) }

    control.recibir(.escuchar)
    control.recibir(.entregar(.listo))
    #expect(control.estado == .resultado(.listo))

    await reloj.waitForSleeper()
    reloj.advance(by: MaquinaDelNotch.duracionDelResultado - .milliseconds(1))
    await Task.yield()
    #expect(control.estado == .resultado(.listo), "se fue antes de tiempo")

    reloj.advance(by: .milliseconds(1))
    while control.estado != .reposo {
      await Task.yield()
    }
    #expect(vistos == [.dictando, .resultado(.listo), .reposo])
  }

  /// Una sesión nueva antes del vencimiento se lleva el temporizador puesto:
  /// el resultado viejo no puede bajar la forma a media frase.
  @MainActor
  @Test func unaSesionNuevaCancelaElPlazoDelResultado() async {
    let reloj = DrivenClock()
    let control = ControlDelNotch(reloj: reloj.deadlineClock)

    control.recibir(.entregar(.listo))
    await reloj.waitForSleeper()
    control.recibir(.escuchar)
    reloj.advance(by: MaquinaDelNotch.duracionDelResultado * 4)
    await Task.yield()
    await Task.yield()

    #expect(control.estado == .dictando)
  }
}

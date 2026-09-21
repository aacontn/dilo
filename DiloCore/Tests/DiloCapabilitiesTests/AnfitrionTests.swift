import ApplicationServices
import Foundation
import Testing

@testable import DiloCapabilities

struct DeteccionDelAnfitrionTests {
  @Test func sinContenedorElAnfitrionEsElCompleto() {
    let anfitrion = Anfitrion.resolver(entorno: [:], lector: LectorEspia())
    #expect(anfitrion is FullHost)
    #expect(anfitrion.nombre == "completo")
  }

  /// La variable la pone el propio sandbox, así que su sola presencia es la
  /// señal: el mismo binario dentro de un contenedor se comporta como lo que
  /// es, sin depender de con qué bandera se compiló.
  @Test func conContenedorElAnfitrionEsElDeSandbox() {
    let anfitrion = Anfitrion.resolver(
      entorno: [Anfitrion.variableDeSandbox: "ABCDE12345.cl.espaciodigital.dilo.mas"],
      lector: LectorEspia()
    )
    #expect(anfitrion is SandboxedHost)
    #expect(anfitrion.nombre == "sandbox")
  }
}

struct CapacidadesTests {
  @Test func elAnfitrionCompletoNoEsconderNada() {
    let completo = FullHost(lector: LectorEspia())
    for capacidad in Capacidad.allCases {
      #expect(completo.admite(capacidad), "el target directo debería poder \(capacidad)")
    }
  }

  /// Lo que el sandbox conserva es exactamente lo que se midió el
  /// 2026-09-20: el portapapeles con Cmd+V, el tap del gatillo y el tap de
  /// audio del sistema. Todo lo que exige leer dentro de otra app, no.
  @Test func elSandboxConservaLoQueSeMidio() {
    let sandbox = SandboxedHost(lector: LectorEspia())
    #expect(sandbox.admite(.pegadoDirecto))
    #expect(sandbox.admite(.atajoGlobal))
    #expect(sandbox.admite(.tapDeAudioDelSistema))
  }

  @Test func elSandboxEscondeLoQueNoPuedeHacer() {
    let sandbox = SandboxedHost(lector: LectorEspia())
    #expect(!sandbox.admite(.focoAntesDePegar))
    #expect(!sandbox.admite(.relecturaDelFoco))
    #expect(!sandbox.admite(.tituloDeVentanaActiva))
    #expect(!sandbox.admite(.arrastreDeArchivosAlNotch))
  }
}

struct PegadoEnSandboxTests {
  /// El contrato de la Tarea 2, comprobado en vez de prometido: en sandbox el
  /// dictado aterriza con portapapeles y Cmd+V, y para llegar ahí no se toca
  /// la API de Accesibilidad ni una vez. El espía lo firma.
  @Test func elPegadoEnSandboxNoTocaAccesibilidad() {
    let espia = LectorEspia(atributos: [
      kAXSubroleAttribute as String: kAXSecureTextFieldSubrole as String
    ])
    let sandbox = SandboxedHost(lector: espia)

    // Los tres momentos en que el pegado le pregunta al anfitrión: capturar
    // el foco, mirar si el destino es un campo de contraseña y revalidarlo
    // justo antes del Cmd+V.
    #expect(sandbox.elementoEnfocado() == nil)
    #expect(sandbox.esCampoSeguro(LectorEspia.elementoPropio) == false)
    _ = sandbox.sigueSiendoElFoco(
      elemento: nil,
      pid: ProcessInfo.processInfo.processIdentifier
    )

    #expect(
      espia.llamadas.isEmpty,
      "el sandbox llamó a Accesibilidad: \(espia.llamadas)"
    )
    // Y sin embargo pega: lo que se pierde es la puntería, no el dictado.
    #expect(sandbox.admite(.pegadoDirecto))
    #expect(!sandbox.admite(.focoAntesDePegar))
  }

  /// La otra mitad del mismo contrato: el anfitrión completo sí pregunta.
  /// Si un día alguien vacía `FullHost` "para que pase el test", falla acá.
  @Test func elAnfitrionCompletoSiPreguntaPorElFoco() {
    let espia = LectorEspia()
    let completo = FullHost(lector: espia)

    _ = completo.elementoEnfocado()

    #expect(espia.llamadas.contains("elementoDelSistema"))
    #expect(espia.llamadas.contains("atributo:\(kAXFocusedUIElementAttribute as String)"))
  }

  @Test func elAnfitrionCompletoReconoceUnCampoDeContrasena() {
    let seguro = FullHost(lector: LectorEspia(atributos: [
      kAXSubroleAttribute as String: kAXSecureTextFieldSubrole as String,
    ]))
    let comun = FullHost(lector: LectorEspia(atributos: [
      kAXSubroleAttribute as String: kAXStandardWindowSubrole as String
    ]))

    #expect(seguro.esCampoSeguro(LectorEspia.elementoPropio))
    #expect(!comun.esCampoSeguro(LectorEspia.elementoPropio))
  }
}

struct RelecturaDelFocoTests {
  @Test func enSandboxNoHayNadaQueReleer() {
    let espia = LectorEspia(atributos: [
      kAXSelectedTextAttribute as String: "esto no se debería leer"
    ])
    let sandbox = SandboxedHost(lector: espia)

    #expect(sandbox.focoParaLeer() == nil)
    #expect(sandbox.tituloDeVentanaActiva() == nil)
    #expect(espia.llamadas.isEmpty)
  }

  @Test func elAnfitrionCompletoDevuelveLaSeleccion() {
    let completo = FullHost(lector: LectorEspia(
      atributos: [
        kAXSubroleAttribute as String: kAXStandardWindowSubrole as String,
        kAXSelectedTextAttribute as String: "hola",
      ],
      atributosDeElemento: [kAXFocusedUIElementAttribute as String]
    ))

    #expect(completo.focoParaLeer()?.textoSeleccionado == "hola")
    #expect(completo.focoParaLeer()?.subrol == kAXStandardWindowSubrole as String)
  }
}

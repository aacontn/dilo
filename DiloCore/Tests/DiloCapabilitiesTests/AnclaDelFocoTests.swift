import ApplicationServices
import Foundation
import Testing

@testable import DiloCapabilities

struct CampoEditableTests {
  private func esEditable(
    atributos: [String: String] = [:],
    booleanos: [String: Bool] = [:]
  ) -> Bool {
    LecturaDelCampo(lector: LectorEspia(atributos: atributos, booleanos: booleanos))
      .esEditable(LectorEspia.elementoPropio)
  }

  @Test func unCampoDeTextoComunEsEditable() {
    #expect(esEditable(atributos: [kAXRoleAttribute: kAXTextAreaRole]))
    #expect(esEditable(atributos: [kAXRoleAttribute: kAXTextFieldRole]))
  }

  /// Una consulta que la app no entiende no es una negativa: un editor web
  /// con un rol raro sigue recibiendo el dictado.
  @Test func loQueNoSeSabeNoSeNiega() {
    #expect(esEditable())
    #expect(esEditable(atributos: [kAXRoleAttribute: "AXWebArea"]))
  }

  @Test func unaContrasenaNoEsDondeSePega() {
    #expect(!esEditable(atributos: [kAXSubroleAttribute: kAXSecureTextFieldSubrole]))
    #expect(!esEditable(atributos: [kAXRoleAttribute: "AXSecureTextField"]))
    #expect(!esEditable(booleanos: ["AXProtected": true]))
  }

  @Test func loDeshabilitadoOSoloLecturaTampoco() {
    #expect(!esEditable(booleanos: [kAXEnabledAttribute: false]))
    #expect(!esEditable(booleanos: ["AXReadOnly": true]))
    #expect(!esEditable(booleanos: ["AXEditable": false]))
    #expect(esEditable(booleanos: [kAXEnabledAttribute: true, "AXReadOnly": false]))
  }

  /// Sin cursor que leer no hay ancla: comparar un foco sin selección
  /// confundiría «la app no lo dice» con «se movió».
  @Test func sinSeleccionNoHayAncla() {
    let lector = LectorEspia(
      atributos: [kAXRoleAttribute: kAXTextAreaRole],
      atributosDeElemento: [kAXFocusedUIElementAttribute]
    )
    #expect(LecturaDelCampo(lector: lector).ancla(en: 501) == nil)
  }

  @Test func sinFocoNoHayAncla() {
    #expect(LecturaDelCampo(lector: LectorEspia()).ancla(en: 501) == nil)
    #expect(LecturaDelCampo(lector: LectorEspia()).ancla(en: 0) == nil)
  }

  /// Lo que la foto no puede leer queda en nil, nunca en «vacío».
  @Test func laFotoDeUnCampoMudoNoEsLegible() {
    let ancla = AnclaDelFoco(
      pid: 501, elemento: LectorEspia.elementoPropio, seleccion: nil, marcador: nil)
    #expect(!LecturaDelCampo(lector: LectorEspia()).foto(de: ancla).esLegible)
  }

  @Test func laFotoLeeElValorYLoCuenta() {
    let ancla = AnclaDelFoco(
      pid: 501, elemento: LectorEspia.elementoPropio, seleccion: nil, marcador: nil)
    let lector = LectorEspia(atributos: [kAXValueAttribute: "hola qué tal"])
    let foto = LecturaDelCampo(lector: lector).foto(de: ancla)
    #expect(foto.valor == "hola qué tal")
    #expect(foto.conteo == 12)
  }
}

struct AnclaEnSandboxTests {
  /// En sandbox no hay ancla, ni comparación, ni foto, y para saberlo no se
  /// le pregunta nada a Accesibilidad.
  @Test func elSandboxNoPreguntaPorElCampo() {
    let espia = LectorEspia(
      atributos: [kAXRoleAttribute: kAXTextAreaRole],
      atributosDeElemento: [kAXFocusedUIElementAttribute]
    )
    let sandbox = SandboxedHost(lector: espia)
    let ancla = AnclaDelFoco(
      pid: 501, elemento: LectorEspia.elementoPropio, seleccion: nil, marcador: nil)

    #expect(sandbox.anclaDelFoco(en: 501) == nil)
    #expect(!sandbox.anclaSigueIgual(ancla))
    #expect(!sandbox.fotoDelCampo(ancla).esLegible)
    #expect(espia.llamadas.isEmpty, "el sandbox llamó a Accesibilidad: \(espia.llamadas)")
  }

  /// El completo sí le pregunta a la app, con espera acotada.
  @Test func elCompletoPreguntaConEspera() {
    let espia = LectorEspia(atributosDeElemento: [kAXFocusedUIElementAttribute])
    _ = FullHost(lector: espia, pidAlFrente: { 501 }).anclaDelFoco(en: 501)
    #expect(espia.llamadas.contains("elementoDeLaApp"))
    #expect(espia.llamadas.contains("fijarEspera"))
  }
}

struct TecleoDelDictadoTests {
  @Test func elTextoSeCortaEnPedazosDeDieciseis() {
    let pedazos = TecleoDelDictado.pedazos(de: "uno dos tres cuatro cinco")
    #expect(pedazos == [.texto("uno dos tres cua"), .texto("tro cinco")])
  }

  /// Un emoji de dos unidades no se parte en la costura.
  @Test func unEmojiNoSeParte() {
    let pedazos = TecleoDelDictado.pedazos(de: "aaaaaaaaaaaaaaa😀b")
    #expect(pedazos == [.texto("aaaaaaaaaaaaaaa"), .texto("😀b")])
  }

  /// Los saltos van aparte, como ⇧↩, para que un chat no mande el mensaje a
  /// medio dictar. «\r\n» es uno solo.
  @Test func losSaltosVanAparte() {
    #expect(TecleoDelDictado.pedazos(de: "hola\nchao") == [.texto("hola"), .saltoDeLinea, .texto("chao")])
    #expect(TecleoDelDictado.pedazos(de: "a\r\nb") == [.texto("a"), .saltoDeLinea, .texto("b")])
    #expect(TecleoDelDictado.pedazos(de: "\n\n") == [.saltoDeLinea, .saltoDeLinea])
  }

  @Test func nadaQueTeclearEsNingunPedazo() {
    #expect(TecleoDelDictado.pedazos(de: "").isEmpty)
  }
}

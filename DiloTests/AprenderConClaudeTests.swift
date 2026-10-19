import DiloModes
import DiloText
import Foundation
import Testing
import os

@testable import Dilo

@MainActor
private func aguardar(_ comentario: Comment, _ condicion: @MainActor () -> Bool) async {
  let limite = ContinuousClock.now + .seconds(10)
  while ContinuousClock.now < limite {
    if condicion() { return }
    try? await Task.sleep(for: .milliseconds(2))
  }
  if condicion() { return }
  Issue.record(comentario)
}

@MainActor
private func ajustesNuevos() -> AppSettings {
  let nombre = "AprenderConClaudeTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: nombre)!
  defaults.removePersistentDomain(forName: nombre)
  return AppSettings(defaults: defaults)
}

/// Lo que recibió el revisor de mentira. Ningún test toca la red ni el
/// Llavero: el revisor y el viaje del orden se inyectan.
private final class Recibido: Sendable {
  private let estado = OSAllocatedUnfairLock<[[CandidatoParaRevisar]]>(initialState: [])
  func anotar(_ c: [CandidatoParaRevisar]) { estado.withLock { $0.append(c) } }
  var todo: [[CandidatoParaRevisar]] { estado.withLock { $0 } }
}

@MainActor
struct RevisorEnLasCorreccionesTests {
  private let kubernetes = ParDeCorreccion(oido: "cuba netes", correcto: "Kubernetes")
  private let posthog = ParDeCorreccion(oido: "posthog", correcto: "PostHog")

  private func correcciones(
    _ settings: AppSettings,
    revisar: (@Sendable ([CandidatoParaRevisar], String) async -> [ParDeCorreccion: TipoDeAprendizaje]?)?
  ) -> CorreccionesDelDictado {
    let c = CorreccionesDelDictado(settings: settings)
    c.esPalabraConocida = { _ in false }
    c.revisar = revisar
    return c
  }

  /// Lo que el revisor descarta no se ofrece, y no se vuelve a preguntar.
  @Test func loQueElRevisorDescartaNoSeOfrece() async {
    let ajustes = ajustesNuevos()
    let c = correcciones(ajustes) { candidatos, _ in
      Dictionary(uniqueKeysWithValues: candidatos.map { ($0.par, TipoDeAprendizaje.nada) })
    }
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    // Mientras revisa, todavía no hay oferta.
    #expect(c.oferta == nil)
    await aguardar("no terminó de revisar") { c.revision == nil }
    #expect(c.oferta == nil)
    c.revisar = { candidatos, _ in
      Dictionary(uniqueKeysWithValues: candidatos.map { ($0.par, TipoDeAprendizaje.reemplazo) })
    }
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    #expect(c.revision == nil)
    #expect(c.oferta == nil)
  }

  /// Un término que Tus palabras arregla sola no deja regla en «Cuando
  /// digo…»; aprenderlo se anota para el orden.
  @Test func unTerminoVaSoloATusPalabras() async {
    let ajustes = ajustesNuevos()
    let c = correcciones(ajustes) { candidatos, _ in
      Dictionary(uniqueKeysWithValues: candidatos.map { ($0.par, TipoDeAprendizaje.termino) })
    }
    var avisos = 0
    c.alAprender = { avisos += 1 }
    c.evaluar(pegado: "abre posthog ya", editado: "abre PostHog ya", crudo: "abre posthog ya")
    await aguardar("no ofreció") { c.oferta != nil }
    #expect(c.oferta?.pares == [posthog])
    #expect(c.oferta?.soloTusPalabras == [posthog])

    c.tocar()
    #expect(ajustes.palabrasPropias == ["PostHog"])
    #expect(ajustes.reemplazos.isEmpty)
    #expect(ajustes.palabrasAprendidas == ["PostHog"])
    #expect(ajustes.aprendidasDesdeElOrden == 1)
    #expect(avisos == 1)

    c.tocar()
    #expect(ajustes.palabrasPropias.isEmpty)
    #expect(ajustes.palabrasAprendidas.isEmpty)
    #expect(ajustes.aprendidasDesdeElOrden == 0)
  }

  /// Sin respuesta del revisor (sin clave, sin red, plazo) se ofrece lo de
  /// siempre.
  @Test func sinRevisorSeOfreceLoDeSiempre() async {
    let ajustes = ajustesNuevos()
    let c = correcciones(ajustes) { _, _ in nil }
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    await aguardar("no ofreció") { c.oferta != nil }
    #expect(c.oferta == OfertaDeAprendizaje(pares: [kubernetes]))
    c.tocar()
    #expect(ajustes.reemplazos == [Reemplazo(dice: "cuba netes", escribe: "Kubernetes", aprendido: true)])
  }

  /// Al revisor viaja el recorte y el modelo elegido, nunca el campo entero.
  @Test func alRevisorViajaSoloElRecorte() async {
    let ajustes = ajustesNuevos()
    ajustes.modeloParaRevisar = "claude-sonnet-5-5"
    let recibido = Recibido()
    let modelos = OSAllocatedUnfairLock<[String]>(initialState: [])
    let c = correcciones(ajustes) { candidatos, modelo in
      recibido.anotar(candidatos)
      modelos.withLock { $0.append(modelo) }
      return nil
    }
    let lejos = (1 ... 30).map { "secreto\($0)" }.joined(separator: " ")
    c.evaluar(
      pegado: "\(lejos) revisa cuba netes hoy \(lejos)",
      editado: "\(lejos) revisa Kubernetes hoy \(lejos)",
      crudo: "\(lejos) revisa cuba netes hoy \(lejos)"
    )
    await aguardar("no revisó") { !recibido.todo.isEmpty }
    let candidato = recibido.todo.first?.first
    #expect(candidato?.par == kubernetes)
    // Las ocho palabras de cada lado sí viajan —«secreto30» justo antes,
    // «secreto1» justo después—; las lejanas, de ningún lado.
    #expect(candidato?.antes.contains("secreto10 ") == false)
    #expect(candidato?.antes.contains("secreto20 ") == false)
    #expect((candidato?.antes.split(separator: " ").count ?? .max) <= 2 * 8 + 2)
    #expect(candidato?.despues.contains("revisa Kubernetes hoy") == true)
    #expect(modelos.withLock { $0 } == ["claude-sonnet-5-5"])
  }

  /// Con el interruptor apagado no se llama al revisor: la oferta es al
  /// tiro, como antes.
  @Test func apagadoNoRevisa() {
    let ajustes = ajustesNuevos()
    ajustes.aprenderConClaude = false
    let c = correcciones(ajustes) { _, _ in
      Issue.record("no debió revisar")
      return nil
    }
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    #expect(c.oferta == OfertaDeAprendizaje(pares: [kubernetes]))
  }

  /// Un dictado nuevo cancela la revisión: una oferta vieja no llega tarde.
  @Test func detenerCancelaLaRevision() async {
    let ajustes = ajustesNuevos()
    let c = correcciones(ajustes) { candidatos, _ in
      try? await Task.sleep(for: .milliseconds(80))
      return Dictionary(uniqueKeysWithValues: candidatos.map { ($0.par, TipoDeAprendizaje.reemplazo) })
    }
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    c.detener()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(c.oferta == nil)
  }
}

@MainActor
struct OrdenadorDelDiccionarioTests {
  private static let respuesta = """
    {"cambios":[
      {"accion":"grafia","ids":["p2"],"queda":"","nueva":"PostHog","motivo":"Así se escribe la marca."},
      {"accion":"quitar","ids":["p3"],"queda":"","nueva":"","motivo":"Palabra común."}
    ]}
    """

  private func ordenador(
    _ ajustes: AppSettings, respuesta: String = respuesta, hayClave: Bool = true
  ) -> (OrdenadorDelDiccionario, OSAllocatedUnfairLock<[String]>) {
    let llamadas = OSAllocatedUnfairLock<[String]>(initialState: [])
    let o = OrdenadorDelDiccionario(settings: ajustes)
    o.hayClave = { hayClave }
    o.pedir = { _, modelo in
      llamadas.withLock { $0.append(modelo) }
      return respuesta
    }
    return (o, llamadas)
  }

  private func conPalabras() -> AppSettings {
    let ajustes = ajustesNuevos()
    ajustes.palabrasPropias = ["Kubernetes", "Posthog", "reunión"]
    ajustes.palabrasAprendidas = ["reunión"]
    return ajustes
  }

  @Test func ordenaDeshaceYNoVuelveAProponerLoDeshecho() async throws {
    let ajustes = conPalabras()
    let (o, llamadas) = ordenador(ajustes)
    o.ordenarAhora()
    #expect(o.estado == .ordenando)
    await aguardar("no terminó") { !o.ordenando }
    #expect(o.estado == .listo(aplicados: 2, propuestos: 0))
    #expect(llamadas.withLock { $0 } == ["claude-sonnet-5-5"])
    #expect(ajustes.palabrasPropias == ["Kubernetes", "PostHog"])
    #expect(ajustes.palabrasAprendidas.isEmpty)
    #expect(ajustes.ultimaPasadaDelOrden != nil)
    #expect(ajustes.firmaDelOrden == ajustes.diccionario.firma)
    let pasada = try #require(ajustes.registroDelOrden.first)
    #expect(pasada.cambios.count == 2)
    #expect(pasada.cambios[0].motivo == "Así se escribe la marca.")

    // Deshacer la grafía devuelve la palabra a su lugar.
    o.alternar(pasada.cambios[0].id, en: pasada.id)
    #expect(ajustes.palabrasPropias == ["Kubernetes", "Posthog"])
    #expect(ajustes.registroDelOrden.first?.cambios[0].estado == .deshecho)

    // Otra pasada con la misma respuesta: lo deshecho no se vuelve a
    // proponer ni a aplicar.
    o.ordenarAhora()
    await aguardar("no terminó") { !o.ordenando }
    #expect(ajustes.palabrasPropias == ["Kubernetes", "Posthog"])
    #expect(ajustes.registroDelOrden.count == 1)
  }

  @Test func sinClaveLoDiceYNoViaja() {
    let ajustes = conPalabras()
    let (o, llamadas) = ordenador(ajustes, hayClave: false)
    o.ordenarAhora()
    #expect(o.estado == .fallo(FallaDeClaude.faltaLaClave.avisoDelOrden))
    o.revisarSiToca()
    #expect(llamadas.withLock { $0 }.isEmpty)
  }

  @Test func soloNoOrdenaDuranteUnDictadoNiApagado() {
    let ajustes = conPalabras()
    let (o, llamadas) = ordenador(ajustes)
    o.hayDictadoEnCurso = { true }
    o.revisarSiToca()
    o.ordenarAhora()
    let apagado = conPalabras()
    apagado.aprenderConClaude = false
    let (o2, llamadas2) = ordenador(apagado)
    o2.revisarSiToca()
    #expect(llamadas.withLock { $0 }.isEmpty)
    #expect(llamadas2.withLock { $0 }.isEmpty)
    o.detener()
  }

  @Test func soloOrdenaCuandoToca() async {
    let ajustes = conPalabras()
    let (o, llamadas) = ordenador(ajustes)
    o.revisarSiToca()
    await aguardar("no terminó") { !o.ordenando }
    #expect(llamadas.withLock { $0 }.count == 1)
    // Recién ordenado: no toca de nuevo.
    o.revisarSiToca()
    #expect(!o.ordenando)
    #expect(llamadas.withLock { $0 }.count == 1)
  }

  @Test func unaFallaNoTocaNada() async {
    let ajustes = conPalabras()
    let o = OrdenadorDelDiccionario(settings: ajustes)
    o.hayClave = { true }
    o.pedir = { _, _ in throw FallaDeClaude.sinConexion }
    o.ordenarAhora()
    await aguardar("no terminó") { !o.ordenando }
    #expect(o.estado == .fallo(FallaDeClaude.sinConexion.avisoDelOrden))
    #expect(ajustes.palabrasPropias == ["Kubernetes", "Posthog", "reunión"])
    #expect(ajustes.registroDelOrden.isEmpty)
    #expect(ajustes.ultimoIntentoDelOrden != nil)
    #expect(ajustes.ultimaPasadaDelOrden == nil)
  }
}

@MainActor
struct AjustesDelAprendizajeConClaudeTests {
  @Test func deFabricaPrendidoConHaikuYSonnet() {
    let ajustes = ajustesNuevos()
    #expect(ajustes.aprenderConClaude)
    #expect(ajustes.modeloParaRevisar == "claude-haiku-5-5")
    #expect(ajustes.modeloParaOrdenar == "claude-sonnet-5-5")
    #expect(ajustes.registroDelOrden.isEmpty)
  }

  @Test func seGuardaYUnModeloDesconocidoVuelveAlDeFabrica() {
    let nombre = "AjustesDelAprendizaje-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    let primera = AppSettings(defaults: defaults)
    primera.modeloParaOrdenar = "claude-opus-5-5"
    primera.aprenderConClaude = false
    defaults.set("claude-inventado-9", forKey: "diloModeloParaRevisar")
    let segunda = AppSettings(defaults: defaults)
    #expect(segunda.modeloParaOrdenar == "claude-opus-5-5")
    #expect(segunda.modeloParaRevisar == "claude-haiku-5-5")
    #expect(!segunda.aprenderConClaude)
  }

  /// El pedido que arma la app lleva el modelo, el esfuerzo y el plazo de
  /// cada uso.
  @Test func losPedidosLlevanSuModeloYSuEsfuerzo() {
    let revisar = AprendizajeConClaude.pedidoParaRevisar([], modelo: "claude-haiku-5-5")
    #expect(revisar.esfuerzo == "low")
    #expect(revisar.plazo == .seconds(7))
    #expect(revisar.sistema == RevisionDeCorrecciones.instrucciones)
    let ordenar = AprendizajeConClaude.pedidoParaOrdenar(
      Diccionario(palabras: ["a"], reemplazos: []), modelo: "claude-sonnet-5-5"
    )
    #expect(ordenar.esfuerzo == "medium")
    #expect(ordenar.modelo == "claude-sonnet-5-5")
    #expect(ordenar.peticion.contains("<p id=\"p1\""))
  }
}

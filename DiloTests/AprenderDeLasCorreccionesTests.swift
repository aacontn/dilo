import ApplicationServices
import DiloCapabilities
import DiloModes
import DiloText
import Foundation
import Testing
import os

@testable import Dilo

/// Lo que el campo va mostrando, vistazo a vistazo. El último se repite.
final class CampoGuionado: Sendable {
  private let estado: OSAllocatedUnfairLock<(valores: [String?], i: Int)>

  init(_ valores: [String?]) {
    estado = OSAllocatedUnfairLock(initialState: (valores, 0))
  }

  func leer() -> String? {
    estado.withLock { e in
      let valor = e.valores[min(e.i, e.valores.count - 1)]
      e.i += 1
      return valor
    }
  }

  var lecturas: Int { estado.withLock { $0.i } }
}

private let rapido = VigiaDeCorrecciones.Tiempos(
  cadaCuanto: .milliseconds(1), vistazos: 60, vistazosQuieto: 3, vistazosParaEncontrarLoPegado: 10
)

@MainActor
private func esperar(_ comentario: Comment, _ condicion: @MainActor () -> Bool) async {
  let limite = ContinuousClock.now + .seconds(10)
  while ContinuousClock.now < limite {
    if condicion() { return }
    try? await Task.sleep(for: .milliseconds(2))
  }
  if condicion() { return }
  Issue.record(comentario)
}

@MainActor
struct VigiaDeCorreccionesTests {
  private let pegado = "Revisa cuba netes hoy."

  @Test func esperaLaCalmaYEntregaLoPegadoEditado() async {
    let campo = CampoGuionado([
      "Hola. ", "Hola. Revisa cuba netes hoy.", "Hola. Revisa Kub", "Hola. Revisa Kubernetes hoy.",
    ])
    let vigia = VigiaDeCorrecciones(tiempos: rapido, entradaSegura: { false })
    var entregado: [String] = []
    vigia.vigilar(pegado: pegado, leerValor: { campo.leer() }) { entregado.append($0) }
    await esperar("no entregó") { !entregado.isEmpty }
    #expect(entregado == ["Revisa Kubernetes hoy."])
    await esperar("no terminó") { !vigia.estaMirando }
  }

  /// Vaciado después de tener texto: lo mandó. Vale lo último que se vio.
  @Test func unCampoVaciadoEsUnMensajeEnviado() async {
    let campo = CampoGuionado(["Revisa cuba netes hoy.", "Revisa Kubernetes hoy.", ""])
    let vigia = VigiaDeCorrecciones(tiempos: rapido, entradaSegura: { false })
    var entregado: [String] = []
    vigia.vigilar(pegado: pegado, leerValor: { campo.leer() }) { entregado.append($0) }
    await esperar("no entregó") { !entregado.isEmpty }
    #expect(entregado == ["Revisa Kubernetes hoy."])
  }

  /// Con entrada segura activa no se mira nada.
  @Test func conEntradaSeguraNoMira() async {
    let campo = CampoGuionado(["Revisa cuba netes hoy."])
    let vigia = VigiaDeCorrecciones(tiempos: rapido, entradaSegura: { true })
    var entregado: [String] = []
    vigia.vigilar(pegado: pegado, leerValor: { campo.leer() }) { entregado.append($0) }
    await esperar("no se rindió") { !vigia.estaMirando }
    #expect(campo.lecturas == 0)
    #expect(entregado.isEmpty)
  }

  /// Si lo pegado nunca aparece en el campo, no hay nada que vigilar.
  @Test func sinLoPegadoSeRinde() async {
    let campo = CampoGuionado(["otra cosa"])
    let vigia = VigiaDeCorrecciones(tiempos: rapido, entradaSegura: { false })
    vigia.vigilar(pegado: pegado, leerValor: { campo.leer() }) { _ in Issue.record("entregó") }
    await esperar("no se rindió") { !vigia.estaMirando }
    #expect(campo.lecturas == rapido.vistazosParaEncontrarLoPegado + 1)
  }

  @Test func detenerCancela() async {
    let campo = CampoGuionado(["Revisa cuba netes hoy."])
    let vigia = VigiaDeCorrecciones(
      tiempos: .init(cadaCuanto: .milliseconds(5), vistazos: 60, vistazosQuieto: 3, vistazosParaEncontrarLoPegado: 10),
      entradaSegura: { false }
    )
    vigia.vigilar(pegado: pegado, leerValor: { campo.leer() }) { _ in Issue.record("entregó") }
    vigia.detener()
    #expect(!vigia.estaMirando)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(campo.lecturas <= 1)
  }
}

@MainActor
struct OfertaDeAprendizajeTests {
  private func settings() -> AppSettings {
    let nombre = "OfertaDeAprendizajeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    return AppSettings(defaults: defaults)
  }

  private func correcciones(_ settings: AppSettings, reloj: DeadlineClock = .continuous) -> (CorreccionesDelDictado, () -> [OfertaDeAprendizaje?]) {
    let c = CorreccionesDelDictado(settings: settings, vigia: VigiaDeCorrecciones(tiempos: rapido, entradaSegura: { false }))
    c.esPalabraConocida = { _ in false }
    c.reloj = reloj
    var vistas: [OfertaDeAprendizaje?] = []
    c.alCambiarLaOferta = { vistas.append($0) }
    return (c, { vistas })
  }

  private let par = ParDeCorreccion(oido: "cuba netes", correcto: "Kubernetes")

  @Test func ofreceAprendeYDeshace() {
    let ajustes = settings()
    let (c, vistas) = correcciones(ajustes)
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    #expect(c.oferta == OfertaDeAprendizaje(pares: [par]))
    // Nada se aprendió todavía: sólo se ofreció.
    #expect(ajustes.reemplazos.isEmpty)
    #expect(vistas().last??.segmento.texto == String(localized: "Aprender"))

    c.tocar()
    #expect(ajustes.palabrasPropias == ["Kubernetes"])
    #expect(ajustes.reemplazos == [Reemplazo(dice: "cuba netes", escribe: "Kubernetes", aprendido: true)])
    #expect(c.oferta?.actividad.id == ActividadDeLaMuesca.aprendizajeHecho.id)

    c.tocar()
    #expect(ajustes.palabrasPropias.isEmpty)
    #expect(ajustes.reemplazos.isEmpty)
    #expect(c.oferta == nil)
    #expect(vistas().last == .some(nil))

    // Lo deshecho no se vuelve a ofrecer.
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    #expect(c.oferta == nil)
  }

  /// Una pregunta que nadie contesta vence sola, no aprende nada y no se
  /// vuelve a hacer.
  @Test func laPreguntaVenceSinAprender() async {
    let ajustes = settings()
    let reloj = DrivenClock()
    let (c, _) = correcciones(ajustes, reloj: reloj.deadlineClock)
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    #expect(c.oferta != nil)
    await reloj.waitForSleeper()
    reloj.advance(by: CorreccionesDelDictado.duracionDeLaPregunta)
    await esperar("no venció") { c.oferta == nil }
    #expect(ajustes.reemplazos.isEmpty)
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa cuba netes hoy")
    #expect(c.oferta == nil)
  }

  /// Lo que puso un modo y no el motor no se ofrece.
  @Test func soloLoQueOyoElMotor() {
    let (c, _) = correcciones(settings())
    c.evaluar(pegado: "revisa cuba netes hoy", editado: "revisa Kubernetes hoy", crudo: "revisa el cluster hoy")
    #expect(c.oferta == nil)
  }

  /// Apagado en Ajustes, o en un anfitrión que no puede leer otra app, no
  /// se mira el campo ni una vez.
  @Test func apagadoOEnElSandboxNoMira() async {
    let ancla = AnclaDelFoco(
      pid: 1, elemento: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      seleccion: nil, marcador: nil
    )
    let lecturas = OSAllocatedUnfairLock(initialState: 0)
    let leer: @Sendable (AnclaDelFoco) async -> String? = { _ in
      lecturas.withLock { $0 += 1 }
      return "x"
    }
    let apagado = settings()
    apagado.aprenderDeCorrecciones = false
    let (c1, _) = correcciones(apagado)
    c1.vigilar(pegado: "x", crudo: "x", ancla: ancla, leer: leer)
    let (c2, _) = correcciones(settings())
    c2.anfitrion = SandboxedHost()
    c2.vigilar(pegado: "x", crudo: "x", ancla: ancla, leer: leer)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(lecturas.withLock { $0 } == 0)
    #expect(!c1.vigia.estaMirando && !c2.vigia.estaMirando)
  }
}

@MainActor
struct SegmentoDeAprendizajeTests {
  private let simulado = HUDScreenSnapshot(
    id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
    auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, menuBarHeight: 24
  )

  private final class Silencio: ReproductorDeSonidos {
    func playBegin(using settings: DictationSoundSettings) {}
    func playEnd(using settings: DictationSoundSettings) {}
    func playPaste(using settings: DictationSoundSettings) {}
  }

  /// La oferta se sienta al costado, dice «Aprender», un clic vuelve a quien
  /// la ofreció y al pasar a «Deshacer» cambia de segmento.
  @Test func laOfertaVaAlCostadoYElClicVuelve() {
    let stage = HUDStage(
      settings: AppSettings.previewStore(), reloj: DrivenClock().deadlineClock,
      sonidos: Silencio(), punteroEn: { .zero }
    )
    stage.colocar(en: simulado)
    var clics = 0
    stage.alTocarAprendizaje = { clics += 1 }
    let par = ParDeCorreccion(oido: "cuba netes", correcto: "Kubernetes")

    stage.mostrarOfertaDeAprendizaje(OfertaDeAprendizaje(pares: [par]))
    #expect(stage.dictationContent.segmentoIzquierdo?.id == "aprender")
    #expect(stage.dictationContent.segmentoIzquierdo?.accesibilidad.contains("Kubernetes") == true)
    stage.dictationContent.alTocarSegmento?("aprender")
    #expect(clics == 1)

    stage.mostrarOfertaDeAprendizaje(OfertaDeAprendizaje(pares: [par], fase: .aprendido(LoAprendido())))
    #expect(stage.dictationContent.segmentoIzquierdo?.id == "aprendido")
    #expect(stage.asientos.asiento(de: "aprender") == .ninguno)

    stage.mostrarOfertaDeAprendizaje(nil)
    #expect(stage.dictationContent.segmentoIzquierdo == nil)
  }

  /// Contra una carcasa real no hay costado: la oferta no se ve, y entonces
  /// tampoco se puede aceptar ni aprender nada.
  @Test func contraUnaCarcasaRealNoSeVe() {
    let stage = HUDStage(
      settings: AppSettings.previewStore(), reloj: DrivenClock().deadlineClock,
      sonidos: Silencio(), punteroEn: { .zero }
    )
    stage.colocar(en: HUDPreviewScreen.notched)
    stage.mostrarOfertaDeAprendizaje(OfertaDeAprendizaje(pares: [ParDeCorreccion(oido: "a b", correcto: "Ab")]))
    #expect(stage.dictationContent.segmentoIzquierdo == nil)
    #expect(stage.asientos.motivos["aprender"] == .pantallaSinLugar)
  }
}

@MainActor
struct AprenderEnElControladorTests {
  /// El vigía arranca después de pegar con el campo que se tomó al empezar,
  /// aunque el `sessionEnded` del pegado ya haya borrado el destino.
  @Test func trasPegarVigilaElCampoYOfrece() async {
    let arnes = ArnesDeLaFaseCuatro()
    let ancla = AnclaDelFoco(
      pid: 1, elemento: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      seleccion: RangoDeTexto(ubicacion: 0, largo: 0), marcador: nil
    )
    let destino = TextInsertionService.Target(
      element: nil, processIdentifier: 1, isSecure: false, displayID: nil,
      applicationName: "Notas", bundleID: "com.apple.Notes", ancla: ancla
    )
    let campo = CampoGuionado(["revisa cuba netes hoy", "revisa Kubernetes hoy"])
    var dependencias = arnes.dependencias(crudo: "revisa cuba netes hoy", destino: destino)
    dependencias.leerCampoParaAprender = { _ in campo.leer() }
    let control = arnes.controlador(dependencias)
    control.correcciones = CorreccionesDelDictado(
      settings: arnes.settings, vigia: VigiaDeCorrecciones(tiempos: rapido, entradaSegura: { false })
    )
    control.correcciones.esPalabraConocida = { _ in false }
    await arnes.preparar(control)

    await arnes.dictar(control)

    #expect(arnes.pegados == ["revisa cuba netes hoy"])
    await esperar("no ofreció") { control.correcciones.oferta != nil }
    #expect(control.correcciones.oferta?.pares == [ParDeCorreccion(oido: "cuba netes", correcto: "Kubernetes")])
    // Ofrecer no es aprender.
    #expect(arnes.settings.reemplazos.isEmpty)
    control.stop()
  }

  /// Lo que se copió y no se pegó no se vigila: no hay campo que mirar.
  @Test func loCopiadoNoSeVigila() async {
    let arnes = ArnesDeLaFaseCuatro()
    let ancla = AnclaDelFoco(
      pid: 1, elemento: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      seleccion: RangoDeTexto(ubicacion: 0, largo: 0), marcador: nil
    )
    let destino = TextInsertionService.Target(
      element: nil, processIdentifier: 1, isSecure: false, displayID: nil,
      applicationName: "Notas", bundleID: "com.apple.Notes", ancla: ancla
    )
    let lecturas = OSAllocatedUnfairLock(initialState: 0)
    var dependencias = arnes.dependencias(crudo: "hola", destino: destino, entrega: .copiado)
    dependencias.leerCampoParaAprender = { _ in lecturas.withLock { $0 += 1 }; return "hola" }
    let control = arnes.controlador(dependencias)
    await arnes.preparar(control)

    await arnes.dictar(control)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(!control.correcciones.vigia.estaMirando)
    #expect(lecturas.withLock { $0 } == 0)
    control.stop()
  }
}

@MainActor
struct SenalesDeLosModosEnLosAjustesTests {
  /// Quien ya tenía modos guardados recibe, una vez, las frases y los sitios
  /// de los de fábrica; a uno editado no se le toca nada, y lo que la
  /// persona vacía después no vuelve.
  @Test func laPasadaUnicaSumaLasSenales() throws {
    let nombre = "SenalesDeLosModos-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    var viejos = Modo.deFabrica
    for i in viejos.indices {
      viejos[i].sitios = []
      viejos[i].disparadoras = []
    }
    viejos[1].disparadoras = ["por mensaje"]
    defaults.set(try JSONEncoder().encode(viejos), forKey: "diloModos")
    defaults.set(MigracionDeModos.version, forKey: "diloMigracionDeModos")

    let primera = AppSettings(defaults: defaults)
    #expect(primera.modos.modo("correo")?.disparadoras == ["como correo"])
    #expect(primera.modos[1].disparadoras == ["por mensaje"])

    primera.modos[primera.modos.firstIndex { $0.id == "correo" }!].disparadoras = []
    let segunda = AppSettings(defaults: defaults)
    #expect(segunda.modos.modo("correo")?.disparadoras == [])
  }
}

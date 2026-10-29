import ApplicationServices
import DiloCapabilities
import DiloModes
import DiloText
import Foundation
import Testing
import os

@testable import Dilo

/// Un arnés chico del controlador para lo que la fase 4 le agregó: el
/// contexto, la elección automática del modo y el vigía de correcciones. Va
/// aparte de `DirectDictationControllerTests` para no tocar su arnés.
@MainActor
final class ArnesDeLaFaseCuatro {
  var pegados: [String] = []
  var conContexto: [(modo: String, contexto: SobreDelDictado.ContextoDeLaApp?, enLinea: Bool)] = []
  var sinContexto: [String] = []
  var historial: [String?] = []
  var mensajes: [String] = []
  var eventos: [String] = []

  let preparado = OSAllocatedUnfairLock(initialState: false)
  let defaults: UserDefaults
  let settings: AppSettings

  init() {
    let nombre = "ArnesDeLaFaseCuatro-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: nombre)!
    defaults.removePersistentDomain(forName: nombre)
    settings = AppSettings(defaults: defaults)
  }

  func dependencias(
    crudo: String = "palabras dichas",
    destino: TextInsertionService.Target? = TextInsertionService.Target(
      element: nil, processIdentifier: 1, isSecure: false, displayID: nil,
      applicationName: "Mail", bundleID: "com.apple.mail"
    ),
    entrega: ResultadoDeEntrega = .pegado(.lectura),
    lectores: LectoresDeContexto = .ninguno
  ) -> DirectDictationController.Dependencies {
    let preparado = preparado
    var dependencias = DirectDictationController.Dependencies(
      setDownloadHandler: { _ in },
      resolveLocale: { _ in Locale(identifier: "es_CL") },
      supportedLocale: { _ in nil },
      retainOnly: { _ in },
      prewarm: { _ in preparado.withLock { $0 = true } },
      startRecognition: { _, _, _, _, _ in },
      finishRecognition: { crudo },
      cancelRecognition: {},
      shutDownRecognition: {},
      translation: TranslationCoordinator(
        service: TranslationService(
          client: TranslationService.Client(
            availability: { _ in .installed },
            prepare: { _ in },
            translate: { _, texto in texto },
            candidateTargets: { [] },
            retain: { _ in },
            shutDown: {}
          )
        )
      ),
      captureFocusedTarget: { destino },
      insertText: { [unowned self] texto, _, _ in
        pegados.append(texto)
        eventos.append("insertText")
        return entrega
      },
      requestMicrophoneAccess: { true },
      requestSpeechAccess: { true },
      requestAccessibilityAccess: {},
      hasAccessibilityAccess: { true },
      isPermissionAlertPresenting: { false },
      showAccessibilitySetupAlert: {},
      showRelaunchAlert: {},
      showListening: { _, _, _, _ in },
      showLatched: {},
      showLiveText: { _, _ in },
      showFinalizing: {},
      showShaping: { _ in },
      showShapingChoice: { _ in },
      showProcesando: {},
      showResultado: { _ in },
      showMessage: { [unowned self] mensaje, _ in mensajes.append(mensaje) },
      showModelDownload: { _ in },
      showAudioLevel: { _ in },
      hideHUD: {},
      playPasteSound: { [unowned self] in eventos.append("playPasteSound") },
      setShapingCycleCaptureEnabled: { _ in },
      recordSession: { _, _ in },
      recordHistory: { [unowned self] _, _, _, modo, _, _ in
        await MainActor.run { historial.append(modo) }
      },
      transformar: { [unowned self] texto, modo, _ in
        await MainActor.run { sinContexto.append(modo.id) }
        return .transformado("\(modo.id): \(texto)")
      }
    )
    dependencias.lectoresDeContexto = lectores
    dependencias.transformarConContexto = { [unowned self] texto, modo, _, contexto, enLinea in
      await MainActor.run { conContexto.append((modo.id, contexto, enLinea)) }
      return .transformado("\(modo.id): \(texto)")
    }
    return dependencias
  }

  func controlador(_ dependencias: DirectDictationController.Dependencies) -> DirectDictationController {
    DirectDictationController(settings: settings, dependencies: dependencias)
  }

  /// Espera el estado y no una duración (la razón está en
  /// `DirectDictationControllerTests.waitUntil`).
  func hasta(_ comentario: Comment, _ condicion: @MainActor () -> Bool) async {
    let limite = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < limite {
      if condicion() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    if condicion() { return }
    Issue.record(comentario)
  }

  func preparar(_ controlador: DirectDictationController) async {
    controlador.applyLanguages()
    await hasta("la preparación no terminó") { controlador.isPreparedForTesting }
  }

  /// Un dictado trabado con la tecla de `slot`, de punta a punta.
  func dictar(
    _ controlador: DirectDictationController,
    _ slot: GlobalKeyEventMonitor.TriggerSlot = .primary,
    antesDeSoltar: (@MainActor (ContextoCapturado) -> Bool)? = nil,
    hastaQue condicion: (@MainActor () -> Bool)? = nil
  ) async {
    let pegadosAntes = pegados.count
    let inicio = ContinuousClock.now
    controlador.handle(.triggerPressed(slot), at: inicio)
    controlador.handle(.triggerReleased(slot), at: inicio + .milliseconds(10))
    await hasta("la sesión no se trabó") { controlador.sessionStateForTesting == .recording(.latched) }
    // Quien habla tarda más que la lectura del contexto; un runner cargado
    // no siempre: se espera a que llegue lo que el test necesita.
    if let antesDeSoltar {
      await hasta("el contexto no llegó") { antesDeSoltar(controlador.contextoLeidoForTesting) }
    }
    controlador.handle(.triggerPressed(slot))
    await hasta("el dictado no se entregó") { self.pegados.count > pegadosAntes }
    await hasta("la sesión no terminó") { controlador.sessionStateForTesting == .idle }
    if let condicion { await hasta("no se cumplió lo esperado", condicion) }
  }
}

@MainActor
struct ContextoEnLaTransformacionTests {
  private let correo = Modo.deFabrica.modo("correo")!
  private let contexto = SobreDelDictado.ContextoDeLaApp(
    app: "Mail", categoria: "correo", textoAntesDelCursor: "Hola Fran, sobre Kubernetes:"
  )

  private func proveedor(_ dialecto: Proveedor.Dialecto, url: String? = nil) -> ResolucionDeProveedor.Resuelto {
    let p = Proveedor(
      id: "p", nombre: "P", dialecto: dialecto, urlBase: url.flatMap(URL.init(string:)), modelo: "m"
    )
    return ResolucionDeProveedor.Resuelto(proveedor: p, modelo: "m", esLocal: p.esLocal)
  }

  private struct ClienteQueAnota: ClienteDeProveedor {
    let visto: OSAllocatedUnfairLock<String?>
    let respuesta: String
    func responder(instrucciones: String, peticion: String, modelo: String) async throws -> String {
      visto.withLock { $0 = peticion }
      return respuesta
    }
  }

  private func peticion(
    _ resuelto: ResolucionDeProveedor.Resuelto, enLinea: Bool, respuesta: String = "Hola, Fran."
  ) async -> (String?, TransformacionDeModo.Resultado) {
    let visto = OSAllocatedUnfairLock<String?>(initialState: nil)
    let servicio = TransformacionDeModo(fabrica: { _ in ClienteQueAnota(visto: visto, respuesta: respuesta) })
    let resultado = await servicio.correr(
      "hola fran", con: correo, deSesion: .corre(resuelto), contexto: contexto, contextoEnLinea: enLinea
    )
    return (visto.withLock { $0 }, resultado)
  }

  /// En el chip el contexto viaja dentro del sobre, como no confiable.
  @Test func enElChipElContextoVaEnElSobre() async {
    let (visto, _) = await peticion(proveedor(.enElChip), enLinea: false)
    #expect(visto?.contains(#""contexto_no_confiable""#) == true)
    #expect(visto?.contains("Kubernetes") == true)
  }

  /// A una nube el contexto no sale sin que la persona lo pida.
  @Test func aUnaNubeNoViajaSinPermiso() async {
    let nube = proveedor(.compatibleOpenAI, url: "https://api.openai.com/v1")
    let (sin, _) = await peticion(nube, enLinea: false)
    #expect(sin?.contains("contexto_no_confiable") == false)
    #expect(sin?.contains("Kubernetes") == false)
    let (con, _) = await peticion(nube, enLinea: true)
    #expect(con?.contains("Kubernetes") == true)
  }

  /// Un modelo que corre en este Mac (Ollama en localhost) es local.
  @Test func unModeloLocalLoRecibeSinPermisoExtra() async {
    let (visto, _) = await peticion(proveedor(.compatibleOpenAI, url: "http://localhost:11434/v1"), enLinea: false)
    #expect(visto?.contains("Kubernetes") == true)
  }

  /// Copiar una frase de la pantalla a la salida se rechaza aunque el modo
  /// deje reescribir.
  @Test func copiarElContextoSeRechaza() async {
    let largo = SobreDelDictado.ContextoDeLaApp(
      app: "Mail", textoAntesDelCursor: "Estimado Pedro te escribo para contarte que el proyecto se atrasa"
    )
    let servicio = TransformacionDeModo(fabrica: { _ in
      ClienteQueAnota(
        visto: .init(initialState: nil),
        respuesta: #"{"texto":"Hola. Te escribo para contarte que el proyecto se atrasa."}"#
      )
    })
    let resultado = await servicio.correr(
      "hola", con: correo, deSesion: .corre(proveedor(.enElChip)), contexto: largo
    )
    guard case let .rechazado(_, motivo) = resultado else {
      Issue.record("no se rechazó: \(resultado)")
      return
    }
    #expect(motivo == .copioElContexto)
  }
}

@MainActor
struct CapturaDeContextoTests {
  private let anfitrionCompleto = FullHost(lector: AccesibilidadDelSistema(), pidAlFrente: { 0 })

  private func ancla() -> AnclaDelFoco {
    AnclaDelFoco(
      pid: 1, elemento: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      seleccion: RangoDeTexto(ubicacion: 3, largo: 0), marcador: nil
    )
  }

  private func destino(bundleID: String, ancla: AnclaDelFoco? = nil) -> TextInsertionService.Target {
    TextInsertionService.Target(
      element: nil, processIdentifier: 7, isSecure: false, displayID: nil,
      applicationName: "App", bundleID: bundleID, ancla: ancla
    )
  }

  private let lectores = LectoresDeContexto(
    alrededor: { _, _ in TextoAlrededorDelCursor(antes: "antes", despues: "después", seleccion: "sel") },
    sitio: { _, _ in "github.com/aacontn/dilo" }
  )

  private func esperar(_ captura: CapturaDeContexto, _ condicion: (ContextoCapturado) -> Bool) async -> ContextoCapturado {
    for _ in 0 ..< 400 {
      try? await Task.sleep(for: .milliseconds(5))
      // Mirar sin recoger: recoger suelta lo leído.
      if condicion(captura.leidoHastaAhora) { break }
    }
    return captura.recoger().capturado
  }

  @Test func leeLoPrendidoYLoSueltaAlRecoger() async {
    let captura = CapturaDeContexto()
    captura.empezar(
      destino: destino(bundleID: "com.google.Chrome", ancla: ancla()),
      fuentes: FuentesDeContexto(textoAlrededor: true, sitio: true),
      sitioParaElegirModo: false, lectores: lectores, anfitrion: anfitrionCompleto
    )
    let leido = await esperar(captura) { $0.sitio != nil && !$0.textoAntes.isEmpty }
    #expect(leido.nombreDeApp == "App")
    #expect(leido.textoAntes == "antes")
    #expect(leido.textoDespues == "después")
    #expect(leido.sitio == "github.com/aacontn/dilo")
    #expect(captura.estaVacia)
  }

  /// Lo apagado no se lee: de fábrica sólo la app, sin preguntarle nada a
  /// la otra app.
  @Test func deFabricaNoLeeLaOtraApp() async {
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let contando = LectoresDeContexto(
      alrededor: { _, _ in llamadas.withLock { $0 += 1 }; return TextoAlrededorDelCursor() },
      sitio: { _, _ in llamadas.withLock { $0 += 1 }; return nil }
    )
    let captura = CapturaDeContexto()
    captura.empezar(
      destino: destino(bundleID: "com.google.Chrome", ancla: ancla()),
      fuentes: .deFabrica, sitioParaElegirModo: false, lectores: contando, anfitrion: anfitrionCompleto
    )
    try? await Task.sleep(for: .milliseconds(50))
    #expect(captura.recoger().capturado == ContextoCapturado(nombreDeApp: "App", bundleID: "com.google.Chrome"))
    #expect(llamadas.withLock { $0 } == 0)
  }

  /// En App Store lo que lee otra app no existe: ni se intenta.
  @Test func enElSandboxNoSeIntenta() async {
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let contando = LectoresDeContexto(
      alrededor: { _, _ in llamadas.withLock { $0 += 1 }; return TextoAlrededorDelCursor() },
      sitio: { _, _ in llamadas.withLock { $0 += 1 }; return nil }
    )
    let captura = CapturaDeContexto()
    captura.empezar(
      destino: destino(bundleID: "com.google.Chrome", ancla: ancla()),
      fuentes: FuentesDeContexto(textoAlrededor: true, seleccion: true, sitio: true),
      sitioParaElegirModo: true, lectores: contando, anfitrion: SandboxedHost()
    )
    try? await Task.sleep(for: .milliseconds(50))
    #expect(llamadas.withLock { $0 } == 0)
    #expect(captura.recoger().capturado.nombreDeApp == "App")
  }

  /// La mayúscula según el cursor lee tres caracteres aunque el campo no
  /// vaya al prompt, y no los deja como contexto para el modelo.
  @Test func laMayusculaLeeSoloLoDeAntesDelCursor() async {
    let topes = OSAllocatedUnfairLock(initialState: [Int]())
    let midiendo = LectoresDeContexto(
      alrededor: { _, tope in
        topes.withLock { $0.append(tope) }
        return TextoAlrededorDelCursor(antes: "el ", despues: "x", seleccion: "")
      },
      sitio: { _, _ in nil }
    )
    let captura = CapturaDeContexto()
    captura.empezar(
      destino: destino(bundleID: "com.apple.Notes", ancla: ancla()),
      fuentes: .deFabrica, sitioParaElegirModo: false, leerAntesDelCursor: true,
      lectores: midiendo, anfitrion: anfitrionCompleto
    )
    let leido = await esperar(captura) { $0.antesDelCursor != nil }
    #expect(leido.antesDelCursor == "el ")
    #expect(leido.textoAntes.isEmpty, "lo leído para la mayúscula no va al prompt")
    #expect(topes.withLock { $0 } == [AjusteAlCursor.caracteresQueMira])
  }

  /// Sin rango en el ancla (un editor web) no hay de dónde medir: nil, y el
  /// dictado entra como venía.
  @Test func sinRangoNoSeMideElCursor() async {
    let sinRango = AnclaDelFoco(
      pid: 1, elemento: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      seleccion: nil, marcador: nil
    )
    let captura = CapturaDeContexto()
    captura.empezar(
      destino: destino(bundleID: "com.apple.Notes", ancla: sinRango),
      fuentes: .deFabrica, sitioParaElegirModo: false, leerAntesDelCursor: true,
      lectores: lectores, anfitrion: anfitrionCompleto
    )
    try? await Task.sleep(for: .milliseconds(50))
    #expect(captura.recoger().capturado.antesDelCursor == nil)
  }

  /// El sitio sólo se pregunta a un navegador.
  @Test func elSitioSoloSePreguntaAUnNavegador() async {
    let llamadas = OSAllocatedUnfairLock(initialState: 0)
    let contando = LectoresDeContexto(
      alrededor: { _, _ in TextoAlrededorDelCursor() },
      sitio: { _, _ in llamadas.withLock { $0 += 1 }; return "x.com" }
    )
    let captura = CapturaDeContexto()
    captura.empezar(
      destino: destino(bundleID: "com.apple.mail"),
      fuentes: FuentesDeContexto(sitio: true), sitioParaElegirModo: true,
      lectores: contando, anfitrion: anfitrionCompleto
    )
    try? await Task.sleep(for: .milliseconds(50))
    #expect(llamadas.withLock { $0 } == 0)
    _ = captura.recoger()
  }
}

@MainActor
struct ContextoEnElControladorTests {
  /// El modo recibe la app y su categoría como contexto; nunca va al
  /// historial.
  @Test func elModoRecibeElContextoDeLaApp() async {
    let arnes = ArnesDeLaFaseCuatro()
    arnes.settings.dictationHistoryEnabled = true
    let control = arnes.controlador(arnes.dependencias())
    await arnes.preparar(control)

    await arnes.dictar(control, .modo("correo"))

    #expect(arnes.conContexto.map(\.modo) == ["correo"])
    #expect(arnes.conContexto.first?.contexto == .init(app: "Mail", categoria: "correo"))
    #expect(arnes.conContexto.first?.enLinea == false)
    #expect(arnes.sinContexto.isEmpty)
    #expect(arnes.historial.allSatisfy { !($0 ?? "").contains("Mail") })
    control.stop()
  }

  /// Con todas las fuentes apagadas el modo corre como antes, sin contexto.
  @Test func sinFuentesElModoCorreComoAntes() async {
    let arnes = ArnesDeLaFaseCuatro()
    arnes.settings.fuentesDeContexto = FuentesDeContexto(app: false)
    let control = arnes.controlador(arnes.dependencias())
    await arnes.preparar(control)

    await arnes.dictar(control, .modo("correo"))

    #expect(arnes.sinContexto == ["correo"])
    #expect(arnes.conContexto.isEmpty)
    control.stop()
  }
}

@MainActor
struct EleccionAutomaticaEnElControladorTests {
  /// «…, como correo» al final: el modo Correo, sin la frase, y el porqué en
  /// la muesca y en el historial.
  @Test func laFraseEligeElModoYSeVaDelTexto() async {
    let arnes = ArnesDeLaFaseCuatro()
    arnes.settings.dictationHistoryEnabled = true
    let control = arnes.controlador(arnes.dependencias(crudo: "mañana no llego, como correo"))
    await arnes.preparar(control)

    await arnes.dictar(control)

    #expect(arnes.conContexto.map(\.modo) == ["correo"])
    #expect(arnes.pegados == ["correo: mañana no llego"])
    await arnes.hasta("el historial no se escribió") { !arnes.historial.isEmpty }
    #expect(arnes.historial.first??.contains("dijiste «como correo»") == true)
    control.stop()
  }

  /// En Chrome la app no dice nada; el sitio sí, si Dilo decide.
  @Test func elSitioDelNavegadorEligeElModo() async {
    let arnes = ArnesDeLaFaseCuatro()
    arnes.settings.unAtajoDiloDecide = true
    let chrome = TextInsertionService.Target(
      element: nil, processIdentifier: 9, isSecure: false, displayID: nil,
      applicationName: "Google Chrome", bundleID: "com.google.Chrome"
    )
    let lectores = LectoresDeContexto(
      alrededor: { _, _ in TextoAlrededorDelCursor() },
      sitio: { _, _ in "github.com/aacontn/dilo" }
    )
    let control = arnes.controlador(arnes.dependencias(destino: chrome, lectores: lectores))
    await arnes.preparar(control)

    await arnes.dictar(control, antesDeSoltar: { $0.sitio != nil })

    #expect(arnes.conContexto.map(\.modo) == ["codigo"])
    // El sitio eligió el modo, pero no viaja al prompt: esa fuente está
    // apagada de fábrica.
    #expect(arnes.conContexto.first?.contexto?.sitio == nil)
    control.stop()
  }

  /// La tecla de un modo le gana a la frase: lo dicho queda entero.
  @Test func laTeclaLeGanaALaFrase() async {
    let arnes = ArnesDeLaFaseCuatro()
    let control = arnes.controlador(arnes.dependencias(crudo: "mañana no llego, como correo"))
    await arnes.preparar(control)

    await arnes.dictar(control, .modo("mensaje"))

    #expect(arnes.conContexto.map(\.modo) == ["mensaje"])
    #expect(arnes.pegados == ["mensaje: mañana no llego, como correo"])
    control.stop()
  }
}

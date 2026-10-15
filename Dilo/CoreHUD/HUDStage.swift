import AppKit
import DiloCapabilities
import DiloConsumo
import DiloModes
import SwiftUI

/// The one shape, and who is holding it.
///
/// Dilo has a single HUD: one panel, one hosting view, one place on screen.
/// Two features want it — Direct Dictation and Drop Transcription — and they
/// must never both have it. This owns the window, the display choice, the
/// mounting, and the arbitration; the feature controllers own what their
/// surface says. Neither of them touches `NSPanel`.
///
/// It also owns the status message band, because "the HUD is the only surface
/// for status and error messages" (CONTEXT.md) is a property of the HUD, not of
/// either feature: a file that cannot be read says so in the same place a
/// secure field does.
@MainActor
final class HUDStage {
  /// How long the retract animation needs before the panel can order out.
  /// A perceptual duration rather than the spring's settling time, per
  /// WWDC23 "Animate with springs": don't wait for settling.
  /// Internal so a test can wait out the retract rather than guess at it.
  static let dismissDuration = Duration.milliseconds(350)

  /// Who holds the shape. `message` is its own occupant rather than a mode of
  /// dictation: a message can interrupt either feature and outranks both.
  enum Occupant: Equatable {
    case none
    case dictation
    case message
    case drop
  }

  private(set) var occupant = Occupant.none

  /// El estado de sesión que el escenario está sosteniendo. Hoy siempre
  /// `dictando`: reunión y conversación están previstas y no se dibujan
  /// (`HUDSessionKind`, spec §5). Vive acá y no en el controlador de dictado
  /// porque el escenario es uno solo para los tres.
  private(set) var sessionKind = HUDSessionKind.dictando

  let dictationContent = DictationHUDContent()
  let dropContent = DropHUDContent()

  /// Quien reproduce los tres sonidos de una sesión. Entra por el inicializador
  /// para que un test pueda afirmar que empezar y terminar suenan sin tocar el
  /// audio de nadie (`ReproductorDeSonidos`).
  let sounds: any ReproductorDeSonidos

  /// Forwarded to the drop surface, which is the only part of the HUD that
  /// takes input.
  var onDropReceived: ((Int) -> Void)?
  var onCardEvent: ((HUDCardEvent) -> Void)?

  /// El retardo del hover de fábrica, en segundos.
  ///
  /// Medio segundo, el punto medio de lo que hacen las apps de notch que
  /// Alfonso pasó de referencia (0,4–0,6 s). La tolerancia es lo que separa
  /// «me acerqué a mirar» de «pasé el mouse camino al menú»: sin ella,
  /// cruzar la pantalla abre y cierra la muesca tres veces. Cuánto es lo
  /// justo depende de cómo mueve el mouse cada persona, así que es un ajuste
  /// (`AppSettings.hudRetardoDeHover`) y esto es sólo su valor inicial.
  static let retardoDeHoverDeFabrica = 0.5

  /// El de fábrica como `Duration`, que es lo que un test quiere adelantar
  /// cuando no cambió el ajuste.
  static var toleranciaDelHover: Duration {
    .milliseconds(Int(retardoDeHoverDeFabrica * 1000))
  }

  /// Cuánto se queda abierto el contexto como mucho.
  ///
  /// Red de seguridad y no diseño: la salida del puntero llega por el área de
  /// seguimiento de la vista (`HUDHostingView`), y no está garantizada —un
  /// espacio que cambia, una sesión que se bloquea, una ventana que se
  /// remonta bajo el cursor—. Sin esto, un contexto abierto se queda abierto
  /// para siempre.
  static let contextoMaximo = Duration.seconds(4)

  /// El estado del contrato que el escenario está sosteniendo.
  var estado: EstadoDelNotch { dictationContent.estado }

  /// La máquina del contrato del notch y sus tiempos. Vive acá y no en el
  /// controlador de dictado porque el escenario es uno solo: un mensaje de
  /// Drop Transcription y un resultado de dictado se turnan la misma forma, y
  /// con una máquina por feature se pisan los temporizadores.
  let control: ControlDelNotch

  /// Un clic en la silueta en reposo: abre el menú de acciones, el mismo del
  /// status item. Lo cablea `AppDelegate`, que es quien tiene el menú.
  var alPedirAcciones: (() -> Void)?
  /// Un clic en la silueta mostrando un resultado: copia lo último dictado.
  var alPedirCopiar: (() -> Void)?
  /// Un clic en un aviso accionable: lo que el aviso ofrece. Lo cablea
  /// `AppDelegate`, que es quien sabe abrir Ajustes del Sistema.
  var alPedirAccion: ((AvisoConAccion.Accion) -> Void)?

  private let settings: AppSettings
  private let panel: HUDPanel
  private let hostingView: HUDHostingView<HUDRootView>
  /// La pantalla donde está puesta la forma. El reposo se queda donde quedó
  /// la última sesión —seguir al puntero pediría sondearlo, y una forma que
  /// salta de monitor sola es peor que una que espera—.
  private var pantallaActual: HUDScreenSnapshot?
  private var hoverTask: Task<Void, Never>?
  /// El reloj de los plazos del escenario. Inyectable por el mismo motivo
  /// que el del pegado (#82): contra el reloj de pared, un test de tiempos
  /// afirma que el runner fue rápido, no que el plazo se respetó.
  private let reloj: DeadlineClock
  private var renderedSettings: DictationSessionSettings
  private var orderOutTask: Task<Void, Never>?
  /// El encuadre que la ventana tiene **ahora**, que no siempre es el que el
  /// estado pide: al abrirse crece antes de que arranque la animación, y al
  /// cerrarse se encoge después de que termine.
  private(set) var encuadre = HUDNotchGeometry.EncuadreDeLaVentana.reposo
  private var encogerTask: Task<Void, Never>?
  /// Si el puntero está sobre la silueta ahora mismo. Lo dice el área de
  /// seguimiento de `HUDHostingView`, que es la única fuente.
  private(set) var punteroSobreLaSilueta = false
  /// Si un arrastre pidió el mouse para toda la forma. Es lo único que
  /// todavía lo enciende «a mano»: Drop Transcription es un destino y su
  /// superficie tiene que recibir el arrastre entero.
  private var elArrastreTomaElMouse = false
  /// Dónde está el puntero ahora mismo, en coordenadas de pantalla. Sólo para
  /// los dos momentos en que el área de seguimiento no puede avisar: cuando
  /// la ventana vuelve a tomar el mouse y cuando vence la red de seguridad del
  /// hover. Inyectable por lo mismo que el reloj: un test que lea el mouse de
  /// verdad afirma dónde quedó el cursor de quien corre los tests.
  private let posicionDelPuntero: @MainActor () -> CGPoint
  /// El observador de cambio de espacio. Se guarda y no se da de baja: el
  /// escenario vive lo que vive la app, y un `deinit` en un tipo aislado al
  /// actor principal no puede tocar sus propiedades.
  private var spaceObserver: (any NSObjectProtocol)?

  #if DEBUG
    /// La escena del arnés que está en pantalla, o nil (`EscenaDeMuestra`).
    var muestra: MuestraEnCurso?
    /// Verdadero mientras el propio arnés llama a `claim`: un dictado de
    /// verdad también lo llama, y es lo que tiene que soltar la muestra.
    var dibujandoMuestra = false
    /// Avisa al arnés que un dictado de verdad le ganó la forma.
    var alInterrumpirLaMuestra: (() -> Void)?
  #endif

  /// Si el arnés de Debug tiene la forma. Mientras la tiene no suena nada,
  /// el puntero no abre ni cierra el panel y ningún botón hace nada real.
  /// Siempre falso en Release, donde el arnés no existe.
  var enMuestra: Bool {
    #if DEBUG
      muestra != nil
    #else
      false
    #endif
  }

  init(
    settings: AppSettings,
    reloj: DeadlineClock = .continuous,
    sonidos: any ReproductorDeSonidos = HUDSounds(),
    punteroEn: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }
  ) {
    self.settings = settings
    self.reloj = reloj
    posicionDelPuntero = punteroEn
    sounds = sonidos
    control = ControlDelNotch(reloj: reloj)
    renderedSettings = settings.sessionSettings
    let placeholder = HUDScreenSnapshot(
      id: 0,
      frame: .zero,
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      menuBarHeight: 0
    )
    hostingView = HUDHostingView(
      rootView: HUDRootView(
        screen: placeholder,
        settings: renderedSettings,
        content: dictationContent,
        drop: dropContent
      )
    )
    // The window size is this stage's decision, not the content's; without
    // this the hosting view imposes the shell's intrinsic size on the window
    // and collapses the fixed frame.
    hostingView.sizingOptions = []
    panel = HUDPanel(
      contentRect: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
      contentView: hostingView,
      ocultaAlCompartir: settings.hudOcultarAlCompartir
    )
    observeSpaceChanges()
    observarCambiosDePantallas()
    control.alCambiar = { [weak self] anterior, estado in
      guard let self else { return }
      aplicar(estado)
      sonarPor(anterior, a: estado)
      seguirLaSesion(de: anterior, a: estado)
      // La vuelta a reposo puede venir del temporizador del resultado, y
      // entonces nadie más soltó la forma.
      if estado == .reposo { retract() }
    }
    dictationContent.alHacerClic = { [weak self] in
      self?.clicEnLaSilueta()
    }
    dictationContent.alTocarLaTarjeta = { [weak self] tarjeta in
      self?.copiarLaTarjeta(tarjeta)
    }
    dictationContent.alTocarSegmento = { [weak self] id in
      self?.tocarSegmento(id)
    }
    // El puntero entra por el área de seguimiento de la vista y por ningún
    // otro lado: la ventana ya no ignora el mouse, así que ve entrar el
    // puntero en el momento en que entra.
    hostingView.alMoverseElPuntero = { [weak self] punto in
      self?.punteroSeMovio(a: punto)
    }
    hostingView.alSalirElPuntero = { [weak self] in
      self?.punteroSalio()
    }
    portapapeles.alCopiar = { [weak self] texto in
      self?.dictationContent.agregarReciente(texto, origen: .copiado)
    }
    dictationContent.alCopiarReciente = { [weak self] elemento in
      self?.copiarReciente(elemento)
    }
    calendario.alCambiar = { [weak self] reunion in
      self?.dictationContent.proximaReunion = reunion
    }
    dictationContent.alAbrirReunion = { [weak self] in
      LectorDelCalendario.abrir(self?.dictationContent.proximaReunion)
    }
    dictationContent.alElegirModo = { [weak self] id in
      self?.settings.hudModoDelAtajoGeneral = id
    }
    datos.alAvisar = { [weak self] aviso in
      self?.avisar(aviso) ?? false
    }
    datos.alCambiar = { [weak self] izquierdo, derecho in
      self?.dictationContent.datoIzquierdo = izquierdo
      self?.dictationContent.datoDerecho = derecho
      self?.anotarLosDatosEscondidos()
    }
  }

  // MARK: Los costados

  /// Quien mantiene al día los datos de los costados de la muesca.
  private let datos = DatosDeLaMuesca()

  /// Cuánto se alarga la muesca a cada lado: lo de un dato si alguno de los
  /// dos costados lleva uno, nada si ninguno.
  private var anchoDeLosLados: CGFloat {
    #if DEBUG
      if muestra?.conDatos == true { return HUDNotchGeometry.anchoDeUnLado }
    #endif
    return datos.llevaDatos ? HUDNotchGeometry.anchoDeUnLado : 0
  }

  /// Quién se sienta dónde (`AsientosDeLaMuesca`): la forma y los dos
  /// costados. La sesión del contrato entra y sale sola con el estado; la
  /// toma guardada y el retenido, cuando existen, como segmentos al costado:
  /// la misma silueta estirada hacia su lado (`HUDSegmentosAlCostado`).
  private(set) var asientos = AsientosDeLaMuesca()
  /// La tarjeta que otra sesión tapó, mientras viva en su segmento.
  private(set) var retenidoAlCostado: TarjetaDeRespaldo?
  private var vencimientoDelRetenido: Task<Void, Never>?
  /// Cuánto dura la toma que quedó en RAM, o nil sin toma.
  private(set) var tomaGuardada: TimeInterval?
  /// Los costados donde hay un segmento sentado ahora.
  private(set) var costadosConSegmento: Set<LadoDelAsiento> = []
  /// Si la ventana está montada con lugar para segmentos. Va detrás de
  /// `costadosConSegmento` al encogerse: el último segmento se va animando y
  /// la ventana se achica cuando ya se fue, como con el panel del hover.
  private(set) var ventanaConSegmentos = false
  private var encogerSegmentosTask: Task<Void, Never>?
  /// Cuándo cada segmento dice su palabra (`PalabraDeLosSegmentos`), y los
  /// plazos que la encogen.
  private(set) var palabra = PalabraDeLosSegmentos()
  private var encogerPalabraTasks: [LadoDelAsiento: Task<Void, Never>] = [:]
  /// Los costados cuyo dato está escondido por un segmento, para anotar en el
  /// log cuándo se esconde y cuándo vuelve.
  private var datosEscondidos: Set<LadoDelAsiento> = []

  /// Un clic en el segmento de la toma: reintentarla. Lo cablea `AppDelegate`
  /// hacia el controlador de dictado, que es quien tiene la toma.
  var alPedirReintento: (() -> Void)?

  /// Lo que Dilo ofrece aprender de una corrección, mientras viva en su
  /// segmento. Quién decide cuándo aparece, cuándo vence y qué hace el clic
  /// es `CorreccionesDelDictado`; el escenario sólo lo sienta y lo dibuja.
  private(set) var ofertaDeAprendizaje: OfertaDeAprendizaje?
  /// Un clic en ese segmento: aprender o deshacer.
  var alTocarAprendizaje: (() -> Void)?

  /// Lo que llega de afuera de Dilo y pide un segmento: los agentes que
  /// avisan por su *hook* (`AgentesEnLaMuesca`) y «Mostrar en la muesca» de
  /// Atajos (`AvisoDeAtajoEnLaMuesca`). El escenario sólo los sienta y los
  /// dibuja; cuándo aparecen, cuándo se van y qué hace el clic lo decide
  /// quien los publicó (2026-10-15). Nunca piden la forma: sólo costado.
  private(set) var segmentosDeAfuera: [String: ContenidoDelSegmento] = [:]
  /// Un clic en uno de esos segmentos, con el id de su actividad.
  var alTocarSegmentoDeAfuera: ((String) -> Void)?

  /// Sienta (o vuelve a sentar con otro contenido) un segmento de afuera.
  /// Con otro contenido bajo el mismo id el segmento vuelve a decir su
  /// palabra: «Claude» que pasa de trabajar a esperarte se tiene que notar.
  func publicarDeAfuera(_ actividad: ActividadDeLaMuesca, contenido: ContenidoDelSegmento) {
    var actividad = actividad
    actividad.puedeSerPrincipal = false
    actividad.exigeElPrincipal = false
    actividad.abreElMicrofono = false
    segmentosDeAfuera[actividad.id] = contenido
    sentar(.publicar(actividad))
  }

  func retirarDeAfuera(id: String) {
    guard segmentosDeAfuera.removeValue(forKey: id) != nil else { return }
    sentar(.retirar(id: id))
  }

  func mostrarOfertaDeAprendizaje(_ oferta: OfertaDeAprendizaje?) {
    let antes = ofertaDeAprendizaje?.actividad.id
    ofertaDeAprendizaje = oferta
    if let antes, antes != oferta?.actividad.id { sentar(.retirar(id: antes)) }
    if let oferta { sentar(.publicar(oferta.actividad)) } else { aplicarSegmentos() }
  }

  /// La toma que quedó en RAM cambió: aparece, se reintentó o venció. Llega
  /// del mismo aviso que esconde o muestra sus entradas en el menú de la
  /// barra (`DirectDictationController.onTomaFallidaChange`).
  func mostrarTomaGuardada(_ duracion: TimeInterval?) {
    tomaGuardada = duracion
    sentar(duracion == nil ? .retirar(id: ActividadDeLaMuesca.tomaGuardada.id) : .publicar(.tomaGuardada))
  }

  /// Pone (o saca) el segmento de una tarjeta tapada. Lo pone el propio
  /// escenario cuando una sesión tapa una tarjeta; interna para el arnés y
  /// los tests.
  func ponerRetenidoAlCostado(_ tarjeta: TarjetaDeRespaldo?) {
    retenidoAlCostado = tarjeta
    vencimientoDelRetenido?.cancel()
    vencimientoDelRetenido = nil
    guard tarjeta != nil else {
      sentar(.retirar(id: ActividadDeLaMuesca.retenido.id))
      return
    }
    sentar(.publicar(.retenido))
    if estado == .reposo { programarVencimientoDelRetenido() }
  }

  /// La sesión del contrato está en los asientos mientras la máquina no
  /// descansa, y una tarjeta que otra sesión tapa se corre a un segmento
  /// (`TarjetaDeRespaldo.tapada`).
  private func seguirLaSesion(de anterior: EstadoDelNotch, a nuevo: EstadoDelNotch) {
    if !enMuestra, let tapada = TarjetaDeRespaldo.tapada(de: anterior, a: nuevo) {
      ponerRetenidoAlCostado(tapada)
    }
    guard nuevo != .reposo else {
      sentar(.retirar(id: ActividadDeLaMuesca.sesion(escuchando: false).id))
      programarVencimientoDelRetenido()
      return
    }
    // Mientras dura una sesión el segmento del retenido no vence: lo que se
    // quiere es poder recogerlo cuando la sesión termine.
    vencimientoDelRetenido?.cancel()
    vencimientoDelRetenido = nil
    sentar(.publicar(.sesion(escuchando: nuevo.captura)))
  }

  private func programarVencimientoDelRetenido() {
    vencimientoDelRetenido?.cancel()
    vencimientoDelRetenido = nil
    guard retenidoAlCostado != nil else { return }
    vencimientoDelRetenido = Task { [weak self, reloj] in
      try? await reloj.sleep(TarjetaDeRespaldo.duracionAlCostado)
      guard !Task.isCancelled, let self, estado == .reposo else { return }
      ponerRetenidoAlCostado(nil)
    }
  }

  /// Un clic en un segmento. Mientras se dicta la ventana no toma el mouse,
  /// así que esto sólo llega en reposo o con una tarjeta a la vista.
  func tocarSegmento(_ id: String) {
    switch id {
    case ActividadDeLaMuesca.tomaGuardada.id:
      alPedirReintento?()
    case ActividadDeLaMuesca.ofertaDeAprendizaje.id, ActividadDeLaMuesca.aprendizajeHecho.id:
      alTocarAprendizaje?()
    case ActividadDeLaMuesca.retenido.id:
      guard let tarjeta = retenidoAlCostado else { return }
      copiarAlPortapapeles(tarjeta.texto)
      ponerRetenidoAlCostado(nil)
      // Lo dice la forma, como cuando se copia la tarjeta misma; con otra
      // tarjeta a la vista no la tapa.
      guard estado == .reposo, let pantallaActual else { return }
      decir(.copiado, texto: ResultadoDelNotch.copiado.texto, en: pantallaActual)
    default:
      if segmentosDeAfuera[id] != nil { alTocarSegmentoDeAfuera?(id) }
    }
  }

  /// Mueve los asientos y lleva el resultado a los segmentos.
  private func sentar(_ evento: AsientosDeLaMuesca.Evento) {
    asientos.recibir(evento)
    aplicarSegmentos()
  }

  /// Qué dice el segmento de cada actividad que hoy puede tener uno.
  private func contenido(de actividad: ActividadDeLaMuesca?) -> ContenidoDelSegmento? {
    switch actividad?.id {
    case ActividadDeLaMuesca.tomaGuardada.id: .toma
    case ActividadDeLaMuesca.retenido.id: .retenido
    case ActividadDeLaMuesca.ofertaDeAprendizaje.id, ActividadDeLaMuesca.aprendizajeHecho.id:
      ofertaDeAprendizaje?.segmento
    default: actividad.flatMap { segmentosDeAfuera[$0.id] }
    }
  }

  /// Lleva los asientos a la forma: el contenido de cada segmento, su
  /// palabra, la ventana y la zona que recibe el mouse.
  ///
  /// La ventana sigue la regla de siempre: crece **antes** de que el segmento
  /// empiece a entrar y se encoge **después** de que el último terminó de
  /// irse (`dismissDuration`), o la animación sale recortada.
  private func aplicarSegmentos() {
    let izquierdo = contenido(de: asientos.costado(.izquierda))
    let derecho = contenido(de: asientos.costado(.derecha))
    var lados: Set<LadoDelAsiento> = []
    if izquierdo != nil { lados.insert(.izquierda) }
    if derecho != nil { lados.insert(.derecha) }
    costadosConSegmento = lados
    if !lados.isEmpty {
      encogerSegmentosTask?.cancel()
      encogerSegmentosTask = nil
      if !ventanaConSegmentos {
        ventanaConSegmentos = true
        remontarConLosLadosActuales()
      }
    } else if ventanaConSegmentos, encogerSegmentosTask == nil {
      encogerSegmentosTask = Task { [weak self, reloj] in
        try? await reloj.sleep(Self.dismissDuration)
        guard !Task.isCancelled, let self else { return }
        encogerSegmentosTask = nil
        guard costadosConSegmento.isEmpty else { return }
        ventanaConSegmentos = false
        remontarConLosLadosActuales()
      }
    }
    // Quien aparece entra diciendo su palabra; quien se va, la suelta. Un
    // segmento que cambia lo que dice —un agente que pasa a esperarte—
    // también la vuelve a decir.
    for (lado, nuevo, viejo) in [
      (LadoDelAsiento.izquierda, izquierdo, dictationContent.segmentoIzquierdo),
      (.derecha, derecho, dictationContent.segmentoDerecho),
    ] where nuevo != viejo {
      cambiarLaPalabra(nuevo == nil ? .seFue(lado) : .aparecio(lado))
    }
    if dictationContent.segmentoIzquierdo != izquierdo { dictationContent.segmentoIzquierdo = izquierdo }
    if dictationContent.segmentoDerecho != derecho { dictationContent.segmentoDerecho = derecho }
    anotarLosDatosEscondidos()
    actualizarZonaInteractiva()
  }

  /// Mueve la palabra de los segmentos y programa cuándo se encoge.
  private func cambiarLaPalabra(_ evento: PalabraDeLosSegmentos.Evento) {
    for efecto in palabra.recibir(evento) {
      guard case let .encogerEn(lado, plazo, turno) = efecto else { continue }
      encogerPalabraTasks[lado]?.cancel()
      encogerPalabraTasks[lado] = Task { [weak self, reloj] in
        try? await reloj.sleep(plazo)
        guard !Task.isCancelled, let self else { return }
        cambiarLaPalabra(.vencio(lado, turno: turno))
      }
    }
    if dictationContent.segmentosConPalabra != palabra.conPalabra {
      dictationContent.segmentosConPalabra = palabra.conPalabra
      // El segmento cambió de ancho: la zona del mouse lo sigue.
      actualizarZonaInteractiva()
    }
  }

  /// Fija o suelta la palabra de todos los segmentos. Sólo para el arnés.
  func fijarLaPalabra(_ fijada: Bool) {
    cambiarLaPalabra(.fijar(fijada))
  }

  /// Encoge ya la palabra de todos los segmentos, como si hubieran vencido
  /// sus tres segundos. Sólo para el arnés y los tests.
  func encogerLaPalabra() {
    for lado in palabra.presentes {
      cambiarLaPalabra(.vencio(lado, turno: palabra.turno(de: lado)))
    }
  }

  /// Qué segmento hay bajo este punto de pantalla, si alguno.
  private func segmento(en punto: CGPoint) -> LadoDelAsiento? {
    guard let pantallaActual else { return nil }
    let cuerpo = HUDNotchGeometry.siluetaEnPantalla(
      for: pantallaActual,
      tamaño: tamañoDeLaSilueta,
      encuadre: encuadre
    )
    let costados = dictationContent.costados(en: pantallaActual)
    for lado in dictationContent.costadosConSegmentoVisible {
      guard let ancho = dictationContent.anchoDelSegmento(lado) else { continue }
      let rect = HUDNotchGeometry.rectDelSegmento(lado, ancho: ancho, costados: costados, cuerpo: cuerpo)
      if rect.contains(punto) { return lado }
    }
    return nil
  }

  /// Anota en el log el dato de cada costado que un segmento esconde y el
  /// que vuelve (`ReglaDeLosCostados`).
  private func anotarLosDatosEscondidos() {
    var conDato: Set<LadoDelAsiento> = []
    if dictationContent.datoIzquierdo != nil { conDato.insert(.izquierda) }
    if dictationContent.datoDerecho != nil { conDato.insert(.derecha) }
    let escondidos = ReglaDeLosCostados.escondidos(conDato: conDato, segmentos: costadosConSegmento)
    guard escondidos != datosEscondidos else { return }
    for lado in escondidos.symmetricDifference(datosEscondidos) {
      let dato = lado == .izquierda ? dictationContent.datoIzquierdo : dictationContent.datoDerecho
      let segmento = lado == .izquierda ? dictationContent.segmentoIzquierdo : dictationContent.segmentoDerecho
      RegistroDeLaMuesca.anotarDatoEscondido(
        dato?.dato.rawValue ?? "?",
        lado: lado,
        segmento: escondidos.contains(lado) ? segmento?.id : nil
      )
    }
    datosEscondidos = escondidos
  }

  /// Cuántos segmentos caben y si la pantalla está en pantalla completa, cada
  /// vez que la forma se monta: cambia con la pantalla y con el espacio.
  private func actualizarLosLugares(de pantalla: HUDScreenSnapshot) {
    let lugares = HUDNotchGeometry.lugaresAlCostado(for: pantalla)
    let suprimida = HUDNotchGeometry.reposoSeEsconde(for: pantalla)
    guard lugares != asientos.lugares || suprimida != asientos.suprimida else { return }
    asientos.recibir(.lugaresAlCostado(lugares))
    asientos.recibir(.suprimir(suprimida))
    aplicarSegmentos()
  }

  // MARK: El panel del hover

  /// Quien suma lo copiado a los recientes del panel.
  private let portapapeles = VigiaDelPortapapeles()
  /// Quien trae la próxima reunión del calendario. Lo usa también Ajustes
  /// para pedir el permiso.
  let calendario = LectorDelCalendario()

  /// Lo más que el panel del hover puede llevar con lo encendido en Ajustes.
  /// Los recientes siempre caben: cualquier dictado es uno.
  private var seccionesPosibles: SeccionesDelPanel {
    #if DEBUG
      if muestra?.panelCompleto == true { return .todas }
    #endif
    return SeccionesDelPanel(
      recientes: HUDNotchGeometry.recientesEnElPanel,
      datos: false,
      reunion: settings.hudProximaReunion,
      modos: (settings.hudModosEnElPanel && !settings.modos.isEmpty) || notaDisponible
        || settings.hudTraducirEnElPanel
    )
  }

  /// Cómo ofrece el panel la traducción: nil si se apagó en Ajustes.
  private var traduccionDelPanel: TraduccionDelPanel? {
    guard settings.hudTraducirEnElPanel else { return nil }
    guard settings.isTranslationEnabled,
      let codigo = Locale.Language(identifier: settings.translationTargetIdentifier)
        .languageCode?.identifier
    else { return .sinDestino }
    return .hacia(codigo.uppercased())
  }

  /// Si el panel ofrece la nota rápida: encendida en Ajustes y posible en
  /// este anfitrión (en App Store no hay Apple Events hacia Notas).
  private var notaDisponible: Bool {
    settings.hudNotaRapida && Anfitrion.actual.admite(.notasDeApple)
  }

  /// Deja un texto en el portapapeles. Una costura, para que un test afirme
  /// qué se copió sin tocar el portapapeles de quien lo corre.
  var copiarAlPortapapeles: (String) -> Void = { texto in
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(texto, forType: .string)
  }

  /// La tarjeta de un dictado que no se pegó, copiada con un clic. La forma
  /// pasa a decir que quedó copiado: es lo que la persona fue a buscar.
  private func copiarLaTarjeta(_ tarjeta: TarjetaDeRespaldo) {
    guard estado == .resultado(.retenido(tarjeta)) else { return }
    copiarAlPortapapeles(tarjeta.texto)
    recibir(.entregar(.copiado))
    dictationContent.text = ResultadoDelNotch.copiado.texto
    dictationContent.volatileText = ""
  }

  /// Copia un reciente y lo dice en su propia fila un momento.
  private func copiarReciente(_ elemento: ElementoReciente) {
    copiarAlPortapapeles(elemento.texto)
    dictationContent.recienteCopiadoID = elemento.id
    Task { [weak self, reloj] in
      try? await reloj.sleep(.milliseconds(1_200))
      guard let self, self.dictationContent.recienteCopiadoID == elemento.id else { return }
      self.dictationContent.recienteCopiadoID = nil
    }
  }

  /// Lleva al panel lo elegido en Ajustes: si mira el portapapeles, qué modos
  /// ofrece y cuál usa el atajo general. Un modo borrado de la biblioteca
  /// deja de estar elegido en vez de quedar apuntando a nada.
  private func aplicarElPanel() {
    portapapeles.encender(settings.hudRecientesDelPortapapeles)
    calendario.encender(settings.hudProximaReunion)
    let modos = settings.hudModosEnElPanel
      ? settings.modos.map { ModoDelPanel(id: $0.id, nombre: $0.nombre) }
      : []
    dictationContent.modosDelPanel = modos
    dictationContent.ofreceNota = notaDisponible
    dictationContent.traduccionDelPanel = traduccionDelPanel
    let elegido = settings.hudModoDelAtajoGeneral
    dictationContent.modoDelPanelID = modos.contains { $0.id == elegido } ? elegido : nil
  }

  /// Abre la muesca un momento con un aviso de límite, si está libre.
  ///
  /// Sólo en reposo y sin nadie en el escenario: un aviso de Claude que
  /// interrumpe un dictado le tapa a alguien lo que está diciendo. Si no
  /// entra, contesta que no, y `DatosDeLaMuesca` lo vuelve a ofrecer en la
  /// vuelta siguiente.
  private func avisar(_ aviso: AvisoDeLimite) -> Bool {
    guard estado == .reposo, occupant == .none, !enMuestra else { return false }
    showMessage(Self.texto(de: aviso), on: pantallaActual?.id)
    return true
  }

  /// «Claude al 95 % · se reinicia en 20 min», o la semana si es la semanal.
  static func texto(de aviso: AvisoDeLimite, ahora: Date = Date()) -> String {
    let nombre = TextoDelDato.etiqueta(aviso.dato)
    let valor = TextoDelDato.porcentaje(aviso.porcentaje)
    let falta = aviso.seReiniciaEn.map { TextoDelDato.faltaPara($0, desde: ahora) }
    switch (aviso.cual, falta) {
    case (.semana, let falta?):
      return String(localized: "\(nombre): \(valor) de la semana · se reinicia en \(falta)")
    case (.semana, nil):
      return String(localized: "\(nombre): \(valor) de la semana")
    case (_, let falta?):
      return String(localized: "\(nombre) al \(valor) · se reinicia en \(falta)")
    case (_, nil):
      return String(localized: "\(nombre) al \(valor)")
    }
  }

  /// Lleva lo elegido en Ajustes a los datos y, si cambió cuánto se alarga
  /// la muesca, la vuelve a montar en la misma pantalla con el ancho nuevo.
  private func aplicarLosLados() {
    let disposicion = settings.hudDisposicion
    datos.configurar(
      izquierdo: disposicion.dato(en: .izquierdo, disponible: DatosDeLaMuesca.disponible),
      derecho: disposicion.dato(en: .derecho, disponible: DatosDeLaMuesca.disponible),
      porcentajeDeClaude: settings.hudPorcentajeDeClaude,
      avisaLimites: settings.hudAvisosDeLimite
    )
    guard var pantalla = pantallaActual,
      pantalla.anchoDeLosLados != anchoDeLosLados || pantalla.seccionesPosibles != seccionesPosibles
    else { return }
    pantalla.anchoDeLosLados = anchoDeLosLados
    pantalla.seccionesPosibles = seccionesPosibles
    mount(on: pantalla)
  }

  /// Vuelve a aplicar los costados cada vez que cambian en Ajustes: sin esto,
  /// elegir un dato recién se vería al próximo dictado.
  private func observarLosLados() {
    withObservationTracking {
      _ = (settings.hudDisposicion, settings.hudPorcentajeDeClaude, settings.hudAvisosDeLimite)
      _ = (settings.hudRecientesDelPortapapeles, settings.hudModosEnElPanel)
      _ = (settings.hudModoDelAtajoGeneral, settings.modos, settings.hudProximaReunion)
      _ = (settings.hudNotaRapida, settings.hudTraducirEnElPanel, settings.translationTargetIdentifier)
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.aplicarLosLados()
        self?.aplicarElPanel()
        self?.observarLosLados()
      }
    }
  }

  /// Pone la forma en pantalla en reposo y la deja ahí.
  ///
  /// El notch de Dilo no aparece al dictar: está. Esto se llama una vez al
  /// arrancar, y después la forma sólo cambia de tamaño. Que la ventana viva
  /// montada no cuesta: en reposo nada anima (`EstadoDelNotch.anima`), que es
  /// el número que el spec §3 pide cuidar.
  func despertar() {
    // Los costados antes de elegir pantalla: su ancho es parte de la silueta
    // que se monta.
    aplicarLosLados()
    aplicarElPanel()
    observarLosLados()
    guard let screen = screen() else { return }
    dictationContent.isRevealed = false
    mount(on: screen)
    aplicar(.reposo)
    // Una línea al arrancar, y desde el escenario y no desde la vista: si el
    // registro está encendido y **esta** línea falta, lo que no ocurrió fue
    // el montaje — que es un diagnóstico distinto de «no se dibujó nada»
    // (`RegistroDeLaMuesca`).
    RegistroDeLaMuesca.anotarElArranque(
      estado: estado,
      ventana: HUDNotchGeometry.windowSize(for: screen, encuadre: encuadre),
      forma: HUDNotchGeometry.reposoSize(for: screen),
      pantalla: screen.nombre,
      notchReal: HUDNotchGeometry.hasMeasuredNotch(for: screen)
    )
  }

  /// Mueve la máquina del contrato. Es la única puerta: el estado no se
  /// escribe a mano desde ninguna parte.
  func recibir(_ evento: MaquinaDelNotch.Evento) {
    control.recibir(evento)
  }

  /// Anota en qué estado está el escenario y ajusta lo que depende de él: si
  /// la forma toma el mouse y qué franja de la ventana lo recibe.
  private func aplicar(_ estado: EstadoDelNotch) {
    // La ventana crece **antes** de que el estado nuevo empiece a animarse:
    // una revelación dentro de una ventana del tamaño del reposo sale
    // recortada en los primeros fotogramas, que son los que se miran.
    ajustarVentana(a: encuadreQuePide(estado))
    dictationContent.estado = estado
    if !estado.tomaElMouse {
      cancelarHover()
      intencion.reiniciar()
      redDeSeguridadTask?.cancel()
      redDeSeguridadTask = nil
      dictationContent.punteroEncima = false
      if palabra.bajoElPuntero != nil { cambiarLaPalabra(.punteroEncima(nil)) }
    } else if punteroSobreLaSilueta, !dictationContent.punteroEncima {
      // El puntero ya estaba encima cuando el estado cambió: terminar de
      // dictar con el mouse parado sobre la muesca tiene que volver a abrir
      // el contexto, y el área de seguimiento no manda nada mientras nadie
      // mueve el mouse. Quieto encima es frenado: abre sin el retardo entero.
      decidir(conLaMuestra: ultimoPunto ?? posicionDelPuntero(), dentro: true)
    }
    // Un arrastre en curso manda: la superficie de Drop Transcription pide el
    // mouse por su cuenta y no se lo quita un cambio de estado del dictado.
    if occupant != .drop { panel.tomaElTeclado = false }
    actualizarPresencia()
    actualizarZonaInteractiva()
  }

  /// Los dos sonidos que enmarcan una sesión, atados a la **transición** del
  /// contrato y no a que llegue un búfer de micrófono.
  ///
  /// Antes vivían en el controlador de dictado: Begin salía de
  /// `showAudioLevel`, es decir del primer nivel de audio que llegara, y sólo
  /// si el visual de voz estaba montado. Una sesión que empieza y no alcanza a
  /// entregar un búfer —o un visual que no se monta— empezaba muda, y el
  /// escenario nuevo no tenía dónde avisar. Reposo→dictando es el momento
  /// exacto que Dilo-Tauri usaba (`actions.rs`: el sonido sale al arrancar la
  /// grabación, no al oír), así que acá vuelve a estar.
  ///
  /// Uno solo por sesión de cada lado, y por eso hay dos banderas y no una
  /// comparación de estados: esperar un modelo a mitad de dictado manda la
  /// forma a `preparando` y la trae de vuelta a `dictando`, así que «entrar a
  /// dictando» ocurre más de una vez por sesión. La sesión termina al volver a
  /// reposo, que es donde las dos se reinician.
  private func sonarPor(_ anterior: EstadoDelNotch, a nuevo: EstadoDelNotch) {
    // Una escena del arnés no es una sesión: mostrar «dictando» no suena.
    guard !enMuestra else { return }
    let ajustes = renderedSettings.sounds
    guard nuevo != .reposo else {
      // Un dictado cancelado no pasa por procesando ni por resultado, y
      // terminó igual.
      if comenzoSonando, !terminoSonando { sounds.playEnd(using: ajustes) }
      comenzoSonando = false
      terminoSonando = false
      return
    }
    switch nuevo {
    case .dictando:
      guard !comenzoSonando else { return }
      comenzoSonando = true
      sounds.playBegin(using: ajustes)
    case .procesando, .resultado:
      // Sin comienzo no hay final: por acá pasan también los avisos de estado,
      // que entran a la forma por el mismo resultado del contrato y sonarían
      // como si alguien hubiera terminado de hablar.
      guard comenzoSonando, !terminoSonando else { return }
      terminoSonando = true
      sounds.playEnd(using: ajustes)
    case .preparando, .reposo:
      break
    }
  }

  /// Si esta sesión ya sonó al empezar y al terminar. Del escenario y no del
  /// controlador de dictado porque el escenario es uno solo: dos features se
  /// turnan la misma forma y llevarían dos copias de esto.
  private var comenzoSonando = false
  private var terminoSonando = false

  /// Si la forma está escondida ahora mismo: sólo el reposo, y sólo donde no
  /// hay barra de menús de la que colgar (`HUDNotchGeometry.reposoSeEsconde`).
  var escondido: Bool {
    guard let pantallaActual else { return false }
    return estado.esCompacto && HUDNotchGeometry.reposoSeEsconde(for: pantallaActual)
  }

  /// Esconde o muestra la forma sin sacarla de pantalla.
  ///
  /// `alphaValue` y no `orderOut`: la ventana se queda montada en todos los
  /// espacios, así que volver de una app en pantalla completa no pide
  /// recolocarla ni pelear otra vez por el orden. Lo que sí hay que soltar es
  /// el mouse, porque una ventana invisible que se traga clics es peor que
  /// una visible que los toma.
  private func actualizarPresencia() {
    panel.alphaValue = escondido ? 0 : 1
  }

  /// Vuelve a colocar la forma cuando cambia la configuración de pantallas:
  /// enchufar un monitor, cambiar la resolución o el modo escalado mueve
  /// dónde está el centro de la barra de menús.
  private func observarCambiosDePantallas() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let screen = self.screen() else { return }
        self.mount(on: screen)
      }
    }
  }

  /// La franja de la ventana que recibe el mouse: la silueta, no la ventana.
  ///
  /// En reposo es la silueta compacta; abierta, lo más ancho que la forma
  /// puede llegar a ser con los ajustes de esta sesión. Generoso a propósito
  /// en los estados abiertos: sólo duran lo que dura una sesión, y errar por
  /// unos puntos ahí vale menos que perder un clic.
  ///
  /// **Nil es lo que libera la pantalla.** Sin zona, `HUDHostingView.hitTest`
  /// devuelve nil en todo el rectángulo y la ventana deja de reclamar clics;
  /// no hay ningún `ignoresMouseEvents` que conmutar.
  private func actualizarZonaInteractiva() {
    guard let pantallaActual, estado.tomaElMouse || elArrastreTomaElMouse, !escondido else {
      panel.zonaInteractiva = nil
      return
    }
    let veniaIgnorandoElMouse = panel.zonaInteractiva == nil
    panel.zonaInteractiva = HUDNotchGeometry.zonaInteractiva(
      for: pantallaActual,
      tamaño: tamañoDeLaSilueta,
      encuadre: encuadre,
      // Los segmentos se esconden con el panel del hover abierto, y lo que
      // no se ve no toma clics.
      costados: dictationContent.costados(en: pantallaActual)
    )
    // Mientras no había zona la ventana ignoraba el mouse (`HUDPanel`) y el
    // área de seguimiento no vio nada: terminar de dictar con el puntero
    // parado sobre la muesca no manda ningún `mouseEntered` hasta que alguien
    // lo mueva. Se pregunta una vez dónde está, y eso sí abre el contexto.
    if veniaIgnorandoElMouse { punteroSeMovio(a: posicionDelPuntero()) }
  }

  /// El tamaño de la forma que hay dibujada ahora mismo.
  ///
  /// En reposo es la silueta compacta —abierta por el hover o no—; en los
  /// estados abiertos, lo más ancho que la forma puede llegar a ser con los
  /// ajustes de esta sesión. Generoso a propósito ahí: esos estados duran lo
  /// que dura una sesión, y errar por unos puntos vale menos que perder un
  /// clic en Copiar.
  private var tamañoDeLaSilueta: CGSize {
    guard let pantallaActual else { return .zero }
    let ventana = HUDNotchGeometry.windowSize(for: pantallaActual, encuadre: encuadre)
    guard estado.esCompacto else {
      // Sin carcasa la forma abierta es la muesca apenas más grande, medida:
      // una zona del ancho del panel del hover se comería clics de media
      // barra de menús mientras se dicta.
      // El aviso es más grande (`tamañoDelAviso`), y la tarjeta y el arreglo
      // con un clic, que son avisos, toman el mouse en toda su forma.
      guard HUDNotchGeometry.hasMeasuredNotch(for: pantallaActual) else {
        return estado.abreElAviso
          ? HUDNotchGeometry.tamañoDelAviso(for: pantallaActual)
          : HUDNotchGeometry.tamañoDictando(for: pantallaActual)
      }
      return CGSize(
        width: min(renderedSettings.hudMetrics.contentWidth, ventana.width),
        height: ventana.height - HUDNotchGeometry.holguraDeRevelacion(for: pantallaActual)
      )
    }
    let reposo = HUDNotchGeometry.reposoSize(for: pantallaActual)
    // Con el contexto abierto la silueta crece hasta el ancho de la forma
    // abierta; la zona crece con ella y no más, que es lo que evita que la
    // muesca se coma clics de media barra de menús.
    guard dictationContent.contextoVisible != nil else { return reposo }
    let conDatos = pantallaActual.anchoDeLosLados > 0
      && (dictationContent.datoIzquierdo != nil || dictationContent.datoDerecho != nil)
    return CGSize(
      width: min(renderedSettings.hudMetrics.contentWidth, ventana.width),
      height: HUDNotchGeometry.altoDelPanelDeHover(
        for: pantallaActual,
        secciones: dictationContent.seccionesDelPanel(conDatos: conDatos)
      )
    )
  }

  // MARK: La ventana mide lo que mide el estado

  /// Qué ventana pide este estado, contando lo que el hover tenga abierto y
  /// un arrastre en curso.
  private func encuadreQuePide(_ estado: EstadoDelNotch) -> HUDNotchGeometry.EncuadreDeLaVentana {
    guard estado.esCompacto else { return .abierta }
    if dictationContent.contextoVisible != nil { return .abierta }
    if occupant == .drop || dropContent.mode != .none { return .abierta }
    return .reposo
  }

  /// El que pide lo que la forma está mostrando ahora.
  private var encuadreNecesario: HUDNotchGeometry.EncuadreDeLaVentana {
    encuadreQuePide(estado)
  }

  /// Cambia el tamaño de la ventana anfitriona, creciendo en el acto y
  /// encogiendo con retardo.
  ///
  /// Las dos direcciones no son simétricas y esa asimetría es todo el
  /// arreglo: si la ventana creciera junto con la animación, la revelación
  /// saldría recortada; si se encogiera junto con ella, el cierre se cortaría
  /// de golpe. Crece antes de que la animación arranque y se encoge cuando ya
  /// terminó (`dismissDuration`, la duración perceptual del encogimiento).
  private func ajustarVentana(a necesario: HUDNotchGeometry.EncuadreDeLaVentana) {
    guard let pantalla = pantallaActual else { return }
    guard necesario == .reposo else {
      encogerTask?.cancel()
      encogerTask = nil
      guard encuadre != .abierta else { return }
      aplicarEncuadre(.abierta, en: pantalla)
      return
    }
    guard encuadre == .abierta, encogerTask == nil else { return }
    encogerTask = Task { [weak self, reloj] in
      try? await reloj.sleep(Self.dismissDuration)
      guard !Task.isCancelled, let self else { return }
      encogerTask = nil
      guard encuadreNecesario == .reposo, let actual = pantallaActual else { return }
      aplicarEncuadre(.reposo, en: actual)
    }
  }

  private func aplicarEncuadre(
    _ nuevo: HUDNotchGeometry.EncuadreDeLaVentana,
    en pantalla: HUDScreenSnapshot
  ) {
    encuadre = nuevo
    panel.setFrame(HUDNotchGeometry.windowFrame(for: pantalla, encuadre: nuevo), display: true)
    // La vista se entera del tamaño nuevo **ahora**, fuera de toda animación.
    // El cambio de estado que viene detrás —el hover, la revelación— sí
    // anima, y si SwiftUI juntara las dos cosas en una sola pasada tomaría el
    // corrimiento de la forma dentro de la ventana (9 puntos del borde en
    // reposo, 164 abierta) como algo que también hay que animar: la muesca
    // saltaría de costado antes de crecer.
    hostingView.layoutSubtreeIfNeeded()
    actualizarZonaInteractiva()
  }

  /// El marco de la ventana anfitriona, en coordenadas de pantalla. Para que
  /// un test pueda afirmar que en reposo mide la muesca y no la pantalla.
  var marcoDeLaVentana: CGRect { panel.frame }

  /// Si la ventana entera está dejando pasar el mouse: sólo cuando la forma no
  /// reclama nada, como mientras se dicta (`HUDPanel.zonaInteractiva`).
  var ventanaIgnoraElMouse: Bool { panel.ignoresMouseEvents }

  /// Si la ventana está dejando pasar el mouse en este punto de pantalla.
  ///
  /// Se pregunta por la zona y no por `ignoresMouseEvents`: la zona es lo que
  /// `HUDHostingView.hitTest` va a contestar ahí, y sin zona la ventana además
  /// ignora el mouse entero (`HUDPanel.zonaInteractiva`).
  func dejaPasarElMouse(en punto: CGPoint) -> Bool {
    guard let zona = panel.zonaInteractiva else { return true }
    let ventana = panel.frame
    let local = CGPoint(x: punto.x - ventana.minX, y: punto.y - ventana.minY)
    return !zona.contains(local)
  }

  /// La pantalla donde está montada la forma ahora.
  var pantallaMontada: HUDScreenSnapshot? { pantallaActual }

  /// Vuelve a montar en la misma pantalla con lo que hoy piden los costados y
  /// el panel del hover. Es lo que hace `aplicarLosLados` cuando cambia un
  /// ajuste, sin mirar si cambió.
  func remontarConLosLadosActuales() {
    guard var pantalla = pantallaActual else { return }
    pantalla.anchoDeLosLados = anchoDeLosLados
    pantalla.seccionesPosibles = seccionesPosibles
    pantalla.llevaSegmentos = ventanaConSegmentos
    mount(on: pantalla)
  }

  /// Vuelve a aplicar el estado del contrato que ya está puesto: el encuadre
  /// de la ventana, la zona que recibe el mouse. Para cuando lo que cambió no
  /// fue el estado sino lo que la forma muestra en él (el panel del hover).
  func reaplicarElEstado() {
    aplicar(estado)
  }

  /// Pone la forma en esta pantalla sin que nadie ocupe el escenario. Es lo
  /// que `despertar()` hace con la pantalla que elige, expuesto para que un
  /// test no dependa de los monitores que tenga la máquina que corre.
  func colocar(en pantalla: HUDScreenSnapshot) {
    mount(on: pantalla)
  }

  /// El puntero se movió, en coordenadas de pantalla.
  ///
  /// Lo llama el área de seguimiento de `HUDHostingView`, que es la única
  /// fuente: la ventana ya no ignora el mouse, así que ve entrar el puntero
  /// en el instante en que entra. La silueta se mide con la misma geometría
  /// que arma `zonaInteractiva`, así que «responde al clic» y «cuenta como
  /// hover» no pueden desviarse.
  func punteroSeMovio(a punto: CGPoint) {
    guard let pantallaActual, !enMuestra else { return }
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: pantallaActual,
      tamaño: tamañoDeLaSilueta,
      encuadre: encuadre
    )
    let dentro = silueta.contains(punto)
    punteroSobreLaSilueta = dentro
    ultimoPunto = punto
    guard estado.tomaElMouse else { return }
    // El segmento no es silueta para la intención: posarse en él le
    // devuelve la palabra y nunca abre el panel del hover. Para
    // `IntencionDelPuntero` es «afuera», así que con el panel abierto
    // ir al segmento empieza la gracia de cierre, como ir a la barra.
    cambiarLaPalabra(.punteroEncima(dentro ? nil : segmento(en: punto)))
    decidir(conLaMuestra: punto, dentro: dentro)
  }

  /// El puntero se fue de la ventana entera. El área de seguimiento lo avisa
  /// aunque el último movimiento no haya caído en la silueta.
  func punteroSalio() {
    guard !enMuestra else { return }
    punteroSobreLaSilueta = false
    cambiarLaPalabra(.punteroEncima(nil))
    guard estado.tomaElMouse else { return }
    decidir(conLaMuestra: ultimoPunto ?? posicionDelPuntero(), dentro: false)
  }

  /// Dónde estuvo el puntero la última vez que el área de seguimiento avisó.
  private var ultimoPunto: CGPoint?

  /// Si el puntero vino a mirar la muesca o va de paso
  /// (`IntencionDelPuntero`). El tiempo lo lleva el escenario, con su reloj:
  /// la intención sólo dice cuándo volver a preguntarle.
  private var intencion = IntencionDelPuntero()

  /// La red de seguridad del panel abierto (`contextoMaximo`).
  private var redDeSeguridadTask: Task<Void, Never>?

  /// Una muestra más para la intención, con el retardo que hoy dice Ajustes.
  ///
  /// La llama sólo el área de seguimiento (por `punteroSeMovio` y
  /// `punteroSalio`) o un cambio de estado con el puntero ya encima. La vista
  /// de SwiftUI no opina con su `onHover`: mandaba una salida falsa cada vez
  /// que la ventana cambiaba de tamaño, que es justo lo que el hover hace al
  /// abrirse.
  private func decidir(conLaMuestra punto: CGPoint, dentro: Bool) {
    intencion.ajustes.retardo = .milliseconds(
      Int((max(0, settings.hudRetardoDeHover) * 1000).rounded())
    )
    decidir(intencion.muestra(punto, dentro: dentro, t: reloj.now()))
  }

  private func decidir(_ decision: IntencionDelPuntero.Decision) {
    // La escena `hover` del arnés abre el panel sola; el mouse de verdad no
    // lo abre ni lo cierra.
    guard !enMuestra else { return }
    switch decision {
    case .nada:
      break
    case .abrir:
      cancelarHover()
      abrirElPanel()
    case .cerrar:
      cancelarHover()
      cerrarElPanel()
    case let .revisarEn(plazo):
      hoverTask?.cancel()
      hoverTask = Task { [weak self, reloj] in
        try? await reloj.sleep(plazo)
        guard !Task.isCancelled, let self else { return }
        hoverTask = nil
        guard estado.tomaElMouse else { return }
        decidir(intencion.revisar(t: reloj.now()))
      }
    }
  }

  /// Abre el panel del hover.
  ///
  /// Un hover jamás arranca una captura: lo único que toca es qué se dibuja
  /// (contrato del notch). Y no exige `contexto`, que sólo existe después del
  /// primer dictado: qué se dice con el panel abierto lo resuelve
  /// `DictationHUDContent.contextoVisible`, que nunca se queda sin algo.
  private func abrirElPanel() {
    guard estado.tomaElMouse else { return }
    // La ventana primero, el contexto después: el panel del hover también
    // es la silueta creciendo, y crece con la misma curva.
    ajustarVentana(a: .abierta)
    // Se lee al abrir y no al montar: el ajuste vive fuera de la foto de la
    // sesión, y cambiarlo tiene que verse en el próximo hover.
    dictationContent.panelDeVidrio = settings.hudPanelDeVidrio
    dictationContent.punteroEncima = true
    actualizarZonaInteractiva()

    // La red de seguridad cierra sólo si el puntero de verdad se fue. Antes
    // cerraba a los cuatro segundos con el mouse todavía encima, y el panel
    // se recogía solo mientras alguien lo estaba leyendo: eso también se
    // lee como un hover que no anda.
    redDeSeguridadTask?.cancel()
    redDeSeguridadTask = Task { [weak self, reloj] in
      repeat {
        try? await reloj.sleep(Self.contextoMaximo)
        guard !Task.isCancelled else { return }
      } while self?.punteroSigueEncima() == true
      guard let self else { return }
      punteroSobreLaSilueta = false
      intencion.reiniciar()
      cerrarElPanel()
    }
  }

  private func cerrarElPanel() {
    redDeSeguridadTask?.cancel()
    redDeSeguridadTask = nil
    dictationContent.punteroEncima = false
    actualizarZonaInteractiva()
    ajustarVentana(a: encuadreNecesario)
  }

  /// Si el puntero está sobre la silueta según dónde está **ahora**, y no
  /// según el último aviso del área de seguimiento: la red de seguridad del
  /// hover existe justo para cuando ese aviso se perdió.
  private func punteroSigueEncima() -> Bool {
    guard let pantallaActual else { return false }
    return HUDNotchGeometry.siluetaEnPantalla(
      for: pantallaActual,
      tamaño: tamañoDeLaSilueta,
      encuadre: encuadre
    ).contains(posicionDelPuntero())
  }

  private func cancelarHover() {
    hoverTask?.cancel()
    hoverTask = nil
  }

  /// Dónde abrir el menú de acciones: justo debajo de la silueta, en
  /// coordenadas de pantalla.
  var puntoDeAcciones: NSPoint? {
    guard let pantallaActual else { return nil }
    let ventana = HUDNotchGeometry.windowFrame(for: pantallaActual, encuadre: encuadre)
    let reposo = HUDNotchGeometry.reposoSize(for: pantallaActual)
    return NSPoint(x: ventana.midX, y: ventana.maxY - reposo.height)
  }

  /// Un clic en la silueta. En reposo abre el menú de acciones, salvo que el
  /// hover tenga el panel abierto con algo que copiar: ahí «copiar el último
  /// dictado» es la acción del panel, que es donde quedó al salir el estado
  /// Resultado.
  // MARK: Terminar un dictado trabado con un clic

  /// Quien mira los clics mientras hay un dictado trabado.
  private var monitorDeLaSesionTrabada: Any?

  /// Lo que se abre sin tecla sostenida —una nota, una traducción desde el
  /// panel, el doble toque— tiene que poder cerrarse con un clic en la muesca
  /// misma: la nota quedaba escuchando sin nada que dijera cómo pararla
  /// (reporte del 2026-09-24).
  ///
  /// **Con un monitor global y no tomando el mouse.** Mientras se dicta, la
  /// ventana deja pasar todos los clics; hacer que los tomara para esto
  /// convertiría su rectángulo —dimensionado para el panel del hover, hasta
  /// 488×262 sobre el centro de la barra— en pantalla muerta durante toda la
  /// sesión. El monitor ve el clic que va a la app de abajo y, si cayó sobre la
  /// silueta, la termina. Debajo de la muesca simulada sólo está el
  /// centro vacío de la barra de menús, así que ese clic no hace nada más.
  /// Los monitores globales de mouse no piden permiso.
  func vigilarElClicDeLaSesionTrabada(_ encendido: Bool) {
    if let monitorDeLaSesionTrabada { NSEvent.removeMonitor(monitorDeLaSesionTrabada) }
    monitorDeLaSesionTrabada = nil
    guard encendido else { return }
    monitorDeLaSesionTrabada = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.dictationContent.sesionTrabadaEnCurso else { return }
        self.clicDuranteLaSesionTrabada(en: self.posicionDelPuntero())
      }
    }
  }

  /// Un clic con un dictado trabado: si cayó en la silueta, lo termina.
  func clicDuranteLaSesionTrabada(en punto: CGPoint) {
    guard dictationContent.sesionTrabadaEnCurso, let pantallaActual else { return }
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: pantallaActual,
      tamaño: tamañoDeLaSilueta,
      encuadre: encuadre
    )
    guard silueta.contains(punto) else { return }
    dictationContent.alTerminarSesionTrabada?()
  }

  private func clicEnLaSilueta() {
    if case let .resultado(.accionable(aviso)) = estado {
      alPedirAccion?(aviso.accion)
      // Hecho lo que ofrecía, el aviso no tiene más que decir. Deshacer no:
      // ahí la forma sigue con la entrega, y la mueve el dictado.
      if aviso.accion != .deshacerCancelacion { retract() }
      return
    }
    guard estado == .reposo else { return }
    if dictationContent.contextoVisible != nil, dictationContent.puedeCopiar {
      alPedirCopiar?()
      return
    }
    alPedirAcciones?()
  }

  /// Vuelve a poner la forma al frente cuando cambia el espacio activo.
  ///
  /// `canJoinAllSpaces` la lleva a todos los espacios, pero no arregla el
  /// orden: si el espacio nuevo es una app en pantalla completa nativa, su
  /// ventana se ordena al frente al entrar y la forma queda detrás —
  /// visible en el Escritorio, invisible en Keynote o en Safari en pantalla
  /// completa (issue #84 del árbol de origen). Reordenar al frente en cada cambio de
  /// espacio es lo que el overlay de Dilo-Tauri conseguía siendo un NSPanel
  /// `nonactivating` + `floating` que se muestra de nuevo en cada estado.
  ///
  /// Sólo mientras hay alguien en el escenario: sin sesión no hay ventana que
  /// ordenar y el observador no cuesta nada.
  private func observeSpaceChanges() {
    spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // Siempre, no sólo con sesión: desde que el escenario es permanente,
        // la forma en reposo también tiene que sobrevivir al cambio de
        // espacio.
        self.panel.assertOverlayOrder()
        // Y volver a medir: entrar a una app en pantalla completa autooculta
        // la barra de menús, que es de donde sale el alto de la muesca y
        // también la señal de que el reposo tiene que esconderse.
        if let screen = self.screen() { self.mount(on: screen) }
      }
    }
  }

  /// Si la forma entera recibe el mouse aunque el estado del contrato no lo
  /// pida. Sólo un arrastre lo enciende: Drop Transcription es un destino y
  /// necesita la superficie completa mientras dura.
  var acceptsMouse: Bool {
    get { elArrastreTomaElMouse }
    set {
      elArrastreTomaElMouse = newValue
      actualizarZonaInteractiva()
    }
  }

  /// Si la forma está reclamando clics ahora mismo. Para que un test pueda
  /// afirmar que fuera de la silueta la ventana no se queda con nada.
  var laFormaRecibeElMouse: Bool { panel.zonaInteractiva != nil }

  /// The live sound preferences. A Drop Transcription has no session snapshot
  /// to capture — its moments are minutes apart — so it reads the current pick
  /// each time, where dictation uses the one it started with.
  var dropSoundSettings: DictationSoundSettings {
    settings.sessionSettings.sounds
  }

  /// The display this surface should open on: the one holding the focused
  /// input where that is known, else the pointer's, else the main one.
  func screen(preferring displayID: CGDirectDisplayID? = nil) -> HUDScreenSnapshot? {
    let screens = NSScreen.screens.compactMap { screen -> HUDScreenSnapshot? in
      guard let id = screen.cgDirectDisplayID else { return nil }
      return HUDScreenSnapshot(
        id: id,
        frame: screen.frame,
        safeAreaTop: screen.safeAreaInsets.top,
        auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
        auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
        menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
        estiloSinNotch: settings.hudEstiloSinNotch,
        nombre: screen.localizedName,
        anchoDeLosLados: anchoDeLosLados,
        seccionesPosibles: seccionesPosibles,
        llevaSegmentos: ventanaConSegmentos
      )
    }
    return HUDPlacement.selectDisplay(
      from: screens,
      targetDisplayID: displayID,
      pointerLocation: NSEvent.mouseLocation,
      pantallaElegida: settings.hudPantalla
    )
  }

  /// Hands the shape to `occupant` and puts it on `screen`.
  ///
  /// Taking it for dictation or a message evicts any drop surface: the file
  /// job keeps running with the status item carrying it, but the user is
  /// speaking now and that outranks a card (CONTEXT.md).
  func claim(
    _ occupant: Occupant,
    on screen: HUDScreenSnapshot,
    rendering settings: DictationSessionSettings? = nil,
    kind: HUDSessionKind = .dictando
  ) {
    // Un estado que todavía no dibuja nada no abre el escenario: una forma
    // negra vacía se lee como un cuelgue (`HUDSessionKind.isDrawn`).
    guard kind.isDrawn else { return }
    #if DEBUG
      // Un dictado de verdad le gana a la muestra: la escena se suelta y la
      // forma es de la sesión desde este mismo `claim`.
      if muestra != nil, !dibujandoMuestra { interrumpirMuestra() }
    #endif
    orderOutTask?.cancel()
    if occupant != .message { cancelMessageDismiss() }
    if occupant != .drop { evictDrop() }
    self.occupant = occupant
    sessionKind = kind
    renderedSettings = settings ?? self.settings.sessionSettings
    mount(on: screen)
  }

  /// Suelta la forma: se encoge hasta el reposo y se queda ahí.
  ///
  /// **La ventana no se va de la pantalla.** Antes se ordenaba fuera y el
  /// notch desaparecía al terminar de dictar, que es lo que lo volvía una
  /// notificación en vez de un lugar. Ahora el escenario es permanente y lo
  /// que cambia es el tamaño de la silueta.
  func retract() {
    guard occupant != .none else { return }
    // Idempotente: si la máquina ya está en reposo —porque venció el
    // resultado— esto no mueve nada y no vuelve a llamar acá.
    control.recibir(.cancelar)
    occupant = .none
    dictationContent.isRevealed = false
    dropContent.isRevealed = false
    // La ventana se encoge después, no ahora: lo que queda por delante es la
    // animación de cierre, y una ventana ya achicada la recorta.
    ajustarVentana(a: encuadreNecesario)

    orderOutTask?.cancel()
    orderOutTask = Task { [weak self, reloj] in
      try? await reloj.sleep(Self.dismissDuration)
      guard !Task.isCancelled, let self, occupant == .none else { return }
      // Sólo cuando la forma ya se encogió: limpiar antes se vería durante
      // el encogimiento.
      dictationContent.isDismissing = false
      dictationContent.text = ""
      dictationContent.volatileText = ""
      // The shaping caption outlived the shape: it is what decides whether
      // the label is mounted, and the label animates every frame while it is.
      dictationContent.shapingName = nil
      dictationContent.shapingChoiceLabel = nil
      dropContent.mode = .none
      dropContent.heldIcon = nil
      dropContent.transcript = nil
      aplicar(.reposo)
    }
  }

  /// Runs `work` after `delay` unless the shape has changed hands, for the
  /// self-dismissing states: a message, a notice, a card's deadline.
  func schedule(after delay: Duration, while occupant: Occupant, _ work: @escaping () -> Void) {
    orderOutTask?.cancel()
    orderOutTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.occupant == occupant else { return }
      work()
    }
  }

  /// A status or error line, in the one place Dilo says anything.
  ///
  /// Un mensaje es un resultado del contrato: dice qué pasó y se va solo. El
  /// plazo lo lleva la máquina y no un temporizador aparte — dos relojes
  /// sobre la misma forma terminan uno tapando al otro.
  func showMessage(_ text: String, on displayID: CGDirectDisplayID? = nil) {
    guard let screen = screen(preferring: displayID) else { return }
    decir(.aviso(text), texto: text, en: screen)
  }

  /// Un aviso que se arregla con un clic (`AvisoConAccion`). Entra por el
  /// mismo resultado del contrato que cualquier mensaje; lo distinto es que
  /// la forma toma el mouse mientras dura.
  func mostrarAviso(_ aviso: AvisoConAccion, on displayID: CGDirectDisplayID? = nil) {
    guard let screen = screen(preferring: displayID) else { return }
    decir(.accionable(aviso), texto: aviso.texto, en: screen)
  }

  /// Un resultado que no es de ninguna sesión —un aviso, una copia hecha
  /// desde un segmento— en la forma, con la pantalla ya elegida.
  private func decir(_ resultado: ResultadoDelNotch, texto text: String, en screen: HUDScreenSnapshot) {
    claim(.message, on: screen)
    recibir(.entregar(resultado))
    // hide() pins these for the retract, and claim() cancels that order-out.
    // A message is a new occupant and must not inherit them.
    dictationContent.isDismissing = false
    dictationContent.shapingName = nil
    dictationContent.shapingChoiceLabel = nil
    dictationContent.showsVoiceVisual = false
    dictationContent.text = text
    dictationContent.volatileText = ""
    revealDictation()
  }

  /// Ya no hay un temporizador de mensajes aparte: el plazo es el del
  /// resultado del contrato, y lo cancela el evento que abra la sesión
  /// siguiente.
  func cancelMessageDismiss() {}

  /// Reveals the dictation surface. It is always mounted — the root shows it
  /// whenever no drop state is up — so its reveal animates against a frame
  /// that already exists.
  func revealDictation() {
    guard !dictationContent.isRevealed else { return }
    commitParkedFrame()
    Task { @MainActor [dictationContent] in
      dictationContent.isRevealed = true
    }
  }

  /// Reveals a drop surface once its parked state has actually been drawn.
  ///
  /// The drop shape is inserted into the view tree at the same moment it is
  /// asked to open, and a view that has never rendered has no parked frame to
  /// spring from — both states collapse into one render and it appears already
  /// open. Forcing layout is not enough and there is no callback for "SwiftUI
  /// has drawn", so the flip waits one display cycle.
  func revealDrop() {
    guard !dropContent.isRevealed else { return }
    commitParkedFrame()
    Task { @MainActor [dropContent] in
      try? await Task.sleep(for: .milliseconds(20))
      dropContent.isRevealed = true
    }
  }

  /// Commits one frame in the parked state, so the reveal has something to
  /// animate from rather than drawing itself already open.
  private func commitParkedFrame() {
    hostingView.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
  }

  /// Rebuilds the root for this display and brings the window forward. The
  /// window's frame comes from the screen, never from the content.
  private func mount(on screen: HUDScreenSnapshot) {
    hostingView.rootView = HUDRootView(
      screen: screen,
      settings: renderedSettings,
      content: dictationContent,
      drop: dropContent,
      kind: sessionKind,
      onDrop: { [weak self] index in
        self?.onDropReceived?(index)
      },
      onCardEvent: { [weak self] event in
        self?.onCardEvent?(event)
      }
    )
    pantallaActual = screen
    // Con un encogimiento en curso la ventana se queda grande hasta que
    // termine: volver a medir la pantalla no es razón para cortar el cierre
    // por la mitad.
    aplicarEncuadre(encogerTask == nil ? encuadreNecesario : .abierta, en: screen)
    panel.assertOverlayOrder()
    actualizarPresencia()
    actualizarZonaInteractiva()
    // Al final: si cambian los lugares, los segmentos pueden pedir otra
    // ventana, y ese montaje tiene que encontrar éste terminado.
    actualizarLosLugares(de: screen)
  }

  private func evictDrop() {
    acceptsMouse = false
    dropContent.mode = .none
  }
}

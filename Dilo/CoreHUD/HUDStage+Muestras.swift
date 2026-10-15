#if DEBUG
import DiloConsumo
import Foundation

/// Lo que el arnés le pidió prestado a la forma, para devolverlo al soltar.
///
/// Guarda sólo lo que **dura más que una sesión** —los recientes, la reunión,
/// los modos, los datos de los costados, lo último dictado— y los cierres de
/// los botones. Lo de la sesión (el texto, la onda) no se guarda: lo limpia
/// `retract()` al soltar, y si un dictado de verdad interrumpe la muestra, lo
/// escribe esa sesión. Guardar el `languageTag`, por ejemplo, pisaría el que
/// el controlador de dictado acaba de poner justo antes de su `claim`.
struct MuestraEnCurso {
  var escena: EscenaDeMuestra
  /// La escena pide los dos costados con un dato aunque Ajustes no tenga
  /// ninguno: la silueta se monta con `anchoDeUnLado`.
  var conDatos = false
  /// La escena pide el panel del hover con todas sus secciones: la ventana
  /// abierta se dimensiona para `SeccionesDelPanel.todas`.
  var panelCompleto = false

  fileprivate let recientes: [ElementoReciente]
  fileprivate let proximaReunion: ProximaReunion?
  fileprivate let modosDelPanel: [ModoDelPanel]
  fileprivate let modoDelPanelID: String?
  fileprivate let ofreceNota: Bool
  fileprivate let traduccionDelPanel: TraduccionDelPanel?
  fileprivate let contexto: String?
  fileprivate let datoIzquierdo: LadoDeLaMuesca?
  fileprivate let datoDerecho: LadoDeLaMuesca?
  fileprivate let tomaGuardada: TimeInterval?
  fileprivate let retenidoAlCostado: TarjetaDeRespaldo?
  fileprivate let botones: Botones

  /// Los cierres que los botones de la forma llaman. Mientras dura la muestra
  /// quedan en nil: «Nota» y «Traducir» no abren un dictado, un reciente no se
  /// copia, un modo no se elige (los botones apagados del arnés).
  fileprivate struct Botones {
    var alTerminarSesionTrabada: (() -> Void)?
    var alDictarTraduciendo: (() -> Void)?
    var alElegirIdiomaDeTraduccion: (() -> Void)?
    var alCopiarReciente: ((ElementoReciente) -> Void)?
    var alElegirModo: ((String?) -> Void)?
    var alAbrirReunion: (() -> Void)?
    var alDictarNota: (() -> Void)?
    var alHacerClic: (() -> Void)?
    var alTocarLaTarjeta: ((TarjetaDeRespaldo) -> Void)?
    var alTocarSegmento: ((String) -> Void)?

    @MainActor
    init(de content: DictationHUDContent) {
      alTerminarSesionTrabada = content.alTerminarSesionTrabada
      alDictarTraduciendo = content.alDictarTraduciendo
      alElegirIdiomaDeTraduccion = content.alElegirIdiomaDeTraduccion
      alCopiarReciente = content.alCopiarReciente
      alElegirModo = content.alElegirModo
      alAbrirReunion = content.alAbrirReunion
      alDictarNota = content.alDictarNota
      alHacerClic = content.alHacerClic
      alTocarLaTarjeta = content.alTocarLaTarjeta
      alTocarSegmento = content.alTocarSegmento
    }

    @MainActor
    func poner(en content: DictationHUDContent) {
      content.alTerminarSesionTrabada = alTerminarSesionTrabada
      content.alDictarTraduciendo = alDictarTraduciendo
      content.alElegirIdiomaDeTraduccion = alElegirIdiomaDeTraduccion
      content.alCopiarReciente = alCopiarReciente
      content.alElegirModo = alElegirModo
      content.alAbrirReunion = alAbrirReunion
      content.alDictarNota = alDictarNota
      content.alHacerClic = alHacerClic
      content.alTocarLaTarjeta = alTocarLaTarjeta
      content.alTocarSegmento = alTocarSegmento
    }

    @MainActor
    static func apagar(en content: DictationHUDContent) {
      Botones(nada: ()).poner(en: content)
    }

    private init(nada: Void) {}
  }

  @MainActor
  fileprivate init(escena: EscenaDeMuestra, de stage: HUDStage) {
    let content = stage.dictationContent
    self.escena = escena
    tomaGuardada = stage.tomaGuardada
    retenidoAlCostado = stage.retenidoAlCostado
    recientes = content.recientes
    proximaReunion = content.proximaReunion
    modosDelPanel = content.modosDelPanel
    modoDelPanelID = content.modoDelPanelID
    ofreceNota = content.ofreceNota
    traduccionDelPanel = content.traduccionDelPanel
    contexto = content.contexto
    datoIzquierdo = content.datoIzquierdo
    datoDerecho = content.datoDerecho
    botones = Botones(de: content)
  }

  @MainActor
  fileprivate func devolver(a stage: HUDStage) {
    let content = stage.dictationContent
    stage.mostrarTomaGuardada(tomaGuardada)
    stage.ponerRetenidoAlCostado(retenidoAlCostado)
    content.recientes = recientes
    content.proximaReunion = proximaReunion
    content.modosDelPanel = modosDelPanel
    content.modoDelPanelID = modoDelPanelID
    content.ofreceNota = ofreceNota
    content.traduccionDelPanel = traduccionDelPanel
    content.contexto = contexto
    content.datoIzquierdo = datoIzquierdo
    content.datoDerecho = datoDerecho
    botones.poner(en: content)
  }
}

extension HUDStage {
  /// Dibuja una escena del arnés en la ventana real.
  ///
  /// Mueve la forma con las mismas puertas que una sesión —`claim`,
  /// `recibir(_:)`, `revealDictation`, `retract`— y nunca toca el controlador
  /// de dictado, el pegado ni EventKit: el estado se pide con eventos, como
  /// en todo el escenario, y lo que se ve es lo que la app dibujaría.
  func mostrarMuestra(_ escena: EscenaDeMuestra, texto: String?) {
    guard let pantalla = pantallaMontada ?? screen() else { return }
    if muestra == nil {
      muestra = MuestraEnCurso(escena: escena, de: self)
      MuestraEnCurso.Botones.apagar(en: dictationContent)
      control.congelado = true
    }
    muestra?.escena = escena
    dibujandoMuestra = true
    defer { dibujandoMuestra = false }

    let conDatos = escena.conDatos
    let panelCompleto = escena.panelCompleto
    if muestra?.conDatos != conDatos || muestra?.panelCompleto != panelCompleto {
      muestra?.conDatos = conDatos
      muestra?.panelCompleto = panelCompleto
      remontarConLosLadosActuales()
    }
    prepararLosDatos(conDatos)
    // Los segmentos salen y vuelven a entrar en cada escena: así se ve la
    // entrada con la palabra y no el resto de la escena anterior.
    let segmentos = escena.segmentos
    fijarLaPalabra(false)
    mostrarTomaGuardada(nil)
    ponerRetenidoAlCostado(nil)
    mostrarTomaGuardada(segmentos.toma ? 12 : nil)
    ponerRetenidoAlCostado(
      segmentos.retenido ? TarjetaDeRespaldo(texto: texto ?? escena.textoDeMuestra ?? "", porque: .sinConfirmar) : nil
    )
    switch escena.palabra {
    case .entra: break
    case .encogida: encogerLaPalabra()
    case .fija: fijarLaPalabra(true)
    }

    // Cada escena parte del reposo: lo que dejó la anterior —un panel
    // abierto, una onda montada— no se mezcla con lo que viene.
    dictationContent.punteroEncima = false
    dictationContent.panelDeVidrio = false
    dictationContent.showsVoiceVisual = false
    // Lo de la sesión que una escena de dictar pone: cada escena parte sin
    // par de idiomas y sin trabar. Una sesión de verdad los vuelve a poner.
    dictationContent.languageTag = nil
    dictationContent.trabada = false
    if occupant != .none { retract() }

    let linea = texto ?? escena.textoDeMuestra ?? ""
    switch escena {
    case .reposo, .reposoConDatos, .segmentoToma, .segmentoRetenido, .dosSegmentos, .segmentosEncogidos,
      .segmentosConPalabra, .segmentoConDatos:
      reaplicarElEstado()

    case .hover, .hoverCompleto, .hoverVidrio, .hoverCompletoVidrio, .hoverSinIdioma:
      dictationContent.contexto = linea
      if escena.panelCompleto { llenarElPanel() }
      if escena == .hoverSinIdioma { dictationContent.traduccionDelPanel = .sinDestino }
      dictationContent.panelDeVidrio = escena.conVidrio
      dictationContent.punteroEncima = true
      reaplicarElEstado()

    case .cargandoModelo, .faltaMicrofono:
      guard case let .preparando(falta) = escena.estado else { return }
      claim(.dictation, on: pantalla)
      recibir(.preparar(falta))
      decir(falta.texto)
      revealDictation()

    case .dictando, .dictandoLargo, .dictandoConSegmentos, .dictandoTraduciendo:
      claim(.dictation, on: pantalla)
      if escena == .dictandoTraduciendo {
        dictationContent.languageTag = "ES → EN"
        dictationContent.trabada = true
      }
      recibir(.escuchar)
      escucharDeMentira()
      decir(linea)
      revealDictation()

    case .procesando:
      claim(.dictation, on: pantalla)
      recibir(.escuchar)
      recibir(.procesar)
      decir(linea)
      revealDictation()

    case .acuse, .copiado, .retenido:
      let resultado: ResultadoDelNotch
      switch escena {
      case .acuse: resultado = .listo
      case .copiado: resultado = .copiado
      default: resultado = .retenido(TarjetaDeRespaldo(texto: linea, porque: .sinConfirmar))
      }
      claim(.dictation, on: pantalla)
      recibir(.escuchar)
      recibir(.entregar(resultado))
      decir(resultado.esAcuse ? "" : resultado.texto)
      revealDictation()

    case .avisoLargo, .aviso:
      claim(.message, on: pantalla)
      recibir(.entregar(.aviso(linea)))
      decir(linea)
      revealDictation()

    case .avisoConArreglo:
      claim(.message, on: pantalla)
      recibir(.entregar(.accionable(EscenaDeMuestra.arregloDeMuestra)))
      decir(EscenaDeMuestra.arregloDeMuestra.texto)
      revealDictation()
    }
  }

  /// Devuelve la forma a su estado real: el reposo, con lo que había antes.
  func soltarMuestra() {
    guard let muestra else { return }
    devolver(muestra)
    retract()
    remontarConLosLadosActuales()
    reaplicarElEstado()
  }

  /// Un `claim` de verdad llegó con una muestra puesta. La forma ya es de la
  /// sesión: se devuelve lo prestado sin retraer nada, y el arnés se entera
  /// para no seguir con el guion.
  func interrumpirMuestra() {
    guard let muestra else { return }
    devolver(muestra)
    remontarConLosLadosActuales()
    alInterrumpirLaMuestra?()
  }

  private func devolver(_ prestado: MuestraEnCurso) {
    self.muestra = nil
    control.congelado = false
    dictationContent.punteroEncima = false
    dictationContent.panelDeVidrio = false
    fijarLaPalabra(false)
    prestado.devolver(a: self)
  }

  private func decir(_ texto: String) {
    dictationContent.text = texto
    dictationContent.volatileText = ""
  }

  /// La onda viva sin micrófono: niveles congelados con forma de sílaba.
  private func escucharDeMentira() {
    let niveles: [Float] = [0.18, 0.46, 0.72, 0.95, 0.61, 0.33, 0.78, 0.52, 0.24]
    var historia = [Float](repeating: 0, count: HUDWaveformView.barCount)
    for i in historia.indices { historia[i] = niveles[i % niveles.count] }
    dictationContent.levelHistory = historia
    dictationContent.audioLevel = 0.6
    dictationContent.isAudioAlive = true
    dictationContent.isDismissing = false
    dictationContent.showsVoiceVisual = true
  }

  private func prepararLosDatos(_ conDatos: Bool) {
    guard conDatos else { return }
    dictationContent.datoIzquierdo = LadoDeLaMuesca(dato: .codex, valor: "35%", nivel: 35)
    dictationContent.datoDerecho = LadoDeLaMuesca(dato: .cpu, valor: "12%", nivel: 12)
  }

  /// Todas las secciones del panel, con lo más largo que pueden llevar.
  private func llenarElPanel() {
    let ahora = Date()
    dictationContent.recientes = []
    dictationContent.agregarReciente(
      "y entonces le dije que el informe tenía que estar listo el jueves", origen: .dictado,
      cuando: ahora.addingTimeInterval(-600)
    )
    dictationContent.agregarReciente("https://dilo.app/notas/4521", origen: .copiado, cuando: ahora.addingTimeInterval(-120))
    dictationContent.agregarReciente("quedamos el martes a las diez", origen: .dictado, cuando: ahora)
    dictationContent.proximaReunion = ProximaReunion(
      titulo: "Revisión semanal con el equipo de producto",
      empieza: ahora.addingTimeInterval(8 * 60),
      termina: ahora.addingTimeInterval(38 * 60),
      enlace: URL(string: "https://meet.google.com/abc-defg-hij")
    )
    dictationContent.modosDelPanel = [
      ModoDelPanel(id: "correo", nombre: "Correo"),
      ModoDelPanel(id: "mensaje", nombre: "Mensaje"),
      ModoDelPanel(id: "codigo", nombre: "Código"),
    ]
    dictationContent.modoDelPanelID = "correo"
    dictationContent.ofreceNota = true
    dictationContent.traduccionDelPanel = .hacia("EN")
  }
}
#endif

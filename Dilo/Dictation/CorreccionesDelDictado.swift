import AppKit
import DiloCapabilities
import DiloText

/// Lo que una oferta de aprender dice en la muesca: primero la pregunta,
/// y si se aceptó, el deshacer por unos segundos.
struct OfertaDeAprendizaje: Equatable, Sendable {
  enum Fase: Equatable, Sendable {
    case pregunta
    /// Aceptada: lo que se agregó, que es exactamente lo que deshacer quita.
    case aprendido(LoAprendido)
  }

  let pares: [ParDeCorreccion]
  /// Los que el revisor dijo que Tus palabras arregla solos: aceptarlos no
  /// agrega una regla a «Cuando digo…» (`RevisionDeCorrecciones.aplicar`).
  var soloTusPalabras: Set<ParDeCorreccion> = []
  var fase: Fase = .pregunta

  /// Dónde se sienta. Un id por fase: al pasar a «Deshacer» el segmento
  /// vuelve a decir su palabra (`PalabraDeLosSegmentos.aparecio`).
  var actividad: ActividadDeLaMuesca {
    fase == .pregunta ? .ofertaDeAprendizaje : .aprendizajeHecho
  }

  /// Lo que dice el segmento. La palabra es corta porque el segmento mide a
  /// lo más 100 puntos; el detalle entero va en el tooltip y en VoiceOver.
  var segmento: ContenidoDelSegmento {
    let terminos = pares.map(\.correcto).joined(separator: ", ")
    switch fase {
    case .pregunta:
      let detalle = pares.count == 1
        ? String(localized: "Agregar «\(pares[0].correcto)» a Tus palabras: oí «\(pares[0].oido)»")
        : String(localized: "Agregar a Tus palabras: \(terminos)")
      return ContenidoDelSegmento(
        id: actividad.id, simbolo: "text.badge.plus",
        texto: String(localized: "Aprender"), destacada: true, accesibilidad: detalle
      )
    case .aprendido:
      return ContenidoDelSegmento(
        id: actividad.id, simbolo: "arrow.uturn.backward",
        texto: String(localized: "Deshacer"), destacada: false,
        accesibilidad: String(localized: "Sacar de Tus palabras: \(terminos)")
      )
    }
  }
}

extension ActividadDeLaMuesca {
  /// Dilo vio que corregiste una palabra y ofrece aprenderla. Sólo costado:
  /// nunca le quita la forma a nadie, y a la izquierda, donde la barra deja
  /// los menús, si el retenido no la tiene.
  static let ofertaDeAprendizaje = ActividadDeLaMuesca(
    id: "aprender", prioridad: .normal, puedeSerPrincipal: false, ladoPreferido: .izquierda
  )
  /// Lo recién aprendido, con su deshacer.
  static let aprendizajeHecho = ActividadDeLaMuesca(
    id: "aprendido", prioridad: .normal, puedeSerPrincipal: false, ladoPreferido: .izquierda
  )
}

/// El ciclo entero de aprender de una corrección: vigilar el campo después
/// de pegar, sacar los pares, ofrecerlos en la muesca y, sólo si la persona
/// acepta, agregarlos a Tus palabras con deshacer.
///
/// **Nunca aprende solo**: una oferta que nadie toca vence y se olvida, y lo
/// que no se aceptó no se vuelve a ofrecer mientras Dilo siga abierto. Los
/// rechazados viven en RAM: la lista de lo que alguien corrigió no se
/// escribe en ningún lado.
///
/// **Con Claude** (`revisar`, prendido de fábrica si hay clave): lo que el
/// filtro determinista propone pasa por un modelo antes de ofrecerse. El
/// modelo descarta lo que no es vocabulario y dice si basta Tus palabras; la
/// oferta llega uno o dos segundos más tarde. Si el modelo no contesta en
/// plazo, no hay clave o no hay red, se ofrece lo determinista como siempre.
@MainActor
final class CorreccionesDelDictado {
  /// Lo que dura la pregunta a la vista.
  static let duracionDeLaPregunta = Duration.seconds(20)
  /// Lo que dura el deshacer después de aceptar.
  static let duracionDelDeshacer = Duration.seconds(6)

  private let settings: AppSettings
  let vigia: VigiaDeCorrecciones
  /// El diccionario de español (`NSSpellChecker`); un test pone el suyo.
  var esPalabraConocida: (String) -> Bool = { esPalabraEspanola($0) }
  var reloj: DeadlineClock = .continuous
  var anfitrion: any HostCapabilities = Anfitrion.actual
  /// La muesca: muestra o retira la oferta. Lo cablea `AppDelegate`.
  var alCambiarLaOferta: ((OfertaDeAprendizaje?) -> Void)?
  /// La segunda mirada, con Claude: el veredicto de cada candidato, o nil si
  /// no hubo (sin clave, sin red, fuera de plazo, respuesta ilegible). Nil
  /// entero —los tests, o sin cablear— es lo determinista de siempre. Lo
  /// cablea `AppDelegate` (`AprendizajeConClaude.revisar`).
  var revisar: (@Sendable (_ candidatos: [CandidatoParaRevisar], _ modelo: String) async -> [ParDeCorreccion: TipoDeAprendizaje]?)?
  /// Se llama después de aprender algo: el orden del diccionario mira si le
  /// toca (`OrdenadorDelDiccionario`).
  var alAprender: (() -> Void)?

  private(set) var oferta: OfertaDeAprendizaje?
  private var rechazados: Set<ParDeCorreccion> = []
  private var vencimiento: Task<Void, Never>?
  /// La revisión en curso. Un dictado nuevo o una corrección nueva la
  /// cancela: una oferta vieja que llega tarde confunde.
  private(set) var revision: Task<Void, Never>?

  init(settings: AppSettings, vigia: VigiaDeCorrecciones = VigiaDeCorrecciones()) {
    self.settings = settings
    self.vigia = vigia
  }

  /// Empieza a mirar el campo del dictado recién pegado.
  ///
  /// - Parameters:
  ///   - pegado: lo que se pegó.
  ///   - crudo: lo que escribió el motor. Sólo se aprende lo que el motor
  ///     oyó mal, no lo que un modo reescribió.
  ///   - ancla: el campo, tomado al empezar el dictado. Se pasa antes del
  ///     `sessionEnded` que lo borra del controlador.
  ///   - leer: el valor del campo, fuera del actor principal.
  func vigilar(
    pegado: String, crudo: String, ancla: AnclaDelFoco,
    leer: @escaping @Sendable (AnclaDelFoco) async -> String?
  ) {
    guard settings.aprenderDeCorrecciones, anfitrion.admite(.vigiaDeCorrecciones) else { return }
    vigia.vigilar(pegado: pegado, leerValor: { await leer(ancla) }) { [weak self] editado in
      self?.evaluar(pegado: pegado, editado: editado, crudo: crudo)
    }
  }

  func detener() {
    vigia.detener()
    revision?.cancel()
    revision = nil
  }

  /// Lo pegado, editado: qué ofrecer, si algo. Interna para los tests.
  func evaluar(pegado: String, editado: String, crudo: String) {
    let candidatos = AprendizajeDeCorrecciones.soloDelMotor(
      AprendizajeDeCorrecciones.pares(
        pegado: pegado, editado: editado, esPalabraConocida: esPalabraConocida
      ),
      crudo: crudo
    )
    let nuevos = candidatos.filter { par in
      !rechazados.contains(par) && !TusPalabrasAprendidas.yaSeSabe(
        par, palabras: settings.palabrasPropias, reemplazos: settings.reemplazos
      )
    }
    let pares = Array(nuevos.prefix(AprendizajeDeCorrecciones.maximoPorDictado))
    guard !pares.isEmpty else { return }
    revision?.cancel()
    revision = nil
    guard let revisar, settings.aprenderConClaude else {
      ofrecer(pares)
      return
    }
    // Sólo el pedazo alrededor de cada cambio viaja: nunca el campo entero.
    let paraRevisar = RevisionDeCorrecciones.candidatos(pares, pegado: pegado, editado: editado)
    let modelo = settings.modeloParaRevisar
    revision = Task { [weak self] in
      let veredictos = await revisar(paraRevisar, modelo)
      guard !Task.isCancelled, let self else { return }
      revision = nil
      guard let veredictos else {
        ofrecer(pares)
        return
      }
      let revisados = RevisionDeCorrecciones.aplicar(veredictos, a: pares)
      // Lo que el revisor descartó no se vuelve a preguntar en esta sesión.
      rechazados.formUnion(pares.filter { !revisados.pares.contains($0) })
      guard !revisados.pares.isEmpty else { return }
      ofrecer(revisados.pares, soloTusPalabras: revisados.soloTusPalabras)
    }
  }

  private func ofrecer(_ pares: [ParDeCorreccion], soloTusPalabras: Set<ParDeCorreccion> = []) {
    // Una pregunta pendiente que nadie contestó se da por no.
    if let anterior = oferta, anterior.fase == .pregunta {
      rechazados.formUnion(anterior.pares)
    }
    mostrar(
      OfertaDeAprendizaje(pares: pares, soloTusPalabras: soloTusPalabras),
      por: Self.duracionDeLaPregunta
    )
  }

  /// Un clic en el segmento: en la pregunta, aprender; en el deshacer,
  /// deshacer.
  func tocar() {
    guard let oferta else { return }
    switch oferta.fase {
    case .pregunta:
      var palabras = settings.palabrasPropias
      var reemplazos = settings.reemplazos
      let hecho = TusPalabrasAprendidas.aprender(
        oferta.pares, soloTusPalabras: oferta.soloTusPalabras,
        palabras: &palabras, reemplazos: &reemplazos
      )
      settings.palabrasPropias = palabras
      settings.reemplazos = reemplazos
      settings.palabrasAprendidas += hecho.palabrasNuevas
      settings.aprendidasDesdeElOrden += hecho.palabrasNuevas.count + hecho.reemplazosNuevos.count
      mostrar(
        OfertaDeAprendizaje(pares: oferta.pares, soloTusPalabras: oferta.soloTusPalabras, fase: .aprendido(hecho)),
        por: Self.duracionDelDeshacer
      )
      alAprender?()
    case let .aprendido(hecho):
      var palabras = settings.palabrasPropias
      var reemplazos = settings.reemplazos
      TusPalabrasAprendidas.deshacer(hecho, palabras: &palabras, reemplazos: &reemplazos)
      settings.palabrasPropias = palabras
      settings.reemplazos = reemplazos
      settings.palabrasAprendidas.removeAll { hecho.palabrasNuevas.contains($0) }
      settings.aprendidasDesdeElOrden = max(
        0, settings.aprendidasDesdeElOrden - hecho.palabrasNuevas.count - hecho.reemplazosNuevos.count
      )
      rechazados.formUnion(oferta.pares)
      mostrar(nil, por: nil)
    }
  }

  private func mostrar(_ nueva: OfertaDeAprendizaje?, por duracion: Duration?) {
    vencimiento?.cancel()
    vencimiento = nil
    oferta = nueva
    alCambiarLaOferta?(nueva)
    guard let duracion, nueva != nil else { return }
    vencimiento = Task { [weak self, reloj] in
      try? await reloj.sleep(duracion)
      guard !Task.isCancelled, let self else { return }
      vencer()
    }
  }

  /// Nadie contestó: la pregunta se da por no y no se vuelve a hacer; el
  /// deshacer, simplemente se va.
  private func vencer() {
    if let oferta, oferta.fase == .pregunta { rechazados.formUnion(oferta.pares) }
    mostrar(nil, por: nil)
  }
}

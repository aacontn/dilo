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

  private(set) var oferta: OfertaDeAprendizaje?
  private var rechazados: Set<ParDeCorreccion> = []
  private var vencimiento: Task<Void, Never>?

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
    // Una pregunta pendiente que nadie contestó se da por no.
    if let anterior = oferta, anterior.fase == .pregunta {
      rechazados.formUnion(anterior.pares)
    }
    mostrar(OfertaDeAprendizaje(pares: pares), por: Self.duracionDeLaPregunta)
  }

  /// Un clic en el segmento: en la pregunta, aprender; en el deshacer,
  /// deshacer.
  func tocar() {
    guard let oferta else { return }
    switch oferta.fase {
    case .pregunta:
      var palabras = settings.palabrasPropias
      var reemplazos = settings.reemplazos
      let hecho = TusPalabrasAprendidas.aprender(oferta.pares, palabras: &palabras, reemplazos: &reemplazos)
      settings.palabrasPropias = palabras
      settings.reemplazos = reemplazos
      mostrar(OfertaDeAprendizaje(pares: oferta.pares, fase: .aprendido(hecho)), por: Self.duracionDelDeshacer)
    case let .aprendido(hecho):
      var palabras = settings.palabrasPropias
      var reemplazos = settings.reemplazos
      TusPalabrasAprendidas.deshacer(hecho, palabras: &palabras, reemplazos: &reemplazos)
      settings.palabrasPropias = palabras
      settings.reemplazos = reemplazos
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

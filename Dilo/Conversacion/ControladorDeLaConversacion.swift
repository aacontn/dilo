import DiloEngines
import DiloModes
import Foundation
import Synchronization
import os

/// La **Conversación**: hablarle a Dilo y que conteste en voz alta, como una
/// llamada.
///
/// Sólo el pensar va en línea. Lo que dices lo transcribe el **Motor de voz**
/// del dictado, en el Mac (`MotorParaConversar`); Claude contesta por la API
/// de Anthropic con la clave de siempre, en streaming
/// (`ClienteDeConversacion`); y la respuesta la dice una voz del Mac
/// (`VozQueContesta`). El audio nunca sale del Mac: sólo viaja texto. Lo
/// conversado vive en RAM mientras dura la llamada y se olvida al colgar;
/// al log van tiempos, modelo y cuentas.
///
/// Los turnos son half duplex (`MaquinaDeLaConversacion`), el modelo de cada
/// turno lo elige `RouterDeModelos`, el fin de tu turno lo dice
/// `FinDelTurno` o soltar el gatillo, y el gasto del mes tiene tope
/// (`TopeDeGasto`). Todo eso es regla pura en `DiloModes`; acá sólo se
/// ejecuta.
@MainActor
final class ControladorDeLaConversacion {
  /// Cada cuánto se mira el silencio mientras escucha. También es cada
  /// cuánto se redibuja el punto del nivel: siete veces por segundo basta
  /// para que se vea vivo y no cuesta nada.
  static let cadaCuantoMirar: Duration = .milliseconds(150)
  /// Sostener el gatillo menos que esto y soltarlo sin voz no termina el
  /// turno: fue un toque, no un turno.
  static let sostenidoMinimo: Duration = .milliseconds(400)
  /// Cuántas líneas de lo conversado guarda la barra para mostrar.
  static let lineasEnLaBarra = 12

  private let settings: AppSettings
  private let stage: HUDStage
  private let motor: MotorParaConversar?
  private let voz: any VozQueContesta
  /// La clave de Anthropic, leída del Llavero fuera del hilo principal en
  /// el momento de usarla. No se guarda.
  private let leerClave: @Sendable () async -> String?

  /// Conversando sí o no: el panel de la barra lo dice.
  var alCambiar: ((Bool) -> Void)?
  /// Si hay un dictado en curso: con uno no se empieza a conversar (el
  /// motor de voz es uno).
  var hayDictado: () -> Bool = { false }

  private var maquina = MaquinaDeLaConversacion()
  private var router = RouterDeModelos()
  private var historial: [MensajeDeLaConversacion] = []
  private var contadorDeLineas = 0

  /// Lo que el audio va midiendo, escrito desde el hilo de audio y leído
  /// por el vigía: con un candado y sin saltar al hilo principal por cada
  /// búfer.
  private let medidor = Medidor()
  private final class Medidor: Sendable {
    struct Medicion {
      var fin: FinDelTurno?
      var nivel: Float = 0
      var escucha = 0
    }

    let candado = Mutex(Medicion())

    func withLock<T: Sendable>(_ cuerpo: (inout sending Medicion) -> sending T) -> T {
      candado.withLock(cuerpo)
    }
  }

  /// Sube cada vez que se abre el micrófono: lo que llega de una escucha
  /// anterior no cuenta.
  private var escucha = 0
  private var sostenidoDesde: ContinuousClock.Instant?
  private var vigia: Task<Void, Never>?
  private var consulta: Task<Void, Never>?
  /// Las operaciones del motor, en fila: empezar, terminar y cancelar
  /// tienen que llegar en orden aunque la persona interrumpa rápido.
  private var filaDelMotor: Task<Void, Never>?
  /// Lo que Claude lleva contestado en este turno, por si lo interrumpen.
  private var contestado = ""
  /// Después de un aviso que no tiene arreglo en la llamada —falta la
  /// clave, se llegó al tope—, colgar cuando termine de decirlo.
  private var colgarAlTerminar = false

  private var inicioDeLaSesion: ContinuousClock.Instant?
  private var turnos = 0
  private var porModelo: [NivelDeModelo: Int] = [:]
  private var costoDeLaSesion = 0.0
  private var voces: [VocesEnEspanol.Voz] = []
  private var microfonos: [(eleccion: EleccionDeMicrofono, nombre: String)] = []

  init(
    settings: AppSettings,
    stage: HUDStage,
    motor: MotorParaConversar?,
    voz: any VozQueContesta = VozDelSistema(),
    leerClave: @escaping @Sendable () async -> String? = {
      await Task.detached(priority: .userInitiated) {
        Llavero().clave(para: Proveedor.anthropicDeFabrica.cuentaEnElLlavero)
      }.value
    }
  ) {
    self.settings = settings
    self.stage = stage
    self.motor = motor
    self.voz = voz
    self.leerClave = leerClave
    self.voz.alEmpezar = { [weak self] in self?.aplicar(.empezoAHablar) }
    self.voz.alTerminar = { [weak self] in self?.terminoDeHablar() }
  }

  var enCurso: Bool { maquina.estado != .colgada }

  // Lo que entra de afuera

  /// El panel de la barra y el atajo «Conversar con Dilo»: llamar o colgar.
  func alternar() {
    enCurso ? colgar() : llamar()
  }

  /// La tecla de conversar, o cualquier gatillo mientras hay conversación.
  /// Apretar te da el turno —interrumpe si Dilo hablaba—; soltar lo termina
  /// si hablaste.
  func gatillo(apretado: Bool) {
    if apretado {
      sostenidoDesde = .now
      guard enCurso else {
        llamar()
        return
      }
      if maquina.silenciada { aplicar(.silenciar(false)) }
      if maquina.estado == .pensando || maquina.estado == .hablando { aplicar(.interrumpir) }
      return
    }
    guard let desde = sostenidoDesde else { return }
    sostenidoDesde = nil
    guard maquina.estado == .escuchando else { return }
    let hubo = medidor.withLock { $0.fin?.huboVoz ?? false }
    if hubo || ContinuousClock.now - desde >= Self.sostenidoMinimo { aplicar(.terminoTuTurno) }
  }

  func colgar() {
    guard enCurso else { return }
    aplicar(.colgar)
    stage.cerrarLaConversacion()
    anotarElResumen()
    historial = []
    router = RouterDeModelos()
    contestado = ""
    colgarAlTerminar = false
    vigia?.cancel()
    vigia = nil
    alCambiar?(false)
  }

  // Llamar

  private func llamar() {
    guard !enCurso, let motor else { return }
    guard !hayDictado() else { return }
    Task {
      guard await leerClave() != nil else {
        stage.showMessage(String(localized: "Falta la clave de Anthropic"))
        return
      }
      guard TopeDeGasto.puedeLlamar(settings.conversacionGasto, tope: settings.conversacionTope, ahora: Date()) else {
        stage.showMessage(String(localized: "Llegaste al tope del mes para conversar"))
        return
      }
      guard !enCurso else { return }
      empezar(motor)
    }
  }

  private func empezar(_ motor: MotorParaConversar) {
    inicioDeLaSesion = .now
    turnos = 0
    porModelo = [:]
    costoDeLaSesion = 0
    contadorDeLineas = 0
    voz.ajustar(ajustesDeLaVoz)
    var foto = FotoDeLaConversacion()
    foto.modelos = opcionesDeModelo
    stage.conversacionContent.foto = foto
    stage.conversacionContent.acciones = acciones
    refrescarLosAjustes()
    stage.abrirLaConversacion(dibujandoCon: settings.sessionSettingsParaDibujar)
    aplicar(.llamar)
    alCambiar?(true)
    AppLog.conversacion.notice("llamada: empieza (modelo \(self.settings.conversacionModelo.rawValue, privacy: .public))")
    Task { [weak self] in
      let voces = await VocesEnEspanol.leer()
      let entradas = await Task.detached(priority: .utility) { DispositivosDeAudio.entradas() }.value
      self?.voces = voces
      self?.microfonos = [
        (.automatico, String(localized: "Automático")),
        (.delSistema, String(localized: "El del sistema")),
      ] + entradas.map { (EleccionDeMicrofono.elegido(uid: $0.uid, nombre: $0.nombre), $0.nombre) }
      self?.refrescarLosAjustes()
    }
  }

  // La máquina

  private func aplicar(_ evento: MaquinaDeLaConversacion.Evento) {
    let efectos = maquina.recibir(evento)
    refrescarElEstado()
    for efecto in efectos { ejecutar(efecto) }
  }

  private func ejecutar(_ efecto: MaquinaDeLaConversacion.Efecto) {
    switch efecto {
    case .abrirMicrofono: escuchar()
    case let .cerrarMicrofono(entregar): cerrarElMicrofono(entregar: entregar)
    case .consultar: consultar()
    case .cancelarConsulta: cancelarLaConsulta()
    case .callarLaVoz: voz.detener()
    }
  }

  private func terminoDeHablar() {
    if colgarAlTerminar {
      colgar()
      return
    }
    aplicar(.terminoDeHablar)
  }

  // Tu turno

  private func escuchar() {
    guard let motor else { return }
    escucha += 1
    let esta = escucha
    medidor.withLock { $0 = Medidor.Medicion(fin: FinDelTurno(inicio: .now), nivel: 0, escucha: esta) }
    stage.conversacionContent.foto.parcial = ""
    let identificador = settings.recognitionLocaleIdentifier
    let eleccion = settings.conversacionMicrofono
    let medidor = medidor
    let handlers = EngineHandlers(
      parcial: { [weak self] update in
        let texto = update.texto
        Task { @MainActor in self?.parcial(texto, escucha: esta) }
      },
      falla: { [weak self] mensaje in
        Task { @MainActor in self?.fallaDelMotor(mensaje, escucha: esta) }
      },
      nivel: { nivel in
        medidor.withLock { medicion in
          guard medicion.escucha == esta else { return }
          medicion.nivel = nivel
          medicion.fin?.muestra(nivel: nivel, en: .now)
        }
      }
    )
    enFila { [weak self] in
      do {
        let locale = try await motor.locale(identificador)
        try await motor.empezar(locale, eleccion, handlers)
      } catch {
        self?.fallaDelMotor(error.localizedDescription, escucha: esta)
      }
    }
    vigilar(esta)
  }

  /// Mira el silencio y el nivel mientras dura esta escucha.
  private func vigilar(_ esta: Int) {
    vigia?.cancel()
    vigia = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.cadaCuantoMirar)
        guard let self, !Task.isCancelled, esta == escucha, maquina.microfonoAbierto else { return }
        let ahora = ContinuousClock.now
        let (nivel, termino, nadie) = medidor.withLock { medicion in
          (medicion.nivel, medicion.fin?.termino(en: ahora) ?? false, medicion.fin?.nadieHabla(en: ahora) ?? false)
        }
        stage.conversacionContent.foto.nivel = nivel
        guard sostenidoDesde == nil else { continue }
        if termino {
          aplicar(.terminoTuTurno)
          return
        }
        if nadie {
          AppLog.conversacion.notice("llamada: cuelga sola, nadie habló")
          colgar()
          return
        }
      }
    }
  }

  private func parcial(_ texto: String, escucha esta: Int) {
    guard esta == escucha, maquina.estado == .escuchando else { return }
    stage.conversacionContent.foto.parcial = texto
  }

  private func cerrarElMicrofono(entregar: Bool) {
    vigia?.cancel()
    vigia = nil
    stage.conversacionContent.foto.nivel = 0
    guard let motor else { return }
    let esta = escucha
    guard entregar else {
      enFila { await motor.cancelar() }
      return
    }
    let soltado = ContinuousClock.now
    enFila { [weak self] in
      let texto = (try? await motor.terminar()) ?? ""
      let transcribir = ContinuousClock.now - soltado
      self?.transcrito(texto, escucha: esta, transcribir: transcribir)
    }
  }

  private func transcrito(_ texto: String, escucha esta: Int, transcribir: Duration) {
    guard esta == escucha, maquina.estado == .pensando else { return }
    let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
    stage.conversacionContent.foto.parcial = ""
    guard !limpio.isEmpty else {
      aplicar(.transcrito(vacio: true))
      return
    }
    AppLog.conversacion.info("turno \(self.turnos + 1): transcrito en \(Self.ms(transcribir), privacy: .public)")
    agregarDeLaPersona(limpio)
    aplicar(.transcrito(vacio: false))
  }

  private func fallaDelMotor(_ mensaje: String, escucha esta: Int) {
    guard esta == escucha, enCurso else { return }
    AppLog.conversacion.error("llamada: el motor de voz falló: \(mensaje, privacy: .public)")
    stage.conversacionContent.foto.aviso = String(localized: "No pude escucharte")
    colgarAlTerminar = true
    voz.decir(String(localized: "No pude abrir el micrófono, así que corto acá."))
    voz.cerrarElTurno()
  }

  // El turno de Dilo

  private func consultar() {
    guard let dicho = historial.last, dicho.rol == .persona else {
      aplicar(.transcrito(vacio: true))
      return
    }
    let decision = router.decidir(dicho.texto, eleccion: settings.conversacionModelo)
    turnos += 1
    porModelo[decision.nivel, default: 0] += 1
    stage.conversacionContent.foto.modelo = decision.nivel.nombreCorto
    stage.conversacionContent.foto.aviso = nil

    guard TopeDeGasto.puedeLlamar(settings.conversacionGasto, tope: settings.conversacionTope, ahora: Date()) else {
      AppLog.conversacion.notice("turno \(self.turnos): no se llama, se llegó al tope del mes")
      decirUnAviso(
        String(localized: "Llegaste al tope de gasto de este mes para conversar. Lo puedes subir en Ajustes, en Claude."),
        enLaBarra: String(localized: "Tope del mes"),
        yColgar: true
      )
      return
    }

    let pedido = PedidoDeConversacion(nivel: decision.nivel, historial: historial)
    let numero = turnos
    let leerClave = leerClave
    contestado = ""
    consulta = Task { [weak self] in
      let inicio = ContinuousClock.now
      var trozos = TrozosParaDecir()
      var primerPedazo: Duration?
      do {
        let cliente = ClienteDeConversacion(clave: await leerClave())
        for try await evento in cliente.responder(pedido) {
          guard let self, !Task.isCancelled else { return }
          switch evento {
          case let .texto(pedazo):
            if primerPedazo == nil { primerPedazo = .now - inicio }
            contestado += pedazo
            for oracion in trozos.agregar(pedazo) { voz.decir(oracion) }
          case let .fin(uso, cortada):
            if let resto = trozos.terminar() { voz.decir(resto) }
            terminarElTurno(
              numero: numero, decision: decision, uso: uso, cortada: cortada,
              primerPedazo: primerPedazo, total: .now - inicio
            )
          }
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        let falla = error as? FallaDeClaude ?? .respuestaInutil
        AppLog.conversacion.error(
          "turno \(numero): \(decision.nivel.rawValue, privacy: .public) falló: \(falla.nombreEnElLog, privacy: .public)"
        )
        fallaDeClaude(falla)
      }
    }
  }

  private func terminarElTurno(
    numero: Int, decision: RouterDeModelos.Decision, uso: UsoDeTokens, cortada: Bool,
    primerPedazo: Duration?, total: Duration
  ) {
    consulta = nil
    let respuesta = contestado.trimmingCharacters(in: .whitespacesAndNewlines)
    contestado = ""
    if !respuesta.isEmpty {
      historial.append(MensajeDeLaConversacion(.dilo, respuesta))
      agregarLinea(respuesta, deDilo: true)
    }
    let costo = CostosDeClaude.costo(de: uso, modelo: decision.nivel.modelo.id) ?? 0
    costoDeLaSesion += costo
    settings.conversacionGasto = TopeDeGasto.sumar(costo, a: settings.conversacionGasto, ahora: Date())
    stage.conversacionContent.foto.costo = Self.dolares(costoDeLaSesion)
    AppLog.conversacion.notice(
      """
      turno \(numero): \(decision.nivel.rawValue, privacy: .public) (\(decision.motivo.rawValue, privacy: .public), \
      esfuerzo \(decision.nivel.esfuerzo, privacy: .public)) primer pedazo \(Self.ms(primerPedazo), privacy: .public), \
      total \(Self.ms(total), privacy: .public), tokens \(uso.entrada)+\(uso.escritosEnCache)w+\(uso.leidosDeCache)r/\(uso.salida)\
      \(cortada ? " cortada" : "", privacy: .public), US$\(costo, format: .fixed(precision: 5), privacy: .public)
      """
    )
    voz.cerrarElTurno()
  }

  /// La interrupción: lo que Claude alcanzó a contestar queda en lo
  /// conversado con una marca, para que el turno siguiente sepa dónde lo
  /// cortaron.
  private func cancelarLaConsulta() {
    consulta?.cancel()
    consulta = nil
    let alcanzo = contestado.trimmingCharacters(in: .whitespacesAndNewlines)
    contestado = ""
    guard !alcanzo.isEmpty else { return }
    historial.append(MensajeDeLaConversacion(.dilo, alcanzo + " —"))
    agregarLinea(alcanzo + " —", deDilo: true)
  }

  private func fallaDeClaude(_ falla: FallaDeClaude) {
    consulta = nil
    contestado = ""
    let sinArreglo = falla == .faltaLaClave || falla == .claveRechazada
    decirUnAviso(falla.dichoEnLaConversacion, enLaBarra: falla.aviso, yColgar: sinArreglo)
  }

  /// Un aviso dicho en voz alta y escrito en la barra. La voz es la que
  /// cierra el turno: al terminar de decirlo, la conversación sigue o cuelga.
  private func decirUnAviso(_ dicho: String, enLaBarra: String, yColgar: Bool) {
    stage.conversacionContent.foto.aviso = enLaBarra
    colgarAlTerminar = colgarAlTerminar || yColgar
    voz.decir(dicho)
    voz.cerrarElTurno()
  }

  // Lo conversado

  /// Lo que dijiste. Dos seguidos —un turno que Claude no alcanzó a
  /// contestar— van juntos: la API quiere turnos alternados.
  private func agregarDeLaPersona(_ texto: String) {
    if let ultimo = historial.last, ultimo.rol == .persona {
      historial[historial.count - 1] = MensajeDeLaConversacion(.persona, ultimo.texto + " " + texto)
    } else {
      historial.append(MensajeDeLaConversacion(.persona, texto))
    }
    agregarLinea(texto, deDilo: false)
  }

  private func agregarLinea(_ texto: String, deDilo: Bool) {
    contadorDeLineas += 1
    var lineas = stage.conversacionContent.foto.lineas
    lineas.append(FotoDeLaConversacion.Linea(id: contadorDeLineas, deDilo: deDilo, texto: texto))
    stage.conversacionContent.foto.lineas = Array(lineas.suffix(Self.lineasEnLaBarra))
  }

  // La barra

  private func refrescarElEstado() {
    var foto = stage.conversacionContent.foto
    foto.silenciada = maquina.silenciada
    switch maquina.estado {
    case .escuchando, .colgada: foto.fase = .escuchando
    case .pensando: foto.fase = .pensando
    case .hablando: foto.fase = .hablando
    }
    if maquina.estado == .escuchando { foto.aviso = nil }
    stage.conversacionContent.foto = foto
  }

  private var acciones: AccionesDeLaLlamada {
    AccionesDeLaLlamada(
      silenciar: { [weak self] in
        guard let self else { return }
        aplicar(.silenciar(!maquina.silenciada))
      },
      colgar: { [weak self] in self?.colgar() },
      alternarTranscripcion: { [weak self] in self?.desplegar(transcripcion: true) },
      alternarAjustes: { [weak self] in self?.desplegar(transcripcion: false) },
      elegirModelo: { [weak self] id in
        guard let self, let eleccion = EleccionDeModelo(rawValue: id) else { return }
        settings.conversacionModelo = eleccion
        refrescarLosAjustes()
      },
      siguienteVoz: { [weak self] in self?.siguienteVoz() },
      siguienteVelocidad: { [weak self] in self?.siguienteVelocidad() },
      siguienteMicrofono: { [weak self] in self?.siguienteMicrofono() }
    )
  }

  private func desplegar(transcripcion: Bool) {
    var foto = stage.conversacionContent.foto
    if transcripcion {
      foto.verTranscripcion.toggle()
      foto.verAjustes = false
    } else {
      foto.verAjustes.toggle()
      foto.verTranscripcion = false
    }
    stage.conversacionContent.foto = foto
    stage.remedirLaConversacion()
  }

  private var opcionesDeModelo: [FotoDeLaConversacion.Opcion] {
    EleccionDeModelo.allCases.map { eleccion in
      FotoDeLaConversacion.Opcion(
        id: eleccion.rawValue, titulo: eleccion.titulo, elegida: eleccion == settings.conversacionModelo
      )
    }
  }

  private var ajustesDeLaVoz: AjustesDeLaVoz {
    AjustesDeLaVoz(
      voz: settings.conversacionVoz.isEmpty ? nil : settings.conversacionVoz,
      velocidad: settings.conversacionVelocidad
    )
  }

  private func refrescarLosAjustes() {
    var foto = stage.conversacionContent.foto
    foto.modelos = opcionesDeModelo
    foto.voz = Self.corto(voces.first { $0.id == settings.conversacionVoz }?.nombre ?? String(localized: "La de fábrica"))
    foto.velocidad = Self.titulo(deVelocidad: settings.conversacionVelocidad)
    foto.microfono = Self.corto(
      microfonos.first { $0.eleccion == settings.conversacionMicrofono }?.nombre
        ?? Self.titulo(deMicrofono: settings.conversacionMicrofono)
    )
    stage.conversacionContent.foto = foto
  }

  private func siguienteVoz() {
    let ids = [""] + voces.map(\.id)
    let actual = ids.firstIndex(of: settings.conversacionVoz) ?? 0
    settings.conversacionVoz = ids[(actual + 1) % ids.count]
    voz.ajustar(ajustesDeLaVoz)
    refrescarLosAjustes()
  }

  private func siguienteVelocidad() {
    let opciones = AjustesDeLaVoz.velocidades
    let actual = opciones.firstIndex { abs($0 - settings.conversacionVelocidad) < 0.01 } ?? 1
    settings.conversacionVelocidad = opciones[(actual + 1) % opciones.count]
    voz.ajustar(ajustesDeLaVoz)
    refrescarLosAjustes()
  }

  /// Cambia el micrófono para el turno siguiente: el de ahora sigue con el
  /// que empezó.
  private func siguienteMicrofono() {
    guard !microfonos.isEmpty else { return }
    let actual = microfonos.firstIndex { $0.eleccion == settings.conversacionMicrofono } ?? 0
    settings.conversacionMicrofono = microfonos[(actual + 1) % microfonos.count].eleccion
    refrescarLosAjustes()
  }

  // Lo de abajo

  private func enFila(_ trabajo: @escaping @MainActor () async -> Void) {
    let anterior = filaDelMotor
    filaDelMotor = Task { @MainActor in
      await anterior?.value
      await trabajo()
    }
  }

  private func anotarElResumen() {
    let duracion = inicioDeLaSesion.map { ContinuousClock.now - $0 } ?? .zero
    let modelos = NivelDeModelo.allCases.map { "\($0.rawValue) \(porModelo[$0] ?? 0)" }.joined(separator: ", ")
    AppLog.conversacion.notice(
      """
      llamada: cuelga tras \(Self.ms(duracion), privacy: .public), \(self.turnos) turnos (\(modelos, privacy: .public)), \
      US$\(self.costoDeLaSesion, format: .fixed(precision: 4), privacy: .public)
      """
    )
    inicioDeLaSesion = nil
  }

  /// Un nombre que cabe en un chip de la barra: los micrófonos USB traen
  /// nombres de treinta letras.
  static func corto(_ nombre: String) -> String {
    nombre.count <= 24 ? nombre : String(nombre.prefix(23)) + "…"
  }

  static func ms(_ duracion: Duration?) -> String {
    guard let duracion else { return "—" }
    let c = duracion.components
    return "\(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000) ms"
  }

  /// «US$0,02», con la coma del español; menos de un centavo, con tres
  /// decimales, para que una sesión barata no diga cero.
  static func dolares(_ valor: Double) -> String {
    let formato = FloatingPointFormatStyle<Double>.number
      .precision(.fractionLength(valor < 0.01 ? 3 : 2))
      .locale(Locale(identifier: "es_CL"))
    return "US$" + valor.formatted(formato)
  }

  static func titulo(deVelocidad velocidad: Double) -> String {
    switch velocidad {
    case ..<0.95: String(localized: "Lenta")
    case ..<1.05: String(localized: "Normal")
    case ..<1.2: String(localized: "Rápida")
    default: String(localized: "Muy rápida")
    }
  }

  static func titulo(deMicrofono eleccion: EleccionDeMicrofono) -> String {
    switch eleccion {
    case .automatico: String(localized: "Automático")
    case .delSistema: String(localized: "El del sistema")
    case let .elegido(_, nombre): nombre
    }
  }
}

extension EleccionDeModelo {
  /// Lo que dicen los chips de la barra y el selector de Ajustes.
  var titulo: String {
    switch self {
    case .automatico: String(localized: "Automático")
    case .haiku: "Haiku"
    case .sonnet: "Sonnet"
    case .opus: "Opus"
    }
  }
}

extension FallaDeClaude {
  /// Lo que la voz dice cuando Claude no contestó: una frase, en el tono de
  /// la conversación, que dice qué pasó y si sirve volver a intentar.
  var dichoEnLaConversacion: String {
    switch self {
    case .faltaLaClave: String(localized: "Me falta la clave de Anthropic. Pégala en Ajustes, en Claude, y conversamos.")
    case .claveRechazada: String(localized: "Anthropic no aceptó la clave. Revísala en Ajustes, en Claude.")
    case .demasiadosPedidos: String(localized: "Anthropic me pidió esperar un poco. Prueba de nuevo en un rato.")
    case .anthropicNoResponde: String(localized: "Anthropic no está respondiendo. Dímelo de nuevo en un rato.")
    case .pedidoRechazado, .respuestaInutil: String(localized: "Algo falló con Claude. ¿Me lo dices de nuevo?")
    case .sinConexion: String(localized: "Me quedé sin conexión con Anthropic. ¿Me lo repites?")
    case .tardoDemasiado: String(localized: "Claude se demoró demasiado. ¿Me lo dices de nuevo?")
    case .seNego: String(localized: "Prefiero no contestar eso.")
    case .cortada: String(localized: "La respuesta se cortó. Pídemela más corta.")
    }
  }
}

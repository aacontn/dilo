import DiloAgentes
import DiloEngines
import DiloModes
import Foundation
import Synchronization
import os

/// La **Conversación**: hablarle a Dilo —y a los otros **Agente**s— y que
/// contesten en voz alta, como una llamada.
///
/// Sólo el pensar va en línea. Lo que dices lo transcribe el **Motor de voz**
/// del dictado, en el Mac (`MotorParaConversar`); a quién va lo decide
/// `EnrutadorDeAgentes` por el nombre al principio o por el último de la
/// llamada; contesta el destino de ese agente (`DestinoDeConversacion`:
/// Claude con herramientas, un servidor MCP, Claude Code); y la respuesta la
/// dice una voz del Mac (`VozQueContesta`). El audio nunca sale del Mac: sólo
/// viaja texto. Lo conversado vive en RAM, en cada destino, mientras dura la
/// llamada y se olvida al colgar; al log van tiempos, modelo y cuentas.
///
/// Lo que un destino quiere hacer y necesita permiso llega como `Aprobacion`
/// y se muestra en la muesca con «Aprobar» y «No»: la llamada espera el clic,
/// no una respuesta de viva voz, y colgar responde que no.
///
/// La persona habla siempre con una voz. Claude Code trabaja por detrás
/// (`EncargosDeFondo`): el agente le encarga, sigue conversando y cuenta el
/// resultado cuando termina. Y el micrófono queda abierto toda la llamada
/// (`OidoDeLaLlamada`), que es lo que deja hablarle encima para interrumpirlo
/// (`DetectorDeInterrupcion`).
///
/// Los turnos son half duplex (`MaquinaDeLaConversacion`), el fin de tu turno
/// lo dice `FinDelTurno` o soltar el gatillo, y el gasto del mes tiene tope
/// (`TopeDeGasto`). Todo eso es regla pura en `DiloModes`; acá sólo se
/// ejecuta.
@MainActor
final class ControladorDeLaConversacion {
  /// Cada cuánto se mira el silencio mientras escucha. También es cada
  /// cuánto se redibuja el punto del nivel: siete veces por segundo basta
  /// para que se vea vivo y no cuesta nada.
  static let cadaCuantoMirar: Duration = .milliseconds(60)
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
  /// Quién contesta a cada agente. Claude Code se enchufa en su registro
  /// (`destinos.registro.registrar(.claudeCode) { … }`).
  let destinos: DestinosDeLaConversacion

  /// Conversando sí o no: el panel de la barra lo dice.
  var alCambiar: ((Bool) -> Void)?
  /// Si hay un dictado en curso: con uno no se empieza a conversar (el
  /// motor de voz es uno).
  var hayDictado: () -> Bool = { false }

  private var maquina = MaquinaDeLaConversacion()
  /// A quién va lo que digas sin nombre: el último al que le hablaste en esta
  /// llamada, o el elegido en el menú de destino. Nil es Dilo.
  private var agenteActual: Agente?
  /// Lo que se va a consultar cuando la máquina lo pida.
  private var pendiente: EnrutadorDeAgentes.Ruta?
  /// Lo que espera un clic. La primera es la que muestra la barra. Las de un
  /// encargo sobreviven a lo que pase en la conversación: terminar o
  /// interrumpir un turno no le niega nada a un trabajo de fondo.
  private var aprobaciones: [(aprobacion: Aprobacion, deFondo: Bool)] = []
  /// Lo que hay que contarle al agente apenas se pueda hablar.
  private var avisos: [String] = []
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
      /// Si lo oído puede interrumpir: mientras el agente piensa o habla.
      var atento = false
      var detector = DetectorDeInterrupcion()
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
  private var tiempos: TiemposDelTurno?
  /// Las operaciones del motor, en fila: empezar, terminar y cancelar
  /// tienen que llegar en orden aunque la persona interrumpa rápido.
  private var filaDelMotor: Task<Void, Never>?
  /// Lo que el destino lleva contestado en este turno, por si lo interrumpen.
  private var contestado = ""
  /// Quién está contestando, para la transcripción.
  private var contestando: Agente?
  /// Después de un aviso que no tiene arreglo en la llamada —falta la
  /// clave, se llegó al tope—, colgar cuando termine de decirlo.
  private var colgarAlTerminar = false

  /// El micrófono de la llamada. Nil si sigue con el motor del dictado.
  private var oido: OidoAbierto?
  /// Con qué motor se está oyendo este turno.
  private var motorDelTurno: MotorParaConversar?
  /// La voz que interrumpió: dónde empezó y cuánta se oyó.
  private var interrupcion: (inicio: Int, voz: Duration)?
  /// Mira, toda la llamada, si alguien interrumpió y si hay algo que contar.
  private var atencion: Task<Void, Never>?
  private var interrupciones = 0

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
    destinos = DestinosDeLaConversacion(settings: settings, leerClave: leerClave)
    self.voz.alEmpezar = { [weak self] in
      self?.anotarElPrimerAudio()
      self?.aplicar(.empezoAHablar)
    }
    self.voz.alTerminar = { [weak self] in self?.terminoDeHablar() }
    destinos.alTerminarElTurno = { [weak self] agente, resumen in self?.anotar(resumen, de: agente) }
    destinos.alTranscribir = { [weak self] agente, texto in
      self?.agregarLinea(texto, deDilo: true, quien: agente.nombre, nota: true)
    }
    destinos.encargos.alTranscribir = { [weak self] agente, texto in
      self?.agregarLinea(texto, deDilo: true, quien: agente.nombre, nota: true)
    }
    destinos.encargos.alCambiar = { [weak self] linea in
      self?.stage.conversacionContent.foto.encargo = linea
    }
    destinos.encargos.alTerminar = { [weak self] aviso in self?.avisos.append(aviso) }
    destinos.encargos.alPedirClic = { [weak self] aprobacion, aviso in
      self?.mostrar(aprobacion, deFondo: true)
      if let aviso { self?.avisos.append(aviso) }
    }
  }

  var enCurso: Bool { maquina.estado != .colgada }

  // Lo que entra de afuera

  /// El panel de la barra y el atajo «Conversar con Dilo»: llamar o colgar.
  func alternar() {
    enCurso ? colgar() : llamar(agente: nil, primerTurno: nil)
  }

  /// Abre la llamada con un agente y, si hay, con lo dicho después de su
  /// nombre como primer turno. Es la puerta de la escucha de nombres: oyó
  /// «Switchboard, ¿qué tengo hoy?» y llama con `switchboard` y «¿Qué tengo
  /// hoy?».
  ///
  /// Con la llamada en curso cambia de agente y, si hay texto, lo consulta
  /// ya (cortando lo que Dilo estuviera diciendo). Sin agente, el último de
  /// la llamada o Dilo; un texto vacío abre la llamada escuchando.
  func llamar(agente: Agente?, primerTurno: String?) {
    let texto = primerTurno?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // «Claude Code, revisa los tests»: se lo dice al agente de la llamada, que
    // es quien lo encarga. Sin mensaje, se le pide que lo retome.
    var quien = agente
    var dicho = texto
    if let agente, agente.trabajaDeFondo {
      quien = nil
      dicho = texto.isEmpty ? String(localized: "Abre \(agente.nombre)") : "\(agente.nombre), \(texto)"
    }
    guard enCurso else {
      empezarLaLlamada(con: quien, primerTurno: dicho)
      return
    }
    if let quien { cambiarDeAgente(a: quien) }
    guard !dicho.isEmpty else { return }
    entraUnTurno(TurnoDeLaPersona(agente: quien ?? agenteDeLaLlamada, texto: dicho))
  }

  /// La tecla de conversar, o cualquier gatillo mientras hay conversación.
  /// Apretar te da el turno —interrumpe si Dilo hablaba—; soltar lo termina
  /// si hablaste.
  func gatillo(apretado: Bool) {
    if apretado {
      sostenidoDesde = .now
      guard enCurso else {
        llamar(agente: nil, primerTurno: nil)
        return
      }
      if maquina.silenciada { silenciar(false) }
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
    // Una aprobación sin decidir es un no: nada se hace sin el clic.
    soltarLasAprobaciones()
    destinos.colgar()
    stage.cerrarLaConversacion()
    anotarElResumen()
    cerrarElOido()
    atencion?.cancel()
    atencion = nil
    avisos = []
    interrupcion = nil
    agenteActual = nil
    pendiente = nil
    contestado = ""
    contestando = nil
    colgarAlTerminar = false
    vigia?.cancel()
    vigia = nil
    alCambiar?(false)
  }

  // Llamar

  /// Los agentes de Ajustes, y el enrutador que los conoce.
  private var enrutador: EnrutadorDeAgentes { EnrutadorDeAgentes(agentes: settings.conversacionAgentes) }

  /// El agente que recibe lo dicho sin nombre.
  private var agenteDeLaLlamada: Agente { agenteActual ?? enrutador.porDefecto }

  private func empezarLaLlamada(con agente: Agente?, primerTurno: String) {
    guard !enCurso, let motor else { return }
    guard !hayDictado() else { return }
    let primero = agente ?? enrutador.porDefecto
    Task {
      // La clave y el tope sólo importan si el primero que contesta usa la
      // API: Claude Code va por la cuenta de la persona.
      if DestinosDeLaConversacion.usaLaAPI(primero) {
        guard await leerClave() != nil else {
          stage.showMessage(String(localized: "Falta la clave de Anthropic"))
          return
        }
        guard TopeDeGasto.puedeLlamar(settings.conversacionGasto, tope: settings.conversacionTope, ahora: Date())
        else {
          stage.showMessage(String(localized: "Llegaste al tope del mes para conversar"))
          return
        }
      }
      guard !enCurso else { return }
      empezar(motor, con: agente)
      if primerTurno.isEmpty {
        aplicar(.llamar)
      } else {
        entraUnTurno(TurnoDeLaPersona(agente: primero, texto: primerTurno))
      }
    }
  }

  private func empezar(_ motor: MotorParaConversar, con agente: Agente?) {
    inicioDeLaSesion = .now
    turnos = 0
    porModelo = [:]
    costoDeLaSesion = 0
    contadorDeLineas = 0
    interrupciones = 0
    medidor.withLock { $0 = Medidor.Medicion() }
    abrirElOido()
    prestarAtencion()
    voz.ajustar(ajustesDeLaVoz)
    agenteActual = agente
    var foto = FotoDeLaConversacion()
    foto.modelos = opcionesDeModelo
    stage.conversacionContent.foto = foto
    stage.conversacionContent.acciones = acciones
    refrescarLosAjustes()
    refrescarElDestino()
    stage.abrirLaConversacion(dibujandoCon: settings.sessionSettingsParaDibujar)
    alCambiar?(true)
    AppLog.conversacion.notice(
      """
      llamada: empieza con \(self.agenteDeLaLlamada.id, privacy: .public) \
      (modelo \(self.settings.conversacionModelo.rawValue, privacy: .public))
      """
    )
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
    let atento = !maquina.silenciada && (maquina.estado == .pensando || maquina.estado == .hablando)
    medidor.withLock { medicion in
      if atento && !medicion.atento { medicion.detector.reiniciar() }
      medicion.atento = atento
    }
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

  // El oído de la llamada

  /// Abre el micrófono de la llamada, en la misma fila que el motor: el primer
  /// turno espera a que esté. Si no se puede, la llamada sigue con el motor del
  /// dictado.
  private func abrirElOido() {
    guard DiloSpeechStack.cargadorDeParakeet.disponible, settings.motorDeVoz == .parakeet else { return }
    let eleccion = settings.conversacionMicrofono
    let medidor = medidor
    let salida = voz.nivelDeSalida
    enFila { [weak self] in
      guard let self, inicioDeLaSesion != nil, oido == nil else { return }
      let abierto = await OidoAbierto.abrir(
        eleccion: eleccion,
        transcribir: { audio in
          try await ParakeetCompartido.motor.conElModelo { try await $0.transcribir(audio) }
        },
        alFallar: { [weak self] mensaje in
          Task { @MainActor [weak self] in
            AppLog.conversacion.error("llamada: se cayó el micrófono: \(mensaje, privacy: .public)")
            self?.cerrarElOido()
          }
        },
        alOir: { nivel, indice in
          // Sin saber qué suena no se puede separar a la persona del eco.
          let sonando = salida?()
          medidor.withLock { medicion in
            guard medicion.atento, let sonando else { return }
            medicion.detector.muestra(microfono: nivel, salida: sonando, indice: indice, en: .now)
          }
        }
      )
      guard inicioDeLaSesion != nil else {
        abierto?.cerrar()
        return
      }
      oido = abierto
      AppLog.conversacion.notice(
        "llamada: micrófono \(abierto == nil ? "por turno, con el motor del dictado" : "abierto toda la llamada", privacy: .public)"
      )
      // Carga el modelo antes de que haga falta: al terminar el primer turno
      // ya no se puede esperar.
      if abierto != nil {
        Task.detached(priority: .userInitiated) {
          try? await ParakeetCompartido.motor.conElModelo { _ in }
        }
      }
    }
  }

  private func cerrarElOido() {
    oido?.cerrar()
    oido = nil
  }

  /// Silenciar cierra el micrófono de verdad: silenciada, nada se oye. Se
  /// reabre antes del turno, que espera en la misma fila.
  private func silenciar(_ silenciada: Bool) {
    if silenciada {
      cerrarElOido()
    } else {
      abrirElOido()
    }
    aplicar(.silenciar(silenciada))
  }

  /// Mira si la persona interrumpió con la voz y si hay algo que contar.
  private func prestarAtencion() {
    atencion?.cancel()
    atencion = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.cadaCuantoMirar)
        guard let self, !Task.isCancelled else { return }
        if sePuedeInterrumpir, let voz = medidor.withLock({ medicion in
          medicion.detector.inicioDeLaVoz.map { (inicio: $0, voz: medicion.detector.vozContada) }
        }) {
          interrumpioConLaVoz(voz)
        }
        contarLoQueLlego()
      }
    }
  }

  /// Hablando se puede interrumpir siempre. Pensando, sólo si ya se consultó y
  /// nada corre: cortar una herramienta a medias o una aprobación por una voz
  /// en la pieza sería peor que esperar. Y un aviso que cuelga no se corta.
  private var sePuedeInterrumpir: Bool {
    guard !colgarAlTerminar, aprobaciones.isEmpty else { return false }
    switch maquina.estado {
    case .hablando: return true
    case .pensando: return consulta != nil && stage.conversacionContent.foto.herramienta == nil
    case .escuchando, .colgada: return false
    }
  }

  private func interrumpioConLaVoz(_ voz: (inicio: Int, voz: Duration)) {
    interrupciones += 1
    AppLog.conversacion.notice("turno \(self.turnos): interrumpido con la voz")
    interrupcion = voz
    aplicar(.interrumpir)
  }

  /// Lo que dejó un encargo se le cuenta al agente apenas la conversación
  /// tiene un hueco: nunca encima de la persona ni del agente.
  private func contarLoQueLlego() {
    guard !avisos.isEmpty, maquina.estado == .escuchando else { return }
    guard !medidor.withLock({ $0.fin?.huboVoz ?? false }) else { return }
    let aviso = avisos.removeFirst()
    escucha += 1
    pendiente = .turno(TurnoDeLaPersona(agente: enrutador.porDefecto, texto: aviso, esAviso: true))
    aplicar(.turnoDeAfuera)
  }

  // Tu turno

  private func escuchar() {
    let viene = interrupcion
    interrupcion = nil
    escucha += 1
    let esta = escucha
    let ahora = ContinuousClock.now
    medidor.withLock { medicion in
      medicion.fin = FinDelTurno(inicio: ahora, vozPrevia: viene?.voz ?? .zero)
      medicion.nivel = 0
      medicion.escucha = esta
    }
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
    // Se decide en la fila: el oído de la llamada puede estar abriéndose.
    enFila { [weak self] in
      guard let self, let motor = oido?.oido.motor(desde: viene?.inicio) ?? self.motor else { return }
      motorDelTurno = motor
      do {
        let locale = try await motor.locale(identificador)
        try await motor.empezar(locale, eleccion, handlers)
      } catch {
        fallaDelMotor(error.localizedDescription, escucha: esta)
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
        let abierta = FinDelTurno.dejaLaFraseAbierta(stage.conversacionContent.foto.parcial)
        let (nivel, termino, nadie) = medidor.withLock { medicion in
          (
            medicion.nivel, medicion.fin?.termino(en: ahora, fraseAbierta: abierta) ?? false,
            medicion.fin?.nadieHabla(en: ahora) ?? false
          )
        }
        stage.conversacionContent.foto.nivel = nivel
        guard sostenidoDesde == nil else { continue }
        if termino {
          aplicar(.terminoTuTurno)
          return
        }
        if nadie, !destinos.encargos.hayTrabajando {
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
    let esta = escucha
    guard entregar else {
      enFila { [weak self] in await self?.motorDelTurno?.cancelar() }
      return
    }
    let soltado = ContinuousClock.now
    tiempos = TiemposDelTurno(
      soltado: soltado, silencio: medidor.withLock { $0.fin?.silencio(en: soltado) } ?? .zero
    )
    enFila { [weak self] in
      let texto = (try? await self?.motorDelTurno?.terminar()) ?? ""
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
    tiempos?.transcribir = transcribir
    let ruta = enrutador.unaSolaVoz(enrutador.enrutar(limpio, ultimo: agenteActual), dicho: limpio)
    pendiente = ruta
    agregarLinea(limpio, deDilo: false)
    aplicar(.transcrito(vacio: false))
  }

  /// Un turno que no salió del micrófono: la escucha de nombres o un
  /// `llamar(agente:primerTurno:)` con la llamada en curso. Lo que se
  /// estuviera transcribiendo ya no cuenta.
  private func entraUnTurno(_ turno: TurnoDeLaPersona) {
    escucha += 1
    pendiente = .turno(turno)
    agregarLinea(turno.texto, deDilo: false)
    aplicar(.turnoDeAfuera)
  }

  private func fallaDelMotor(_ mensaje: String, escucha esta: Int) {
    guard esta == escucha, enCurso else { return }
    AppLog.conversacion.error("llamada: el motor de voz falló: \(mensaje, privacy: .public)")
    stage.conversacionContent.foto.aviso = String(localized: "No pude escucharte")
    colgarAlTerminar = true
    voz.decir(String(localized: "No pude abrir el micrófono, así que corto acá."))
    voz.cerrarElTurno()
  }

  // El turno del agente

  private func consultar() {
    guard let ruta = pendiente else {
      aplicar(.transcrito(vacio: true))
      return
    }
    pendiente = nil
    switch ruta {
    case let .cambiarA(agente):
      cambiarDeAgente(a: agente, diciendolo: true)
    case let .turno(turno):
      consultar(turno)
    }
  }

  /// «Pásame con Switchboard»: cambia y lo dice, sin mandarle nada. Si ese
  /// tipo de agente todavía no está conectado, lo dice y no cambia.
  private func cambiarDeAgente(a agente: Agente, diciendolo: Bool = false) {
    let conectado = destinos.registro.estaConectado(agente.tipo.clase)
    if conectado { agenteActual = agente }
    refrescarElDestino()
    guard diciendolo else { return }
    let dicho = conectado
      ? String(localized: "Te paso con \(agente.nombre).")
      : String(localized: "\(agente.nombre) todavía no está conectado a Dilo.")
    agregarLinea(dicho, deDilo: true, quien: conectado ? agente.nombre : nil, nota: true)
    voz.decir(dicho)
    voz.cerrarElTurno()
  }

  private func consultar(_ turno: TurnoDeLaPersona) {
    let agente = turno.agente
    // Un agente sin conectar contesta que no lo está, pero no se queda con
    // lo que digas después sin nombre.
    if destinos.registro.estaConectado(agente.tipo.clase) { agenteActual = agente }
    refrescarElDestino()
    turnos += 1
    stage.conversacionContent.foto.aviso = nil
    stage.conversacionContent.foto.herramienta = nil

    if DestinosDeLaConversacion.usaLaAPI(agente),
      !TopeDeGasto.puedeLlamar(settings.conversacionGasto, tope: settings.conversacionTope, ahora: Date())
    {
      AppLog.conversacion.notice("turno \(self.turnos): no se llama, se llegó al tope del mes")
      decirUnAviso(
        String(localized: "Llegaste al tope de gasto de este mes para conversar. Lo puedes subir en Ajustes, en Claude."),
        enLaBarra: String(localized: "Tope del mes"),
        yColgar: true
      )
      return
    }

    let destino = destinos.destino(para: agente)
    let numero = turnos
    contestado = ""
    contestando = agente
    let flujo = destino.responder(turno)
    consulta = Task { [weak self] in
      var trozos = TrozosParaDecir()
      do {
        for try await evento in flujo {
          guard let self, !Task.isCancelled else { return }
          if let claude = destino as? DestinoConClaude {
            stage.conversacionContent.foto.modelo = claude.ultimaDecision?.nivel.nombreCorto
          } else {
            stage.conversacionContent.foto.modelo = nil
          }
          switch evento {
          case let .texto(pedazo):
            contestado += pedazo
            tiempos?.marcarPrimerPedazo()
            for oracion in trozos.agregar(pedazo) {
              tiempos?.marcarPrimeraOracion()
              voz.decir(oracion)
            }
          case let .herramienta(nombre, enCurso):
            stage.conversacionContent.foto.herramienta = enCurso ? nombre : nil
            if enCurso { agregarLinea(nombre, deDilo: true, quien: quienDice(agente), nota: true) }
          case let .pideAprobacion(aprobacion):
            // Lo que ya se dijo se termina de decir mientras espera el clic.
            if let resto = trozos.terminar() { voz.decir(resto) }
            mostrar(aprobacion, deFondo: false)
          case let .fin(costoUSD):
            if let resto = trozos.terminar() { voz.decir(resto) }
            terminarElTurno(de: agente, costo: costoUSD)
          }
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        if let falla = error as? FallaDeClaude {
          AppLog.conversacion.error(
            "turno \(numero): \(agente.id, privacy: .public) falló: \(falla.nombreEnElLog, privacy: .public)"
          )
          fallaDeClaude(falla)
        } else {
          AppLog.conversacion.error(
            "turno \(numero): \(agente.id, privacy: .public) falló: \(String(describing: error), privacy: .public)"
          )
          fallaDelDestino(agente)
        }
      }
    }
  }

  /// Lo que tardó el turno desde que la persona se calló hasta oír a Dilo, por
  /// partes. Es la medida de que esto se sienta como una conversación.
  private struct TiemposDelTurno {
    let soltado: ContinuousClock.Instant
    /// Lo que se esperó en silencio antes de darle el turno a Dilo.
    let silencio: Duration
    var transcribir: Duration?
    var primerPedazo: Duration?
    var primeraOracion: Duration?

    mutating func marcarPrimerPedazo() {
      if primerPedazo == nil { primerPedazo = .now - soltado }
    }

    mutating func marcarPrimeraOracion() {
      if primeraOracion == nil { primeraOracion = .now - soltado }
    }
  }

  private func anotarElPrimerAudio() {
    guard let tiempos else { return }
    self.tiempos = nil
    let oido = ContinuousClock.now - tiempos.soltado
    AppLog.conversacion.notice(
      """
      turno \(self.turnos): de callar a oír \(Self.ms(tiempos.silencio + oido), privacy: .public) \
      (silencio \(Self.ms(tiempos.silencio), privacy: .public), transcribir \(Self.ms(tiempos.transcribir), privacy: .public), \
      primer texto \(Self.ms(tiempos.primerPedazo), privacy: .public), primera oración \(Self.ms(tiempos.primeraOracion), privacy: .public), \
      primer audio \(Self.ms(oido), privacy: .public))
      """
    )
  }

  /// En la transcripción, el nombre de quien contesta si no es Dilo.
  private func quienDice(_ agente: Agente) -> String? {
    agente.tipo == .dilo && agente.nombre == "Dilo" ? nil : agente.nombre
  }

  /// Lo que dijo el agente va a la transcripción y lo gastado al tope.
  private func terminarElTurno(de agente: Agente, costo: Double?) {
    consulta = nil
    soltarLasDelTurno()
    stage.conversacionContent.foto.herramienta = nil
    let respuesta = contestado.trimmingCharacters(in: .whitespacesAndNewlines)
    contestado = ""
    contestando = nil
    if !respuesta.isEmpty { agregarLinea(respuesta, deDilo: true, quien: quienDice(agente)) }
    if let costo {
      costoDeLaSesion += costo
      settings.conversacionGasto = TopeDeGasto.sumar(costo, a: settings.conversacionGasto, ahora: Date())
      stage.conversacionContent.foto.costo = Self.dolares(costoDeLaSesion)
    }
    voz.cerrarElTurno()
  }

  /// Lo que un destino con Claude cuenta de su turno: al log, como siempre.
  private func anotar(_ resumen: ResumenDelTurno, de agente: Agente) {
    let decision = resumen.decision
    porModelo[decision.nivel, default: 0] += 1
    let herramientas = resumen.herramientas.isEmpty ? "" : " herramientas \(resumen.herramientas.joined(separator: ","))"
    let uso = resumen.uso
    AppLog.conversacion.notice(
      """
      turno \(self.turnos) (\(agente.id, privacy: .public)): \(decision.nivel.rawValue, privacy: .public) \
      (\(decision.motivo.rawValue, privacy: .public), esfuerzo \(decision.nivel.esfuerzo, privacy: .public)) \
      vueltas \(resumen.vueltas)\(herramientas, privacy: .public) primer pedazo \(Self.ms(resumen.primerPedazo), privacy: .public), \
      total \(Self.ms(resumen.total), privacy: .public), tokens \(uso.entrada)+\(uso.escritosEnCache)w+\(uso.leidosDeCache)r/\(uso.salida)\
      \(resumen.cortada ? " cortada" : "", privacy: .public), US$\(resumen.costoUSD, format: .fixed(precision: 5), privacy: .public)
      """
    )
  }

  /// La interrupción: lo que el agente alcanzó a contestar queda en la
  /// transcripción con una marca. Lo conversado de cada destino lo guarda el
  /// destino, que también anota dónde lo cortaron.
  private func cancelarLaConsulta() {
    consulta?.cancel()
    consulta = nil
    soltarLasDelTurno()
    stage.conversacionContent.foto.herramienta = nil
    let alcanzo = contestado.trimmingCharacters(in: .whitespacesAndNewlines)
    contestado = ""
    let quien = contestando.flatMap(quienDice)
    contestando = nil
    guard !alcanzo.isEmpty else { return }
    agregarLinea(alcanzo + " —", deDilo: true, quien: quien)
  }

  private func fallaDeClaude(_ falla: FallaDeClaude) {
    consulta = nil
    contestado = ""
    contestando = nil
    soltarLasDelTurno()
    stage.conversacionContent.foto.herramienta = nil
    let sinArreglo = falla == .faltaLaClave || falla == .claveRechazada
    decirUnAviso(falla.dichoEnLaConversacion, enLaBarra: falla.aviso, yColgar: sinArreglo)
  }

  private func fallaDelDestino(_ agente: Agente) {
    consulta = nil
    contestado = ""
    contestando = nil
    soltarLasDelTurno()
    stage.conversacionContent.foto.herramienta = nil
    decirUnAviso(
      String(localized: "Algo falló con \(agente.nombre). ¿Me lo dices de nuevo?"),
      enLaBarra: String(localized: "Falló \(agente.nombre)"),
      yColgar: false
    )
  }

  // La aprobación

  /// Pone la aprobación en la muesca, con su detalle en la transcripción. No
  /// se dice en voz alta: no es una pregunta que se conteste con la voz. Si hay
  /// otra esperando, ésta sigue en la fila.
  private func mostrar(_ nueva: Aprobacion, deFondo: Bool) {
    if !deFondo { soltarLasDelTurno() }
    aprobaciones.append((nueva, deFondo))
    agregarLinea(
      String(localized: "Pide aprobar: \(nueva.detalle)"), deDilo: true, quien: quienDice(nueva.agente), nota: true
    )
    AppLog.conversacion.notice("aprobación: \(nueva.agente.id, privacy: .public) pide un clic")
    mostrarLaPrimera()
  }

  private func mostrarLaPrimera() {
    stage.conversacionContent.foto.aprobacion = aprobaciones.first.map {
      FotoDeLaConversacion.AprobacionEnLaBarra(descripcion: $0.aprobacion.descripcion, detalle: $0.aprobacion.detalle)
    }
    stage.remedirLaConversacion()
  }

  /// El clic. La responde una sola vez y pasa a la siguiente.
  private func decidirLaAprobacion(_ decision: Bool) {
    guard !aprobaciones.isEmpty else { return }
    responder(aprobaciones.removeFirst().aprobacion, decision)
    mostrarLaPrimera()
  }

  /// Interrumpir o terminar un turno: lo que él pidió queda en no. Las de un
  /// encargo siguen esperando.
  private func soltarLasDelTurno() {
    let delTurno = aprobaciones.filter { !$0.deFondo }
    guard !delTurno.isEmpty else { return }
    aprobaciones.removeAll { !$0.deFondo }
    delTurno.forEach { responder($0.aprobacion, false) }
    mostrarLaPrimera()
  }

  /// Colgar: todo lo que no se decidió es un no.
  private func soltarLasAprobaciones() {
    let todas = aprobaciones
    aprobaciones = []
    todas.forEach { responder($0.aprobacion, false) }
    mostrarLaPrimera()
  }

  private func responder(_ aprobacion: Aprobacion, _ decision: Bool) {
    aprobacion.responder(decision)
    agregarLinea(
      decision ? String(localized: "Aprobado") : String(localized: "No aprobado"),
      deDilo: false, nota: true
    )
    AppLog.conversacion.notice("aprobación: \(decision ? "aprobada" : "no", privacy: .public)")
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

  private func agregarLinea(_ texto: String, deDilo: Bool, quien: String? = nil, nota: Bool = false) {
    contadorDeLineas += 1
    var lineas = stage.conversacionContent.foto.lineas
    lineas.append(
      FotoDeLaConversacion.Linea(id: contadorDeLineas, deDilo: deDilo, texto: texto, quien: quien, nota: nota)
    )
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
        silenciar(!maquina.silenciada)
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
      siguienteMicrofono: { [weak self] in self?.siguienteMicrofono() },
      alternarDestinos: { [weak self] in self?.desplegarLosDestinos() },
      elegirDestino: { [weak self] id in
        guard let self, let agente = settings.conversacionAgentes.first(where: { $0.id == id }) else { return }
        cambiarDeAgente(a: agente)
        desplegarLosDestinos()
      },
      aprobar: { [weak self] in self?.decidirLaAprobacion(true) },
      rechazar: { [weak self] in self?.decidirLaAprobacion(false) }
    )
  }

  private func desplegarLosDestinos() {
    var foto = stage.conversacionContent.foto
    foto.verDestinos.toggle()
    if foto.verDestinos {
      foto.verAjustes = false
      foto.verTranscripcion = false
    }
    stage.conversacionContent.foto = foto
    stage.remedirLaConversacion()
  }

  /// El chip de a quién se le habla y los agentes del menú.
  private func refrescarElDestino() {
    let actual = agenteDeLaLlamada
    var foto = stage.conversacionContent.foto
    foto.agente = Self.corto(actual.nombre)
    // Los que trabajan de fondo no se eligen: se les encarga por el agente.
    foto.agentes = settings.conversacionAgentes.filter { !$0.trabajaDeFondo }.map { agente in
      FotoDeLaConversacion.Opcion(id: agente.id, titulo: agente.nombre, elegida: agente.id == actual.id)
    }
    stage.conversacionContent.foto = foto
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
    foto.verDestinos = false
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
    if oido != nil, !maquina.microfonoAbierto {
      cerrarElOido()
      abrirElOido()
    }
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
    let eco = medidor.withLock { $0.detector.ecoAprendido }.map { String(format: "%.2f", $0) } ?? "—"
    AppLog.conversacion.notice(
      """
      llamada: cuelga tras \(Self.ms(duracion), privacy: .public), \(self.turnos) turnos (\(modelos, privacy: .public)), \
      \(self.interrupciones) interrupciones con la voz, eco \(eco, privacy: .public), \
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

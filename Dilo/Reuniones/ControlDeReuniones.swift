import AppKit
import DiloEngines
import DiloHablantes
import DiloReuniones
import Foundation
import Observation
import os

/// La puerta de Reuniones en la app: grabar, terminar, afinar, y lo que la
/// interfaz necesita mirar. Es lo único que la ventana del guion, la lista de
/// Ajustes, la muesca, el panel de la barra y los atajos tocan.
///
/// **Nada de reuniones se carga hasta que se graba una** (spec, «Números»):
/// este objeto es chico; los búferes, las capturas y los modelos nacen con
/// `grabar` y la pasada final, y se van al terminar.
@MainActor
@Observable
final class ControlDeReuniones {
  /// Una pista mientras graba, como la dibuja la muesca.
  struct PistaEnVivo: Equatable, Sendable {
    /// La vigía: `.ambar` a los 5 s de ceros exactos, `.sinAudio` a los 15.
    var vigia: VigiaDeSilencio.Estado = .bien
    /// dBFS del último segundo. Sobre `EstadoDeLaMarca.umbralDeSenal` hay
    /// señal.
    var nivel: Float = -160
    /// Si la marca va encendida.
    var conSenal: Bool { nivel > EstadoDeLaMarca.umbralDeSenal }
    /// Con `.sinAudio`: si lo que falta parece ser el permiso del audio del
    /// sistema (nunca sonó) y no una llamada en silencio.
    var pareceFaltarPermiso = false
    /// Si la pista no abrió o se cortó, por qué. La otra sigue.
    var falla: String?
  }

  /// La reunión que se está grabando.
  struct EnCurso: Equatable, Sendable {
    var id: String
    var titulo: String
    var inicio: Date
    var carpeta: URL
    /// En el SSD o en el respaldo interno.
    var lugar: PoliticaDeDisco.Lugar
    var yo = PistaEnVivo()
    var ellos = PistaEnVivo()
    /// Menos de 500 MB libres: la interfaz avisa.
    var espacioBajo = false
  }

  /// La pasada final en curso, con su avance real.
  struct Pasada: Equatable, Sendable {
    var id: String
    var titulo: String
    var avance: AvanceDeLaPasada
  }

  /// Lo que la muesca tiene que decir una vez, con su arreglo.
  enum Aviso: Equatable, Sendable {
    case noEmpezo(String)
    /// `ellos` 15 s en ceros y nunca sonó: «Sin audio de la llamada: falta
    /// un permiso». El arreglo es `Permiso.panelDelAudioDelSistema`.
    case faltaPermisoDelAudioDelSistema
    case microfonoMudo
    case espacioBajo
    case guionListo(id: String)
    case pasadaFallo(id: String, motivo: String)
  }

  /// El panel exacto de Ajustes del Sistema para el permiso del audio del
  /// sistema («System Audio Recording Only»).
  static let panelDelAudioDelSistema = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"

  private(set) var enCurso: EnCurso?
  private(set) var pasada: Pasada?
  private(set) var aviso: Aviso?

  /// Cómo está el separador de voces elegido en este Mac: lo que dice
  /// Ajustes → Grabar reuniones.
  enum EstadoDelSeparador: Equatable, Sendable {
    case sinRevisar
    case sinBajar
    case bajando
    /// Bajado, pero la primera carga va a compilar para el Neural Engine.
    case porPreparar
    case preparando
    case listo
    case fallo(String)
  }

  private(set) var separador = EstadoDelSeparador.sinRevisar

  /// Lo que se va diciendo en la reunión que graba, y sigue a la vista
  /// mientras se afina. Aparte de `enCurso`, que cambia cada segundo y mueve la
  /// muesca: esto sólo lo mira la ventana.
  private(set) var vivo = GuionEnVivo()
  private(set) var notas: [NotaDeLaReunion] = []
  /// De qué reunión son `vivo` y `notas`.
  private(set) var idDelVivo: String?

  /// Para lo que no es SwiftUI (el panel de la barra): cada cambio de
  /// `enCurso` o `pasada`.
  @ObservationIgnored var alCambiar: (() -> Void)?
  /// Justo antes de cerrar la grabación, venga de donde venga el «Terminar»:
  /// la ventana guarda la nota a medio escribir.
  @ObservationIgnored var antesDeTerminar: (() -> Void)?

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let respaldo: URL
  @ObservationIgnored private let parakeet: @MainActor () -> ParakeetEngine
  @ObservationIgnored private var grabadora: GrabadoraDeReunion?
  @ObservationIgnored private var transcripcion: TranscripcionEnVivo?
  @ObservationIgnored private var afinando: Set<String> = []
  @ObservationIgnored private var separacion: SeparacionDeVoces?
  @ObservationIgnored private var observadorDelDisco: (any NSObjectProtocol)?
  @ObservationIgnored private var dictando = false
  /// La compilación para el Neural Engine en curso, si hay: una pasada que
  /// llega a separar voces la espera en vez de cargar el modelo dos veces.
  @ObservationIgnored private var precalentado: Task<Void, Never>?
  @ObservationIgnored private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")

  init(
    defaults: UserDefaults = .standard,
    respaldo: URL = CarpetaDeReunion.respaldoInterno(
      applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ),
    parakeet: @escaping @MainActor () -> ParakeetEngine = { ParakeetCompartido.motor }
  ) {
    self.defaults = defaults
    self.respaldo = respaldo
    self.parakeet = parakeet
  }

  var preferencias: PreferenciasDeReuniones { PreferenciasDeReuniones.leer(defaults) }
  var grabando: Bool { enCurso != nil }
  var lector: LectorDeReuniones { LectorDeReuniones(raiz: preferencias.carpeta, respaldo: respaldo) }

  enum ResultadoAlGrabar: Equatable, Sendable {
    case empezo(id: String)
    case yaGrabando(id: String)
    case noSePudo(String)
  }

  /// Empieza a grabar. Nunca sola: la llama un clic o un atajo de la persona.
  /// Sin evento, toma el del calendario que está pasando ahora (si hay
  /// permiso).
  @discardableResult
  func grabar(evento: EventoDeLaReunion? = nil) -> ResultadoAlGrabar {
    if let enCurso { return .yaGrabando(id: enCurso.id) }
    do {
      let transcripcion = armarLaTranscripcion()
      let grabadora = try GrabadoraDeReunion.empezar(
        evento: evento ?? EventoActualDelCalendario.leer(), preferencias: preferencias, respaldo: respaldo,
        alOir: { transcripcion.recibir($0) }
      )
      self.grabadora = grabadora
      self.transcripcion = transcripcion
      Task.detached(priority: .utility) { await transcripcion.escuchar() }
      vivo = GuionEnVivo()
      notas = []
      idDelVivo = grabadora.reunion.id
      enCurso = EnCurso(
        id: grabadora.reunion.id, titulo: grabadora.reunion.titulo, inicio: grabadora.reunion.inicio,
        carpeta: grabadora.carpeta, lugar: grabadora.enVivo.lugar
      )
      reflejar(grabadora.enVivo)
      grabadora.alCambiar = { [weak self] enVivo in self?.reflejar(enVivo) }
      alCambiar?()
      // La primera reunión baja el separador de voces mientras graba (es «a
      // pedido»: lo pidió grabar) y lo deja compilado para cuando termine.
      prepararElSeparador(bajarSiFalta: true)
      return .empezo(id: grabadora.reunion.id)
    } catch {
      let motivo = error.localizedDescription
      Self.logger.error("La reunión no empezó: \(motivo, privacy: .public)")
      aviso = .noEmpezo(motivo)
      return .noSePudo(motivo)
    }
  }

  /// Termina la reunión en curso y corre la pasada final. Vuelve en cuanto
  /// los WAV están cerrados; la pasada sigue en segundo plano y publica su
  /// avance en `pasada`. Devuelve el id de la reunión, o nil si no grababa.
  @discardableResult
  func terminar() -> String? {
    guard let grabadora else { return nil }
    antesDeTerminar?()
    let enDisco = grabadora.terminar()
    self.grabadora = nil
    let transcripcion = self.transcripcion
    self.transcripcion = nil
    Task { await transcripcion?.terminar() }
    enCurso = nil
    alCambiar?()
    afinar(enDisco)
    return enDisco.id
  }

  /// Un dictado empezó o terminó: si hay reunión, sus palabras de `yo` no van
  /// al guion.
  func dictado(enCurso: Bool) {
    grabadora?.dictado(enCurso: enCurso)
    dictando = enCurso
    let transcripcion = self.transcripcion
    Task { await transcripcion?.dictado(enCurso: enCurso) }
    // Lo que esperaba a que terminara el dictado, ahora.
    if !enCurso, separador == .porPreparar { prepararElSeparador() }
  }

  /// Una nota en la reunión que graba. Devuelve si quedó: una nota vacía no.
  @discardableResult
  func anotar(_ texto: String) -> Bool {
    guard let grabadora, grabadora.anotar(texto) else { return false }
    notas = grabadora.notas
    return true
  }

  /// El guion en vivo de esta reunión: con el mismo Parakeet del dictado y un
  /// detector de voz por pista, porque cada uno lleva su estado. El detector se
  /// baja la primera vez que hace falta (~1 MB, lo pidió grabar); sin él, sigue
  /// por nivel.
  private func armarLaTranscripcion() -> TranscripcionEnVivo {
    let motor = parakeet()
    let logger = Self.logger
    let (detectorYo, detectorEllos) = (DetectorDeVozSilero(), DetectorDeVozSilero())
    let aplicar: @Sendable (NovedadEnVivo) -> Void = { [weak self] novedad in
      Task { @MainActor in self?.vivo.aplicar(novedad) }
    }
    // Cargar el modelo en frío tarda hasta 26 s: mejor mientras la gente se
    // saluda que encima de la primera frase.
    Task.detached(priority: .utility) { try? await motor.conElModelo { _ in } }
    return TranscripcionEnVivo(
      inicioHost: RelojDelMac.ahora,
      transcribir: { audio in
        do {
          return try await motor.transcribirSinSesion(audio)
        } catch EngineError.modeloNoDescargado {
          throw FallaDelVivo.sinMotor
        } catch {
          logger.error("El guion en vivo no pudo transcribir un tramo: \(error.localizedDescription, privacy: .public)")
          throw error
        }
      },
      detectar: { pista, trozo in try await (pista == .yo ? detectorYo : detectorEllos).probabilidad(trozo) },
      alCambiar: aplicar
    )
  }

  /// Vuelve a correr la pasada final de una reunión ya grabada: tras una
  /// falla, con otro diarizador, o una interrumpida.
  func afinarDeNuevo(id: String) {
    Task {
      guard let enDisco = try? lector.reunion(id: id) else { return }
      afinar(enDisco)
    }
  }

  func olvidarAviso() { aviso = nil }

  private func afinar(_ enDisco: ReunionEnDisco) {
    guard !afinando.contains(enDisco.id) else { return }
    afinando.insert(enDisco.id)
    let separacion = self.separacion ?? SeparacionDeVoces(carpetaDeModelos: Self.carpetaDeModelos)
    self.separacion = separacion
    let diarizador = Diarizador.para(preferencias.diarizador)
    let precalentado = self.precalentado
    let marca = Self.marca(diarizador)
    let pasadaFinal = PasadaFinal(
      parakeet: parakeet(), separacion: separacion,
      // Si una compilación está en curso, la pasada la espera; si nunca se
      // compiló, la pasada misma compila y la ventana lo dice.
      antesDeSeparar: {
        await precalentado?.value
        let guardada = try? String(contentsOf: Self.archivoDeLaMarca(diarizador), encoding: .utf8)
        return PrecalentadoDelDiarizador.vaACompilar(marcaGuardada: guardada, actual: marca)
      },
      alSeparar: { usado in Self.anotarLaMarca(usado) }
    )
    let politica = preferencias.audio
    pasada = Pasada(id: enDisco.id, titulo: enDisco.reunion.titulo, avance: AvanceDeLaPasada(etapa: .preparando))
    alCambiar?()
    let publicar: @Sendable (AvanceDeLaPasada) -> Void = { [weak self] avance in
      Task { @MainActor in self?.publicar(avance, id: enDisco.id) }
    }
    Task.detached(priority: .utility) { [weak self] in
      let reunion = await pasadaFinal.afinar(enDisco, diarizador: diarizador, avance: publicar)
      if reunion.estado == .lista {
        ConversionDelAudio.aplicar(
          [ReunionEnDisco(reunion: reunion, carpeta: enDisco.carpeta, enElRespaldo: enDisco.enElRespaldo)],
          politica: politica
        )
      }
      await self?.pasadaTermino(reunion)
    }
  }

  private func publicar(_ avance: AvanceDeLaPasada, id: String) {
    guard pasada?.id == id else { return }
    pasada?.avance = avance
  }

  private func pasadaTermino(_ reunion: Reunion) {
    afinando.remove(reunion.id)
    if separador == .porPreparar || separador == .preparando { revisarElSeparador() }
    if pasada?.id == reunion.id { pasada = nil }
    if idDelVivo == reunion.id {
      idDelVivo = nil
      vivo = GuionEnVivo()
      notas = []
    }
    if reunion.estado == .lista {
      aviso = .guionListo(id: reunion.id)
    } else if let falla = reunion.falla {
      aviso = .pasadaFallo(id: reunion.id, motivo: falla)
    }
    alCambiar?()
  }

  private func reflejar(_ enVivo: GrabadoraDeReunion.EnVivo) {
    guard var actual = enCurso else { return }
    let antes = actual
    actual.lugar = enVivo.lugar
    actual.espacioBajo = enVivo.espacioBajo
    actual.yo = PistaEnVivo(
      vigia: enVivo.yo.vigia, nivel: enVivo.yo.nivel, pareceFaltarPermiso: false, falla: enVivo.fallaDeYo
    )
    actual.ellos = PistaEnVivo(
      vigia: enVivo.ellos.vigia, nivel: enVivo.ellos.nivel, pareceFaltarPermiso: enVivo.ellos.pareceFaltarPermiso,
      falla: enVivo.fallaDeEllos
    )
    enCurso = actual
    // Los avisos, una vez cada uno: cuando la condición recién aparece.
    if actual.ellos.vigia == .sinAudio, antes.ellos.vigia != .sinAudio, actual.ellos.pareceFaltarPermiso {
      aviso = .faltaPermisoDelAudioDelSistema
    }
    if actual.yo.vigia == .sinAudio, antes.yo.vigia != .sinAudio { aviso = .microfonoMudo }
    if actual.espacioBajo, !antes.espacioBajo { aviso = .espacioBajo }
    if actual.lugar != antes.lugar || actual.yo.falla != antes.yo.falla || actual.ellos.falla != antes.ellos.falla {
      alCambiar?()
    }
  }

  /// Cuando se monta el volumen de la raíz (el SSD vuelve), muda lo que
  /// esperaba en el respaldo interno y afina lo que quedó a medias por una
  /// parte que estaba allá.
  private func escucharElDisco() {
    guard observadorDelDisco == nil else { return }
    observadorDelDisco = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didMountNotification, object: nil, queue: .main
    ) { [weak self] aviso in
      let montado = aviso.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
      MainActor.assumeIsolated {
        guard let self, let volumen = CarpetaDeReunion.volumen(de: self.preferencias.carpeta),
          montado?.standardizedFileURL.path == volumen.standardizedFileURL.path
        else { return }
        Self.logger.notice("Volvió el disco de las reuniones: muevo lo pendiente")
        self.alArrancar()
      }
    }
  }

  /// Al abrir Dilo, en segundo plano y sin modelos: repara lo que quedó
  /// grabando cuando la app murió, retoma las pasadas a medias, muda al SSD
  /// lo que esperaba el disco y aplica la retención del audio. Sólo lee
  /// `reunion.json`; no carga nada si no hay reuniones.
  func alArrancar() {
    let lector = self.lector
    let respaldo = self.respaldo
    let raiz = preferencias.carpeta
    let politica = preferencias.audio
    let grabandoAhora: Set<String> = enCurso.map { [$0.id] } ?? []
    escucharElDisco()
    Task.detached(priority: .background) { [weak self] in
      if GrabadoraDeReunion.sePuedeEscribirSinCrear(en: raiz) {
        _ = MudanzaDeReuniones.mudar(desde: respaldo, a: raiz, noTocar: grabandoAhora)
      }
      guard let todas = try? lector.todas() else { return }
      var pendientes: [ReunionEnDisco] = []
      for var enDisco in todas {
        if ReparacionDeReuniones.estaHuerfana(
          enDisco.reunion, grabandoAhora: grabandoAhora, estaVivo: RelojDelMac.estaVivo
        ) {
          if let reparada = try? ReparacionDeReuniones.reparar(enDisco) { enDisco.reunion = reparada }
        }
        // Una pasada que se cortó (la app se cerró afinando) o una reunión
        // interrumpida se afina; si le falta una parte, espera al disco.
        if [.interrumpida, .afinando].contains(enDisco.reunion.estado),
          ReparacionDeReuniones.partesQueFaltan(enDisco).isEmpty
        {
          pendientes.append(enDisco)
        }
      }
      ConversionDelAudio.aplicar(todas, politica: politica)
      await self?.retomar(pendientes)
      // Un separador bajado y sin compilar para este macOS (una
      // actualización tira lo compilado): se prepara ahora, en reposo.
      await self?.prepararElSeparador()
    }
  }

  /// Mira en el disco cómo está el separador elegido, sin cargar nada. Lo
  /// llama Ajustes al abrirse.
  func revisarElSeparador() {
    guard precalentado == nil else { return }
    let diarizador = Diarizador.para(preferencias.diarizador)
    Task { [weak self] in
      let estado = await Task.detached(priority: .utility) { Self.estadoEnDisco(diarizador) }.value
      guard let self, self.precalentado == nil else { return }
      self.separador = estado
    }
  }

  nonisolated private static func estadoEnDisco(_ diarizador: Diarizador) -> EstadoDelSeparador {
    guard SeparacionDeVoces.estaEnDisco(diarizador, carpeta: carpetaDeModelos) else { return .sinBajar }
    let guardada = try? String(contentsOf: archivoDeLaMarca(diarizador), encoding: .utf8)
    return PrecalentadoDelDiarizador.vaACompilar(marcaGuardada: guardada, actual: marca(diarizador))
      ? .porPreparar : .listo
  }

  /// Compila el separador para el Neural Engine en segundo plano, si hace
  /// falta y si se puede ahora (`PrecalentadoDelDiarizador.decidir`): nunca
  /// durante un dictado ni junto a una pasada. Con `bajarSiFalta` lo baja
  /// primero —sólo cuando la persona pidió reuniones: al grabar o con
  /// «Preparar ahora»—; bajar no compila, así que puede correr dictando.
  func prepararElSeparador(bajarSiFalta: Bool = false) {
    guard precalentado == nil else { return }
    let diarizador = Diarizador.para(preferencias.diarizador)
    let separacion = self.separacion ?? SeparacionDeVoces(carpetaDeModelos: Self.carpetaDeModelos)
    self.separacion = separacion
    precalentado = Task { [weak self] in
      var estado = await Task.detached(priority: .utility) { Self.estadoEnDisco(diarizador) }.value
      if estado == .sinBajar, bajarSiFalta {
        self?.separador = .bajando
        do {
          try await separacion.bajar(diarizador)
          estado = await Task.detached(priority: .utility) { Self.estadoEnDisco(diarizador) }.value
        } catch {
          Self.logger.error("No se pudo bajar el separador: \(error.localizedDescription, privacy: .public)")
          estado = .fallo(String(localized: "No pude bajar el separador de voces. Revisa la conexión."))
        }
      }
      guard let self else { return }
      let decision = PrecalentadoDelDiarizador.decidir(
        modeloEnDisco: estado == .porPreparar || estado == .listo,
        vaACompilar: estado == .porPreparar,
        dictando: dictando, afinando: !afinando.isEmpty, compilando: false
      )
      guard decision == .precalentar else {
        separador = estado
        precalentado = nil
        return
      }
      separador = .preparando
      let inicio = Date()
      do {
        try await separacion.preparar(diarizador)
        await separacion.soltar()
        Self.anotarLaMarca(diarizador)
        Self.logger.notice("Separador compilado para el Neural Engine en \(Int(Date().timeIntervalSince(inicio)), privacy: .public) s")
        separador = .listo
      } catch {
        separador = .fallo(error.localizedDescription)
      }
      precalentado = nil
    }
  }

  /// La marca de lo compilado, junto a los modelos.
  nonisolated static func archivoDeLaMarca(_ diarizador: Diarizador) -> URL {
    carpetaDeModelos.appending(path: ".precalentado-\(diarizador.rawValue)")
  }

  nonisolated static func marca(_ diarizador: Diarizador) -> String {
    PrecalentadoDelDiarizador.marca(
      diarizador: diarizador.rawValue, sistema: ProcessInfo.processInfo.operatingSystemVersionString,
      fluidAudio: diarizador.version
    )
  }

  nonisolated static func anotarLaMarca(_ diarizador: Diarizador) {
    try? Data(marca(diarizador).utf8).write(to: archivoDeLaMarca(diarizador), options: .atomic)
  }

  private func retomar(_ pendientes: [ReunionEnDisco]) {
    // De a una: dos pasadas a la vez se pelean el Neural Engine.
    guard let primera = pendientes.first else { return }
    afinar(primera)
    let resto = Array(pendientes.dropFirst())
    guard !resto.isEmpty else { return }
    Task { [weak self] in
      while let self, !self.afinando.isEmpty { try? await Task.sleep(for: .seconds(5)) }
      self?.retomar(resto)
    }
  }

  /// Las reuniones, de la más nueva a la más vieja, leídas fuera del hilo
  /// principal.
  func reunionesRecientes(maximo: Int = 50) async -> [ReunionEnDisco] {
    let lector = self.lector
    return await Task.detached(priority: .userInitiated) {
      Array(((try? lector.todas()) ?? []).prefix(maximo))
    }.value
  }

  /// Buscar por lo dicho y por quién lo dijo, sin tildes ni mayúsculas.
  func buscar(_ consulta: String, hablante: String? = nil, maximo: Int = 50) async -> [ResultadoDeBusqueda] {
    let lector = self.lector
    return await Task.detached(priority: .userInitiated) {
      let leidas = ((try? lector.todas()) ?? []).compactMap { r in
        LectorDeReuniones.guionLegible(de: r).map { (reunion: r.reunion, markdown: $0) }
      }
      return BusquedaEnReuniones.buscar(consulta, hablante: hablante, en: leidas, maximo: maximo)
    }.value
  }

  /// El guion de la última reunión lista, en Markdown, o nil si no hay.
  func guionDeLaUltima() async -> String? {
    let lector = self.lector
    return await Task.detached(priority: .userInitiated) {
      ((try? lector.todas()) ?? []).lazy.compactMap { LectorDeReuniones.guionLegible(de: $0) }.first
    }.value
  }

  /// Renombra a un hablante en todas sus líneas y regenera `guion.md`.
  func renombrar(hablante: String, a nombre: String?, en id: String) async throws {
    let lector = self.lector
    try await Task.detached(priority: .userInitiated) {
      guard let enDisco = try lector.reunion(id: id) else { return }
      _ = try EscritorDeReunion.renombrar(hablante, a: nombre, en: enDisco)
    }.value
  }

  /// Junta a `origen` en `destino` en todas sus palabras (el modelo partió a
  /// alguien en dos) y reescribe el guion.
  func juntar(_ origen: String, en destino: String, id: String) async throws {
    try await editarGuion(id: id) { palabras, reunion in
      EdicionDelGuion.juntar(origen, en: destino, palabras: &palabras, reunion: &reunion)
    }
  }

  /// Pasa una línea a otro hablante, o a uno nuevo con nil (el modelo juntó
  /// dos voces parecidas).
  func reasignar(_ linea: LineaDelGuion, a destino: String?, id: String) async throws {
    try await editarGuion(id: id) { palabras, reunion in
      EdicionDelGuion.reasignar(linea, a: destino, palabras: &palabras, reunion: &reunion)
    }
  }

  /// Lee, edita con una regla pura de `EdicionDelGuion` y guarda
  /// `reunion.json`, `guion.jsonl` y `guion.md` juntos, fuera del hilo
  /// principal.
  private func editarGuion(
    id: String, _ cambio: @escaping @Sendable (inout [PalabraDelGuion], inout Reunion) -> Void
  ) async throws {
    let lector = self.lector
    try await Task.detached(priority: .userInitiated) {
      guard let enDisco = try lector.reunion(id: id), enDisco.reunion.estado == .lista else { return }
      var palabras = LectorDeReuniones.palabras(de: enDisco)
      var reunion = enDisco.reunion
      cambio(&palabras, &reunion)
      try EscritorDeReunion.guardar(reunion, en: enDisco.carpeta)
      try EscritorDeReunion.guardarGuion(palabras, reunion: reunion, en: enDisco.carpeta)
    }.value
  }

  /// Manda la carpeta entera de una reunión a la Papelera: nunca un borrado
  /// definitivo desde Dilo. La que está grabando o afinando no se borra.
  func borrar(id: String) async throws {
    guard enCurso?.id != id, pasada?.id != id else { return }
    let lector = self.lector
    try await Task.detached(priority: .userInitiated) {
      guard let enDisco = try lector.reunion(id: id) else { return }
      try FileManager.default.trashItem(at: enDisco.carpeta, resultingItemURL: nil)
    }.value
  }

  /// Una reunión leída de nuevo, con su guion en líneas y sus notas, fuera
  /// del hilo principal. Nil si ya no está.
  func leer(id: String) async -> (reunion: ReunionEnDisco, lineas: [LineaDelGuion], notas: [NotaDeLaReunion])? {
    let lector = self.lector
    return await Task.detached(priority: .userInitiated) {
      guard let enDisco = try? lector.reunion(id: id) else { return nil }
      return (enDisco, LectorDeReuniones.lineas(de: enDisco), LectorDeReuniones.notas(de: enDisco))
    }.value
  }

  /// Los modelos de separar voces, junto al de Parakeet: en
  /// `Application Support/Dilo/models/`, se borran con Dilo.
  nonisolated static var carpetaDeModelos: URL { ParakeetModelStore.carpeta }
}

extension GrabadoraDeReunion {
  /// Como `sePuedeEscribir`, pero sin crear la raíz: al arrancar sólo se muda
  /// si el SSD ya está y la carpeta existe.
  nonisolated static func sePuedeEscribirSinCrear(en raiz: URL) -> Bool {
    FileManager.default.isWritableFile(atPath: raiz.path(percentEncoded: false))
  }
}

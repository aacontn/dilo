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

  /// Para lo que no es SwiftUI (el panel de la barra): cada cambio de
  /// `enCurso` o `pasada`.
  @ObservationIgnored var alCambiar: (() -> Void)?

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let respaldo: URL
  @ObservationIgnored private let parakeet: @MainActor () -> ParakeetEngine
  @ObservationIgnored private var grabadora: GrabadoraDeReunion?
  @ObservationIgnored private var afinando: Set<String> = []
  @ObservationIgnored private var separacion: SeparacionDeVoces?
  @ObservationIgnored private var observadorDelDisco: (any NSObjectProtocol)?
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
      let grabadora = try GrabadoraDeReunion.empezar(
        evento: evento ?? EventoActualDelCalendario.leer(), preferencias: preferencias, respaldo: respaldo
      )
      self.grabadora = grabadora
      enCurso = EnCurso(
        id: grabadora.reunion.id, titulo: grabadora.reunion.titulo, inicio: grabadora.reunion.inicio,
        carpeta: grabadora.carpeta, lugar: grabadora.enVivo.lugar
      )
      reflejar(grabadora.enVivo)
      grabadora.alCambiar = { [weak self] enVivo in self?.reflejar(enVivo) }
      alCambiar?()
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
    let enDisco = grabadora.terminar()
    self.grabadora = nil
    enCurso = nil
    alCambiar?()
    afinar(enDisco)
    return enDisco.id
  }

  /// Un dictado empezó o terminó: si hay reunión, sus palabras de `yo` no van
  /// al guion.
  func dictado(enCurso: Bool) {
    grabadora?.dictado(enCurso: enCurso)
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
    let pasadaFinal = PasadaFinal(parakeet: parakeet(), separacion: separacion)
    let diarizador = Diarizador.para(preferencias.diarizador)
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
    if pasada?.id == reunion.id { pasada = nil }
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
    }
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

  /// Los modelos de separar voces, junto al de Parakeet: en
  /// `Application Support/Dilo/models/`, se borran con Dilo.
  static var carpetaDeModelos: URL { ParakeetModelStore.carpeta }
}

extension GrabadoraDeReunion {
  /// Como `sePuedeEscribir`, pero sin crear la raíz: al arrancar sólo se muda
  /// si el SSD ya está y la carpeta existe.
  nonisolated static func sePuedeEscribirSinCrear(en raiz: URL) -> Bool {
    FileManager.default.isWritableFile(atPath: raiz.path(percentEncoded: false))
  }
}

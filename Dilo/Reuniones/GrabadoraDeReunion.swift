import AppKit
import DiloReuniones
import Foundation
import os

/// Por qué no empezó una reunión, en una frase con qué hacer.
enum FallaAlGrabar: Error, Equatable, LocalizedError {
  case yaGraba
  case sinEspacio(libre: Int64)
  case sinCarpeta(String)
  /// Ni el micrófono ni el audio del sistema abrieron.
  case ningunaPista(String)

  var errorDescription: String? {
    switch self {
    case .yaGraba: String(localized: "Ya hay una reunión grabando.")
    case let .sinEspacio(libre):
      String(localized: "Queda muy poco disco para grabar (\(libre / 1_000_000) MB). Libera al menos 1 GB.")
    case let .sinCarpeta(detalle): String(localized: "No pude crear la carpeta de la reunión: \(detalle)")
    case let .ningunaPista(detalle): String(localized: "No pude abrir ni el micrófono ni el audio del Mac: \(detalle)")
    }
  }
}

/// Una reunión grabándose: las dos pistas, sus anclas, `reunion.json` y el
/// disco. Si una pista falla la otra sigue; si el SSD se desmonta, las dos
/// siguen en el respaldo interno sin cortar (spec, «Captura» y «Datos»).
@MainActor
final class GrabadoraDeReunion {
  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")

  struct EnVivo: Equatable {
    var yo = PistaEnDisco.Estado()
    var ellos = PistaEnDisco.Estado()
    var fallaDeYo: String?
    var fallaDeEllos: String?
    var espacioBajo = false
    var lugar: PoliticaDeDisco.Lugar
  }

  private(set) var reunion: Reunion
  private(set) var carpeta: URL
  private(set) var enVivo: EnVivo
  private(set) var notas: [NotaDeLaReunion] = []
  var alCambiar: ((EnVivo) -> Void)?

  private let respaldo: URL
  private let inicioHost: Double
  private let relojes: EscritorDeRelojes
  private let pistaYo: PistaEnDisco
  private let pistaEllos: PistaEnDisco
  private let microfono: CapturaDelMicrofono
  private let sistema: CapturaDelSistema
  private var dictandoDesde: Double?
  private var vigiaDelDisco: Task<Void, Never>?
  private var observadorDelDisco: (any NSObjectProtocol)?

  /// Arma la carpeta, decide el disco y abre las dos pistas. Lanza sólo si no
  /// se puede grabar nada.
  static func empezar(
    evento: EventoDeLaReunion?, preferencias: PreferenciasDeReuniones, respaldo: URL,
    alOir: @escaping @Sendable (TranscripcionEnVivo.Entrega) -> Void
  ) throws(FallaAlGrabar) -> GrabadoraDeReunion {
    let inicio = Date()
    let titulo = evento?.titulo.trimmingCharacters(in: .whitespacesAndNewlines).nilSiVacio ?? String(localized: "Reunión")
    let raiz = preferencias.carpeta
    let destino = PoliticaDeDisco.destino(
      raizDisponible: Self.sePuedeEscribir(en: raiz),
      libreEnRaiz: Self.libre(en: raiz),
      libreEnRespaldo: Self.libre(en: respaldo)
    )
    let lugar: PoliticaDeDisco.Lugar
    switch destino {
    case let .sinEspacio(_, libre): throw .sinEspacio(libre: libre)
    case let .en(elegido): lugar = elegido
    }
    let base = lugar == .raiz ? raiz : respaldo
    let año = CarpetaDeReunion.año(inicio: inicio)
    let existentes = Set(
      (try? FileManager.default.contentsOfDirectory(atPath: base.appending(path: año).path(percentEncoded: false))) ?? []
    )
    let carpeta = CarpetaDeReunion.url(
      raiz: base, año: año, nombre: CarpetaDeReunion.nombre(inicio: inicio, titulo: titulo, existentes: existentes)
    )
    var reunion = Reunion(
      id: CarpetaDeReunion.id(inicio: inicio), titulo: titulo, inicio: inicio, evento: evento,
      salida: HALDeReuniones.salidaDeAudio, proceso: RelojDelMac.esteProceso
    )
    do {
      try EscritorDeReunion.guardar(reunion, en: carpeta)
    } catch {
      throw .sinCarpeta(error.localizedDescription)
    }
    let grabadora = GrabadoraDeReunion(
      reunion: reunion, carpeta: carpeta, lugar: lugar, respaldo: respaldo,
      microfonoUID: preferencias.microfonoUID, alOir: alOir
    )
    let abiertas = grabadora.abrirPistas()
    guard abiertas > 0 else {
      grabadora.cerrar()
      // Sólo quedaron cabeceras vacías: a la Papelera, nunca un borrado
      // definitivo.
      try? FileManager.default.trashItem(at: carpeta, resultingItemURL: nil)
      throw .ningunaPista([grabadora.enVivo.fallaDeYo, grabadora.enVivo.fallaDeEllos].compactMap { $0 }.joined(separator: " "))
    }
    reunion = grabadora.reunion
    grabadora.vigilarElDisco()
    Self.logger.notice("Reunión empezó en \(lugar.rawValue, privacy: .public), salida \(reunion.salida.rawValue, privacy: .public)")
    return grabadora
  }

  private init(
    reunion: Reunion, carpeta: URL, lugar: PoliticaDeDisco.Lugar, respaldo: URL, microfonoUID: String?,
    alOir: @escaping @Sendable (TranscripcionEnVivo.Entrega) -> Void
  ) {
    self.reunion = reunion
    self.carpeta = carpeta
    self.respaldo = respaldo
    enVivo = EnVivo(lugar: lugar)
    inicioHost = RelojDelMac.ahora
    relojes = EscritorDeRelojes(carpeta: carpeta)
    relojes.anotar(AnclaDeReloj(pista: nil, muestra: 0, host: inicioHost))
    let bufferDeYo = BuferAnular()
    let bufferDeEllos = BuferAnular()
    microfono = CapturaDelMicrofono(bufer: bufferDeYo, uidElegido: microfonoUID)
    sistema = CapturaDelSistema(bufer: bufferDeEllos)
    let relojes = self.relojes
    // Las pistas avisan desde su cola; acá se salta al hilo principal. El
    // mensajero existe porque las pistas nacen antes que `self`.
    let mensajero = Mensajero()
    pistaYo = PistaEnDisco(
      pista: .yo, carpeta: carpeta, bufer: bufferDeYo, anotarAncla: { relojes.anotar($0) },
      alCambiar: { estado in Task { @MainActor in mensajero.grabadora?.pista(.yo, cambio: estado) } },
      alFallar: { motivo in Task { @MainActor in mensajero.grabadora?.pistaNoEscribe(.yo, motivo) } },
      alOir: alOir
    )
    pistaEllos = PistaEnDisco(
      pista: .ellos, carpeta: carpeta, bufer: bufferDeEllos, anotarAncla: { relojes.anotar($0) },
      alCambiar: { estado in Task { @MainActor in mensajero.grabadora?.pista(.ellos, cambio: estado) } },
      alFallar: { motivo in Task { @MainActor in mensajero.grabadora?.pistaNoEscribe(.ellos, motivo) } },
      alOir: alOir
    )
    mensajero.grabadora = self
  }

  /// A quién le avisan las pistas. Se escribe una vez, en el hilo principal,
  /// antes de que ninguna pista arranque.
  private final class Mensajero: @unchecked Sendable {
    @MainActor weak var grabadora: GrabadoraDeReunion?
  }

  /// Abre cada pista por su lado: si una falla, la otra sigue (la regla de
  /// la secundaria del Tauri). Devuelve cuántas abrieron.
  private func abrirPistas() -> Int {
    var abiertas = 0
    for (pista, escritor) in [(Pista.yo, pistaYo), (.ellos, pistaEllos)] {
      do {
        try escritor.empezar()
      } catch {
        anotarFalla(pista, error.localizedDescription)
        continue
      }
      do {
        if pista == .yo {
          microfono.alFallar = { [weak self] motivo in Task { @MainActor in self?.anotarFalla(.yo, motivo) } }
          try microfono.empezar()
          marcarDispositivo(.yo, microfono.dispositivo)
        } else {
          sistema.alFallar = { [weak self] motivo in Task { @MainActor in self?.anotarFalla(.ellos, motivo) } }
          try sistema.empezar()
          marcarDispositivo(.ellos, sistema.dispositivo)
        }
        abiertas += 1
      } catch {
        // El WAV queda, vacío: la reunión dice qué pista falló y por qué.
        anotarFalla(pista, error.localizedDescription)
      }
    }
    guardar()
    return abiertas
  }

  /// Un dictado empezó o terminó durante la reunión: sus palabras de `yo` no
  /// van al guion.
  func dictado(enCurso: Bool) {
    let ahora = RelojDelMac.ahora - inicioHost
    if enCurso {
      dictandoDesde = ahora
    } else if let desde = dictandoDesde {
      reunion.dictados.append(TramoDeDictado(desde: desde, hasta: ahora))
      dictandoDesde = nil
      guardar()
    }
  }

  /// Una nota de la persona, con la hora en que la escribió. A disco en el
  /// acto: si la app muere, la nota no se pierde con ella.
  @discardableResult
  func anotar(_ texto: String) -> Bool {
    guard let limpio = NotaDeLaReunion.limpiar(texto) else { return false }
    notas.append(NotaDeLaReunion(en: Date().timeIntervalSince(reunion.inicio), texto: limpio))
    guardarNotas()
    return true
  }

  private func guardarNotas() {
    do {
      try EscritorDeReunion.guardarNotas(notas, en: carpeta)
    } catch {
      // Sigue en la RAM: la próxima nota, o la mudanza al respaldo, la escribe.
      Self.logger.error("No pude guardar las notas: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Cierra las capturas, completa los WAV y deja la reunión lista para
  /// afinar.
  func terminar() -> ReunionEnDisco {
    if dictandoDesde != nil { dictado(enCurso: false) }
    cerrar()
    reunion.fin = Date()
    reunion.estado = .afinando
    reunion.proceso = nil
    guardar()
    Self.logger.notice("Reunión terminó: \(Int(self.reunion.duracion()), privacy: .public) s")
    return ReunionEnDisco(reunion: reunion, carpeta: carpeta, enElRespaldo: enVivo.lugar == .respaldo)
  }

  private func cerrar() {
    vigiaDelDisco?.cancel()
    vigiaDelDisco = nil
    if let observadorDelDisco { NSWorkspace.shared.notificationCenter.removeObserver(observadorDelDisco) }
    observadorDelDisco = nil
    microfono.detener()
    sistema.detener()
    pistaYo.terminar()
    pistaEllos.terminar()
    actualizarPartes()
  }

  private func pista(_ pista: Pista, cambio estado: PistaEnDisco.Estado) {
    if pista == .yo { enVivo.yo = estado } else { enVivo.ellos = estado }
    if pista == .ellos, !estado.yaSono, VigiaDeSilencio.tocaRearmar(segundosEnCeros: estado.segundosEnCeros) {
      Self.logger.notice("La pista ellos nunca sonó: rearmo el tap por si acaban de dar el permiso")
      sistema.rearmar()
    }
    alCambiar?(enVivo)
  }

  private func anotarFalla(_ pista: Pista, _ motivo: String) {
    if pista == .yo { enVivo.fallaDeYo = motivo } else { enVivo.fallaDeEllos = motivo }
    if let i = reunion.pistas.firstIndex(where: { $0.pista == pista }) { reunion.pistas[i].falla = motivo }
    Self.logger.error("Pista \(pista.rawValue, privacy: .public) falló: \(motivo, privacy: .private)")
    guardar()
    alCambiar?(enVivo)
  }

  private func marcarDispositivo(_ pista: Pista, _ nombre: String?) {
    if let i = reunion.pistas.firstIndex(where: { $0.pista == pista }) { reunion.pistas[i].dispositivo = nombre }
  }

  /// Una pista no pudo escribir: el disco se fue o se llenó. Las dos pasan al
  /// respaldo interno, con una parte nueva cada una.
  private func pistaNoEscribe(_ pista: Pista, _ motivo: String) {
    guard enVivo.lugar == .raiz else {
      anotarFalla(pista, motivo)
      return
    }
    mudarAlRespaldo()
  }

  private func mudarAlRespaldo() {
    guard enVivo.lugar == .raiz else { return }
    let nueva = CarpetaDeReunion.url(
      raiz: respaldo, año: carpeta.deletingLastPathComponent().lastPathComponent, nombre: carpeta.lastPathComponent
    )
    Self.logger.notice("El disco de la reunión no está: sigo en el respaldo interno")
    enVivo.lugar = .respaldo
    carpeta = nueva
    relojes.mudarA(nueva)
    _ = pistaYo.mudarA(nueva)
    _ = pistaEllos.mudarA(nueva)
    actualizarPartes()
    guardar()
    if !notas.isEmpty { guardarNotas() }
    alCambiar?(enVivo)
  }

  private func actualizarPartes() {
    for (pista, escritor) in [(Pista.yo, pistaYo), (.ellos, pistaEllos)] where !escritor.partes.isEmpty {
      if let i = reunion.pistas.firstIndex(where: { $0.pista == pista }) { reunion.pistas[i].partes = escritor.partes }
    }
  }

  private func guardar() {
    actualizarPartes()
    do {
      try EscritorDeReunion.guardar(reunion, en: carpeta)
    } catch {
      Self.logger.error("No pude guardar reunion.json: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Cada 30 s mira el espacio (avisa bajo 500 MB) y escucha si el volumen se
  /// desmonta.
  private func vigilarElDisco() {
    vigiaDelDisco = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard let self else { return }
        let bajo = PoliticaDeDisco.hayQueAvisar(libre: Self.libre(en: self.carpeta))
        if bajo != self.enVivo.espacioBajo {
          self.enVivo.espacioBajo = bajo
          self.alCambiar?(self.enVivo)
        }
      }
    }
    guard let volumen = CarpetaDeReunion.volumen(de: carpeta) else { return }
    observadorDelDisco = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
    ) { [weak self] aviso in
      let desmontado = aviso.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
      guard desmontado?.standardizedFileURL.path == volumen.standardizedFileURL.path else { return }
      MainActor.assumeIsolated { self?.mudarAlRespaldo() }
    }
  }

  /// Si se puede escribir en la raíz: el volumen está montado y la carpeta se
  /// deja crear. Una raíz fuera de `/Volumes` sólo tiene que dejarse crear.
  static func sePuedeEscribir(en raiz: URL) -> Bool {
    if let volumen = CarpetaDeReunion.volumen(de: raiz),
      !FileManager.default.fileExists(atPath: volumen.path(percentEncoded: false))
    {
      return false
    }
    return (try? FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)) != nil
  }

  /// Bytes libres donde está (o estaría) la carpeta.
  static func libre(en url: URL) -> Int64? {
    var actual = url
    while !FileManager.default.fileExists(atPath: actual.path(percentEncoded: false)), actual.pathComponents.count > 1 {
      actual.deleteLastPathComponent()
    }
    let valores = try? actual.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return valores?.volumeAvailableCapacityForImportantUsage
  }
}

/// Escribe `relojes.jsonl` en su propia cola. Guarda las anclas en memoria
/// (720 por hora entre las dos pistas) para reescribirlas enteras si la
/// reunión se muda al respaldo: la mudanza del SSD copia la versión del
/// respaldo, y tiene que tenerlas todas.
final class EscritorDeRelojes: @unchecked Sendable {
  private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.reuniones.relojes", qos: .utility)
  private var archivo: URL
  private var anclas: [AnclaDeReloj] = []

  init(carpeta: URL) {
    archivo = carpeta.appending(path: CarpetaDeReunion.relojes)
  }

  func anotar(_ ancla: AnclaDeReloj) {
    cola.async { [self] in
      anclas.append(ancla)
      let datos = AnclaDeReloj.codificar(ancla)
      if let manija = try? FileHandle(forWritingTo: archivo) {
        _ = try? manija.seekToEnd()
        try? manija.write(contentsOf: datos)
        try? manija.close()
      } else {
        try? datos.write(to: archivo)
      }
    }
  }

  func mudarA(_ carpeta: URL) {
    cola.sync {
      archivo = carpeta.appending(path: CarpetaDeReunion.relojes)
      try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
      try? anclas.reduce(into: Data()) { $0.append(AnclaDeReloj.codificar($1)) }.write(to: archivo, options: .atomic)
    }
  }
}

extension String {
  fileprivate var nilSiVacio: String? { isEmpty ? nil : self }
}

import AppKit
import DiloCapabilities
import DiloModes
import DiloText

/// Cómo se lee el contexto de otra app. Una costura, para que los tests del
/// controlador digan qué hay alrededor del cursor sin una app viva.
struct LectoresDeContexto: Sendable {
  /// El texto alrededor del cursor del ancla, y la selección.
  var alrededor: @Sendable (AnclaDelFoco, Int) async -> TextoAlrededorDelCursor
  /// El dominio y la ruta de la página del navegador `pid`, o nil. Se rinde
  /// en el plazo que recibe.
  var sitio: @Sendable (pid_t, Duration) async -> String?

  /// Los del anfitrión, fuera del actor principal: una app lenta en contestar
  /// no traba la muesca ni el micrófono. En App Store el anfitrión contesta
  /// vacío sin preguntar nada.
  static let delAnfitrion = LectoresDeContexto(
    alrededor: { ancla, tope in
      await Task.detached(priority: .userInitiated) {
        Anfitrion.actual.textoAlrededor(de: ancla, tope: tope)
      }.value
    },
    sitio: { pid, plazo in
      await Task.detached(priority: .userInitiated) {
        Anfitrion.actual.sitio(dePid: pid, hasta: .now + plazo)
      }.value
    }
  )

  static let ninguno = LectoresDeContexto(alrededor: { _, _ in TextoAlrededorDelCursor() }, sitio: { _, _ in nil })
}

/// Lo que rodeaba al dictado, leído en paralelo con la apertura del
/// micrófono y recogido al soltar.
///
/// **Nunca antes del micrófono y nunca se espera**: al soltar se toma lo que
/// llegó, y lo que no llegó no existe. Lo leído vive acá hasta que la sesión
/// lo recoge o termina, y se suelta: ni historial, ni disco, ni log.
@MainActor
final class CapturaDeContexto {
  /// Cuánto se lee a cada lado del cursor. El sobre recorta después según
  /// el proveedor; leer más no le sirve a nadie.
  static let caracteresAlrededor = 500
  /// Un navegador lento no puede retener nada: lo que no llegó en medio
  /// segundo no llega.
  static let plazoDelSitio = Duration.milliseconds(500)

  private var capturado = ContextoCapturado()
  /// Los interruptores como estaban al empezar: cambiar Ajustes a mitad de
  /// dictado aplica al siguiente (ADR-0004).
  private var fuentes = FuentesDeContexto.deFabrica
  private var tareas: [Task<Void, Never>] = []
  /// Sube con cada sesión: una lectura vieja que llega tarde no se mezcla
  /// con la de la sesión siguiente.
  private var turno = 0

  /// Empieza a leer. Lo que no se puede leer en este anfitrión ni se
  /// intenta: lo decide `HostCapabilities.admite`, como todo lo que lee otra
  /// app.
  ///
  /// - Parameter sitioParaElegirModo: algún modo de la sesión se elige por
  ///   sitio, así que la página se lee aunque no vaya al prompt.
  /// - Parameter leerAntesDelCursor: «Adaptar la mayúscula al cursor» está
  ///   prendido: se leen los caracteres antes del cursor aunque el campo no
  ///   vaya al prompt.
  func empezar(
    destino: TextInsertionService.Target?,
    fuentes: FuentesDeContexto,
    sitioParaElegirModo: Bool,
    leerAntesDelCursor: Bool = false,
    lectores: LectoresDeContexto,
    anfitrion: any HostCapabilities = Anfitrion.actual
  ) {
    cancelar()
    self.fuentes = fuentes
    capturado = ContextoCapturado(
      nombreDeApp: destino?.applicationName, bundleID: destino?.bundleID
    )
    guard let destino else { return }
    let turno = turno

    // Sin rango en el ancla (un editor web) no hay de dónde medir: «nada
    // antes» sería mentira, y el dictado quedaría con mayúscula de más.
    let mideElCursor = leerAntesDelCursor && destino.ancla?.seleccion != nil
    if fuentes.leeElCampo, anfitrion.admite(.contextoDelCampo), let ancla = destino.ancla {
      tareas.append(Task { [weak self] in
        let leido = await lectores.alrededor(ancla, Self.caracteresAlrededor)
        guard let self, self.turno == turno, !Task.isCancelled else { return }
        capturado.textoAntes = leido.antes
        capturado.textoDespues = leido.despues
        capturado.seleccion = leido.seleccion
        if mideElCursor { capturado.antesDelCursor = leido.antes }
      })
    } else if mideElCursor, anfitrion.admite(.contextoDelCampo), let ancla = destino.ancla {
      // Sólo lo que hace falta para la mayúscula: tres caracteres.
      tareas.append(Task { [weak self] in
        let leido = await lectores.alrededor(ancla, AjusteAlCursor.caracteresQueMira)
        guard let self, self.turno == turno, !Task.isCancelled else { return }
        capturado.antesDelCursor = leido.antes
      })
    }

    if fuentes.sitio || sitioParaElegirModo, anfitrion.admite(.sitioDelNavegador),
      LectorDeSitio.esNavegador(destino.bundleID) {
      let pid = destino.processIdentifier
      tareas.append(Task { [weak self] in
        let sitio = await lectores.sitio(pid, Self.plazoDelSitio)
        guard let self, self.turno == turno, !Task.isCancelled else { return }
        capturado.sitio = sitio
      })
    }
  }

  /// Lo que llegó hasta ahora, con los interruptores de la sesión, y se
  /// suelta. Sin esperar nada.
  func recoger() -> (capturado: ContextoCapturado, fuentes: FuentesDeContexto) {
    let listo = (capturado, fuentes)
    cancelar()
    return listo
  }

  /// Termina la captura y olvida lo leído. Se llama en cada final de
  /// sesión: soltar, Esc, una falla.
  func cancelar() {
    turno += 1
    tareas.forEach { $0.cancel() }
    tareas = []
    capturado = ContextoCapturado()
    fuentes = .deFabrica
  }

  /// Lo leído hasta ahora, sin soltarlo. Para los tests.
  var leidoHastaAhora: ContextoCapturado { capturado }
  /// Sólo para los tests: si todavía hay algo guardado.
  var estaVacia: Bool { capturado == ContextoCapturado() }
}

import DiloCapabilities
import DiloConsumo
import Foundation

/// Lo que un costado de la muesca dibuja: una etiqueta, un valor, y cuán
/// lleno está, para el color. Y el detalle que se abre con el hover.
struct LadoDeLaMuesca: Equatable, Sendable {
  let etiqueta: String
  let valor: String
  /// Del 0 al 100 cuando el dato es un porcentaje, o nil. Es lo que pinta el
  /// valor de mango cerca del límite y de rojo encima.
  let nivel: Double?
  /// Las filas del panel del hover: cada ventana con su reinicio
  /// (`DetalleDelDato`). Vacío mientras no hay nada leído.
  var detalle: [FilaDelDetalle] = []
}

/// Quien mantiene al día los dos costados de la muesca.
///
/// Corre sólo si alguno de los dos tiene un dato elegido: con los dos en
/// «ninguno» no hay ninguna tarea viva, y el reposo sigue costando lo que
/// cuesta una ventana quieta (spec §3). Encendido, lee a tres ritmos:
///
/// - **CPU y RAM cada tres segundos**, que es lo que tarda en cambiar algo que
///   valga la pena mirar. Dos llamadas de Mach, microsegundos.
/// - **Los archivos de Claude Code y de Codex cada treinta.** La lectura es
///   incremental (`LectorDeClaude`) y la de Codex lee sólo la cola del último
///   archivo: medido el 2026-09-23 en la máquina de Alfonso, 3 ms y 12 ms.
/// - **El porcentaje del plan de Claude cada dos minutos**, como CodexBar, y
///   sólo si la persona lo encendió: es una consulta a Anthropic con su sesión.
@MainActor
final class DatosDeLaMuesca {
  /// Se llama con los dos costados cada vez que cambia algo que se ve.
  var alCambiar: ((LadoDeLaMuesca?, LadoDeLaMuesca?) -> Void)?

  private let muestra = MuestraDelSistema()
  private let codex: LectorDeCodex
  private let claudeLocal: LectorDeClaude
  private let claudePlan: ClienteDeUsoDeClaude

  private var izquierdo = DatoDeLaMuesca.ninguno
  private var derecho = DatoDeLaMuesca.ninguno
  private var porcentajeDeClaude = false
  private var tarea: Task<Void, Never>?

  private var cpu: Double?
  private var ram: Double?
  private var consumoDeCodex: ConsumoDeIA?
  private var tokensDeClaude: ConsumoDeIA?
  private var planDeClaude: (consumo: ConsumoDeIA, leido: Date)?
  private var ultimaLecturaDeArchivos = Date.distantPast
  private var ultimaConsultaDelPlan = Date.distantPast
  private var planEsperaHasta = Date.distantPast
  private var publicado: (LadoDeLaMuesca?, LadoDeLaMuesca?) = (nil, nil)

  static let cadenciaDelSistema: Duration = .seconds(3)
  static let cadenciaDeLosArchivos: TimeInterval = 30
  static let cadenciaDelPlan: TimeInterval = 120
  /// Un porcentaje del plan más viejo que esto ya no se muestra: mejor los
  /// tokens de ahora que un porcentaje de hace un rato presentado como actual.
  static let vigenciaDelPlan: TimeInterval = 10 * 60

  init(inicio: URL = URL(filePath: NSHomeDirectory())) {
    // Las carpetas las dice la detección, que es la que Ajustes usa para
    // contar si hay de dónde leer: un solo lugar sabe dónde vive cada cosa.
    codex = LectorDeCodex(sesiones: DeteccionDeFuentes.carpeta(de: .codex, en: inicio)!)
    claudeLocal = LectorDeClaude(proyectos: DeteccionDeFuentes.carpeta(de: .claude, en: inicio)!)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    claudePlan = ClienteDeUsoDeClaude(agente: "Dilo/\(version)")
  }

  /// Si este anfitrión puede leer un dato. En App Store el sandbox no deja
  /// entrar a las carpetas de Claude Code ni de Codex: ahí esos datos no
  /// ocupan costado y su tarjeta de Ajustes dice por qué.
  nonisolated static func disponible(_ dato: DatoDeLaMuesca) -> Bool {
    !dato.leeArchivosDeOtraApp || Anfitrion.actual.admite(.consumoDeIADeOtrasApps)
  }

  /// Toma lo elegido en Ajustes y arranca, reinicia o apaga la tarea.
  func configurar(izquierdo: DatoDeLaMuesca, derecho: DatoDeLaMuesca, porcentajeDeClaude: Bool) {
    self.izquierdo = Self.disponible(izquierdo) ? izquierdo : .ninguno
    self.derecho = Self.disponible(derecho) ? derecho : .ninguno
    self.porcentajeDeClaude = porcentajeDeClaude
    tarea?.cancel()
    tarea = nil
    ultimaLecturaDeArchivos = .distantPast
    ultimaConsultaDelPlan = .distantPast
    guard self.izquierdo != .ninguno || self.derecho != .ninguno else {
      publicar()
      return
    }
    tarea = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refrescar()
        self.publicar()
        try? await Task.sleep(for: self.usaElSistema ? Self.cadenciaDelSistema : .seconds(Self.cadenciaDeLosArchivos))
      }
    }
  }

  /// Si alguno de los dos costados lleva un dato, ya filtrado por lo que este
  /// anfitrión puede leer.
  var llevaDatos: Bool { izquierdo != .ninguno || derecho != .ninguno }

  private var elegidos: Set<DatoDeLaMuesca> { [izquierdo, derecho] }
  private var usaElSistema: Bool { !elegidos.isDisjoint(with: [.cpu, .ram]) }

  private func refrescar() async {
    let ahora = Date()
    if elegidos.contains(.cpu) { cpu = muestra.cpu() ?? cpu }
    if elegidos.contains(.ram) { ram = muestra.ram() }

    if ahora.timeIntervalSince(ultimaLecturaDeArchivos) >= Self.cadenciaDeLosArchivos {
      ultimaLecturaDeArchivos = ahora
      if elegidos.contains(.codex) {
        let lector = codex
        consumoDeCodex = await Task.detached(priority: .utility) { lector.leer() }.value
      }
      if elegidos.contains(.claude) { tokensDeClaude = await claudeLocal.leer() }
    }

    if elegidos.contains(.claude), porcentajeDeClaude, ahora >= planEsperaHasta,
      ahora.timeIntervalSince(ultimaConsultaDelPlan) >= Self.cadenciaDelPlan {
      ultimaConsultaDelPlan = ahora
      do {
        planDeClaude = (try await claudePlan.leer(), ahora)
      } catch ClienteDeUsoDeClaude.Falla.esperar(let hasta) {
        planEsperaHasta = hasta
      } catch {
        // Sin sesión, sin permiso o sin red: siguen los tokens. No se anota
        // nada del error en el registro, que podría llevar la respuesta.
      }
    }
  }

  private func publicar() {
    let nuevo = (lado(izquierdo), lado(derecho))
    guard nuevo != publicado else { return }
    publicado = nuevo
    alCambiar?(nuevo.0, nuevo.1)
  }

  private func lado(_ dato: DatoDeLaMuesca) -> LadoDeLaMuesca? {
    let etiqueta = TextoDelDato.etiqueta(dato)
    let ahora = Date()
    switch dato {
    case .ninguno:
      return nil
    case .cpu:
      return LadoDeLaMuesca(
        etiqueta: etiqueta,
        valor: cpu.map(TextoDelDato.porcentaje) ?? "–",
        nivel: cpu,
        detalle: DetalleDelDato.sistema(cpu)
      )
    case .ram:
      return LadoDeLaMuesca(
        etiqueta: etiqueta,
        valor: ram.map(TextoDelDato.porcentaje) ?? "–",
        nivel: ram,
        detalle: DetalleDelDato.sistema(ram)
      )
    case .codex:
      return ladoDeIA(
        etiqueta,
        consumoDeCodex,
        detalle: DetalleDelDato.codex(consumoDeCodex, ahora: ahora),
        ahora: ahora
      )
    case .claude:
      let plan = planVigente(ahora: ahora)
      return ladoDeIA(
        etiqueta,
        plan ?? tokensDeClaude,
        detalle: DetalleDelDato.claude(tokens: tokensDeClaude, plan: plan, ahora: ahora),
        ahora: ahora
      )
    }
  }

  /// El porcentaje del plan de Claude, si se pidió y es de hace poco.
  private func planVigente(ahora: Date) -> ConsumoDeIA? {
    guard porcentajeDeClaude, let plan = planDeClaude,
      ahora.timeIntervalSince(plan.leido) < Self.vigenciaDelPlan
    else { return nil }
    return plan.consumo
  }

  private func ladoDeIA(
    _ etiqueta: String,
    _ consumo: ConsumoDeIA?,
    detalle: [FilaDelDetalle],
    ahora: Date
  ) -> LadoDeLaMuesca {
    guard let ventana = consumo?.ventanaCorta.vigente(en: ahora) else {
      return LadoDeLaMuesca(etiqueta: etiqueta, valor: "–", nivel: nil)
    }
    return LadoDeLaMuesca(
      etiqueta: etiqueta,
      valor: TextoDelDato.valor(ventana) ?? "–",
      nivel: ventana.porcentaje,
      detalle: detalle
    )
  }
}

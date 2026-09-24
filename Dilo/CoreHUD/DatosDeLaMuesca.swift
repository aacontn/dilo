import DiloCapabilities
import DiloConsumo
import Foundation

/// Lo que un costado de la muesca dibuja: de qué es —su ícono—, un valor, y
/// cuán lleno está, para el color y la barrita. Y el detalle que se abre con
/// el hover.
struct LadoDeLaMuesca: Equatable, Sendable {
  let dato: DatoDeLaMuesca
  let valor: String
  /// Del 0 al 100 cuando el dato es un porcentaje, o nil. Es lo que pinta el
  /// valor de mango cerca del límite y de rojo encima.
  let nivel: Double?
  /// Las filas del panel del hover: cada ventana con su reinicio
  /// (`DetalleDelDato`). Vacío mientras no hay nada leído.
  var detalle: [FilaDelDetalle] = []

  /// El nombre, para VoiceOver y para el encabezado del detalle: en el
  /// costado va el ícono.
  var etiqueta: String { TextoDelDato.etiqueta(dato) }
}

/// Quien mantiene al día los dos costados de la muesca.
///
/// Corre sólo si alguno de los dos tiene un dato elegido: con los dos en
/// «ninguno» no hay ninguna tarea viva, y el reposo sigue costando lo que
/// cuesta una ventana quieta (spec §3). Encendido, lee a tres ritmos:
///
/// - **CPU, RAM, GPU, red y disco cada tres segundos**, que es lo que tarda en
///   cambiar algo que valga la pena mirar. Llamadas de Mach, IOKit y `sysctl`,
///   microsegundos.
/// - **Los archivos de Claude Code y de Codex cada treinta.** La lectura es
///   incremental (`LectorDeClaude`) y la de Codex lee sólo la cola del último
///   archivo: medido el 2026-09-23 en la máquina de Alfonso, 3 ms y 12 ms.
/// - **El porcentaje del plan de Claude cada dos minutos**, como CodexBar, y
///   sólo si la persona lo encendió: es una consulta a Anthropic con su sesión.
@MainActor
final class DatosDeLaMuesca {
  /// Se llama con los dos costados cada vez que cambia algo que se ve.
  var alCambiar: ((LadoDeLaMuesca?, LadoDeLaMuesca?) -> Void)?
  /// Se llama cuando una IA cruza el 80 % o el 95 % de una ventana. Devuelve
  /// si el aviso se pudo mostrar: si la muesca estaba ocupada dictando, el
  /// aviso espera a la vuelta siguiente en vez de perderse.
  var alAvisar: ((AvisoDeLimite) -> Bool)?

  private let muestra = MuestraDelSistema()
  private let codex: LectorDeCodex
  private let claudeLocal: LectorDeClaude
  private let claudePlan: ClienteDeUsoDeClaude

  private var izquierdo = DatoDeLaMuesca.ninguno
  private var derecho = DatoDeLaMuesca.ninguno
  private var porcentajeDeClaude = false
  private var avisaLimites = true
  private var vigia = VigiaDeLimites()
  private var tarea: Task<Void, Never>?

  private var cpu: Double?
  private var ram: Double?
  private var gpu: Double?
  private var red: VelocidadDeRed?
  private var disco: EspacioEnDisco?
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
  func configurar(
    izquierdo: DatoDeLaMuesca,
    derecho: DatoDeLaMuesca,
    porcentajeDeClaude: Bool,
    avisaLimites: Bool = true
  ) {
    self.izquierdo = Self.disponible(izquierdo) ? izquierdo : .ninguno
    self.derecho = Self.disponible(derecho) ? derecho : .ninguno
    self.porcentajeDeClaude = porcentajeDeClaude
    self.avisaLimites = avisaLimites
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
        self.avisarSiToca()
        try? await Task.sleep(for: self.usaElSistema ? Self.cadenciaDelSistema : .seconds(Self.cadenciaDeLosArchivos))
      }
    }
  }

  /// Si alguno de los dos costados lleva un dato, ya filtrado por lo que este
  /// anfitrión puede leer.
  var llevaDatos: Bool { izquierdo != .ninguno || derecho != .ninguno }

  private var elegidos: Set<DatoDeLaMuesca> { [izquierdo, derecho] }
  private var usaElSistema: Bool { !elegidos.isDisjoint(with: [.cpu, .ram, .gpu, .red, .disco]) }

  private func refrescar() async {
    let ahora = Date()
    if elegidos.contains(.cpu) { cpu = muestra.cpu() ?? cpu }
    if elegidos.contains(.ram) { ram = muestra.ram() }
    if elegidos.contains(.gpu) { gpu = muestra.gpu() }
    if elegidos.contains(.red) { red = muestra.red(ahora: ahora) ?? red }
    if elegidos.contains(.disco) { disco = muestra.disco() }

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
    let ahora = Date()
    switch dato {
    case .ninguno:
      return nil
    case .cpu:
      return ladoDelSistema(.cpu, cpu)
    case .ram:
      return ladoDelSistema(.ram, ram)
    case .gpu:
      return ladoDelSistema(.gpu, gpu)
    case .disco:
      return LadoDeLaMuesca(
        dato: .disco,
        valor: disco.map { TextoDelDato.porcentaje($0.ocupado) } ?? "–",
        nivel: disco?.ocupado,
        detalle: DetalleDelDato.disco(disco)
      )
    case .red:
      // Lo que baja, que es lo que alguien mira cuando la red «anda lenta». Sin
      // nivel: una velocidad no tiene techo, y una barrita inventada mentiría.
      return LadoDeLaMuesca(
        dato: .red,
        valor: red.map { TextoDelDato.velocidad($0.baja) } ?? "–",
        nivel: nil,
        detalle: DetalleDelDato.red(red)
      )
    case .codex:
      return ladoDeIA(
        .codex,
        consumoDeCodex,
        detalle: DetalleDelDato.codex(consumoDeCodex, ahora: ahora),
        ahora: ahora
      )
    case .claude:
      let plan = planVigente(ahora: ahora)
      return ladoDeIA(
        .claude,
        plan ?? tokensDeClaude,
        detalle: DetalleDelDato.claude(tokens: tokensDeClaude, plan: plan, ahora: ahora),
        ahora: ahora
      )
    }
  }

  private func ladoDelSistema(_ dato: DatoDeLaMuesca, _ valor: Double?) -> LadoDeLaMuesca {
    LadoDeLaMuesca(
      dato: dato,
      valor: valor.map(TextoDelDato.porcentaje) ?? "–",
      nivel: valor,
      detalle: DetalleDelDato.sistema(valor)
    )
  }

  // MARK: Avisos

  /// Las ventanas con porcentaje de las IAs que se están mirando: la de cinco
  /// horas y la semanal de Codex, y la del plan de Claude si se pidió. Los
  /// tokens de Claude no avisan (`VigiaDeLimites`).
  private func ventanasVigiladas(ahora: Date) -> [(DatoDeLaMuesca, FilaDelDetalle.Cual, VentanaDeUso)] {
    var ventanas: [(DatoDeLaMuesca, FilaDelDetalle.Cual, VentanaDeUso)] = []
    if elegidos.contains(.codex), let codex = consumoDeCodex {
      ventanas.append((.codex, .cincoHoras, codex.ventanaCorta))
      if let semanal = codex.ventanaSemanal { ventanas.append((.codex, .semana, semanal)) }
    }
    if elegidos.contains(.claude), let plan = planVigente(ahora: ahora) {
      ventanas.append((.claude, .cincoHoras, plan.ventanaCorta))
      if let semanal = plan.ventanaSemanal { ventanas.append((.claude, .semana, semanal)) }
    }
    return ventanas
  }

  /// Da como mucho un aviso por vuelta —dos a la vez se pisarían en la misma
  /// muesca— y lo marca sólo si se mostró.
  private func avisarSiToca() {
    guard avisaLimites, let alAvisar else { return }
    let ahora = Date()
    for (dato, cual, ventana) in ventanasVigiladas(ahora: ahora) {
      guard let aviso = vigia.revisar(dato, cual, ventana, ahora: ahora) else { continue }
      if alAvisar(aviso) { vigia.marcar(aviso) }
      return
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
    _ dato: DatoDeLaMuesca,
    _ consumo: ConsumoDeIA?,
    detalle: [FilaDelDetalle],
    ahora: Date
  ) -> LadoDeLaMuesca {
    guard let ventana = consumo?.ventanaCorta.vigente(en: ahora) else {
      return LadoDeLaMuesca(dato: dato, valor: "–", nivel: nil)
    }
    return LadoDeLaMuesca(
      dato: dato,
      valor: TextoDelDato.valor(ventana) ?? "–",
      nivel: ventana.porcentaje,
      detalle: detalle
    )
  }
}

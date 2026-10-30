import DiloAgentes
import DiloModes
import Foundation
import os

/// Los trabajos que el agente de la llamada le encargó a Claude Code, corriendo
/// por detrás mientras la conversación sigue.
///
/// La persona habla siempre con una voz: el agente entiende qué pide y en qué
/// proyecto, lo encarga acá y sigue conversando. Cada proyecto tiene su sesión
/// (`DestinoClaudeCode`), que sigue abierta entre un encargo y otro. Lo que el
/// trabajo quiere hacer pide su clic igual que antes; lo que va contando se
/// anota en `ListaDeEncargos`, y al terminar el agente lo cuenta. Colgar
/// detiene todo: los permisos se aprueban en la barra de la llamada.
@MainActor
final class EncargosDeFondo: MandoDeEncargos {
  /// Cambió algo que muestra la barra.
  var alCambiar: ((String?) -> Void)?
  /// Terminó un encargo: lo que hay que contarle al agente.
  var alTerminar: ((String) -> Void)?
  /// Un encargo pide un clic. `aviso` es lo que hay que contarle al agente, si
  /// no se le ha contado.
  var alPedirClic: ((Aprobacion, _ aviso: String?) -> Void)?
  /// Lo entero que dijo un encargo, para la transcripción.
  var alTranscribir: ((Agente, String) -> Void)?

  private let settings: AppSettings
  private let agentes: () -> [Agente]
  private var lista = ListaDeEncargos()
  private var sesiones: [String: DestinoClaudeCode] = [:]
  private var tareas: [Int: Task<Void, Never>] = [:]

  init(settings: AppSettings, agentes: @escaping () -> [Agente]) {
    self.settings = settings
    self.agentes = agentes
  }

  var hayTrabajando: Bool { lista.hayTrabajando }

  var informe: String { lista.informe }

  func encargar(
    agente nombre: String,
    proyecto: ProyectoDeClaudeCode,
    tarea: String?,
    retomar: Bool
  ) -> ResultadoDeHerramienta {
    guard let agente = agentes().first(where: { $0.nombre == nombre && $0.trabajaDeFondo }) else {
      return ResultadoDeHerramienta("No hay un agente \(nombre).", esError: true)
    }
    let quePide = tarea ?? "retomar la última sesión"
    guard let id = lista.abrir(agente: agente.nombre, proyecto: proyecto.nombre, tarea: quePide) else {
      return ResultadoDeHerramienta(
        "\(agente.nombre) sigue trabajando en \(proyecto.nombre). Espera su aviso o usa detener_encargo.", esError: true
      )
    }
    let sesion = sesion(de: agente, en: proyecto)
    let flujo = sesion.encargar(tarea, en: proyecto, retomar: retomar)
    tareas[id] = Task { [weak self] in
      do {
        for try await evento in flujo {
          guard let self, !Task.isCancelled else { return }
          recibir(evento, de: agente, en: id)
        }
        self?.termino(id, falla: nil)
      } catch is CancellationError {
        // Lo detuvo la persona.
      } catch {
        guard !Task.isCancelled else { return }
        self?.termino(id, falla: error.localizedDescription)
      }
    }
    AppLog.conversacion.notice("encargo \(id): empieza con \(agente.id, privacy: .public)")
    publicar()
    return ResultadoDeHerramienta("Encargado a \(agente.nombre) en \(proyecto.nombre). Te avisan al terminar.")
  }

  func detener(proyecto: String) -> ResultadoDeHerramienta {
    guard let encargo = lista.enCurso(proyecto: proyecto) else {
      return ResultadoDeHerramienta("No hay nada corriendo en \(proyecto).")
    }
    lista.detener(encargo.id)
    tareas[encargo.id]?.cancel()
    tareas[encargo.id] = nil
    AppLog.conversacion.notice("encargo \(encargo.id): detenido")
    publicar()
    return ResultadoDeHerramienta("Detenido.")
  }

  /// La llamada se cortó: todo lo que corría se detiene y se olvida.
  func colgar() {
    tareas.values.forEach { $0.cancel() }
    tareas = [:]
    sesiones.values.forEach { $0.colgar() }
    sesiones = [:]
    lista.olvidar()
    publicar()
  }

  private func sesion(de agente: Agente, en proyecto: ProyectoDeClaudeCode) -> DestinoClaudeCode {
    if let sesion = sesiones[proyecto.carpeta] { return sesion }
    let sesion = DestinoClaudeCode(agente: agente, settings: settings)
    sesion.alTranscribir = { [weak self] texto in self?.alTranscribir?(agente, texto) }
    sesiones[proyecto.carpeta] = sesion
    return sesion
  }

  private func recibir(_ evento: EventoDelDestino, de agente: Agente, en id: Int) {
    switch evento {
    case let .texto(contado):
      lista.anotar(contado: contado, en: id)
    case let .herramienta(nombre, enCurso):
      lista.anotar(detalle: enCurso ? nombre : nil, en: id)
    case let .pideAprobacion(aprobacion):
      let avisar = lista.pideClic(en: id)
      let aviso = avisar ? lista.avisoDeClic(id, descripcion: aprobacion.descripcion) : nil
      var conClic = aprobacion
      conClic.responder = { [weak self] decision in
        aprobacion.responder(decision)
        Task { @MainActor [weak self] in
          self?.lista.sigue(en: id)
          self?.publicar()
        }
      }
      alPedirClic?(conClic, aviso)
    case .fin:
      break
    }
    publicar()
  }

  private func termino(_ id: Int, falla: String?) {
    tareas[id] = nil
    lista.terminar(id, falla: falla)
    AppLog.conversacion.notice("encargo \(id): terminó\(falla == nil ? "" : " con falla", privacy: .public)")
    publicar()
    if let aviso = lista.avisoAlTerminar(id) { alTerminar?(aviso) }
  }

  private func publicar() {
    alCambiar?(lista.lineaDeLaBarra)
  }
}

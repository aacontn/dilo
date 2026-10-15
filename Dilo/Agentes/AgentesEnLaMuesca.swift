import DiloPlataforma
import Foundation
import os

/// Los agentes de código en la muesca, por su *hook* y el URL scheme
/// (fase 5, plan cap. 5 §7; 2026-10-15).
///
/// La persona pega en su agente una línea que corre `dilo-agente.sh`; el
/// script abre `dilo://agente?de=claude&fase=espera&proyecto=…`, macOS se la
/// entrega a `AppDelegate.application(_:open:)` y llega acá. Dilo **no lee**
/// archivos de otras apps ni sus credenciales para esto: lo que sabe es lo
/// que el agente le dijo.
///
/// Quién existe lo decide `RegistroDeAgentes` (puro, `DiloPlataforma`);
/// dónde se sienta, `AsientosDeLaMuesca`; esto sólo une los dos, programa el
/// próximo vencimiento y atiende el clic, que quita el segmento.
@MainActor
final class AgentesEnLaMuesca {
  private let settings: AppSettings
  /// Sienta o retira un segmento. En la app, el escenario
  /// (`HUDStage.publicarDeAfuera`); en los tests, un registro.
  private let publicar: (ActividadDeLaMuesca, ContenidoDelSegmento) -> Void
  private let retirar: (String) -> Void
  /// La hora; un test pone la suya.
  var ahora: () -> Date = { Date() }

  private(set) var registro = RegistroDeAgentes()
  private var vencimiento: Task<Void, Never>?

  init(
    settings: AppSettings,
    publicar: @escaping (ActividadDeLaMuesca, ContenidoDelSegmento) -> Void,
    retirar: @escaping (String) -> Void
  ) {
    self.settings = settings
    self.publicar = publicar
    self.retirar = retirar
    observarElInterruptor()
  }

  /// Una URL que llegó a Dilo. Lo que no se entiende se anota con su motivo
  /// y no hace nada más: un *hook* mal pegado se encuentra con
  /// `log show --predicate 'subsystem == "cl.espaciodigital.dilo"'`,
  /// categoría `plataforma`.
  func abrir(_ url: URL) {
    switch EnlaceDeDilo.leer(url) {
    case let .success(.agente(evento)):
      guard settings.hudAgentes else {
        AppLog.plataforma.notice("Agente ignorado: los agentes están apagados en Ajustes")
        return
      }
      AppLog.plataforma.info(
        "Agente \(evento.agente.rawValue, privacy: .public) fase=\(evento.fase.rawValue, privacy: .public) proyecto=\(evento.proyecto, privacy: .private)"
      )
      recibir(evento)
    case let .failure(rechazo):
      AppLog.plataforma.notice("URL dilo:// rechazada: \(Self.motivo(rechazo), privacy: .public)")
    }
  }

  func recibir(_ evento: EventoDeAgente) {
    aplicar(registro.recibir(evento, ahora: ahora()))
  }

  /// Un clic en el segmento: la persona ya lo vio. Si el agente vuelve a
  /// avisar, vuelve.
  func tocar(id: String) {
    aplicar(registro.descartar(id: id))
  }

  /// «Probar» de Ajustes: lo mismo que haría el *hook*, sin pasar por
  /// LaunchServices —que con varias copias de Dilo instaladas puede
  /// entregarle la URL a otra—.
  func probar() {
    guard settings.hudAgentes else { return }
    recibir(EventoDeAgente(agente: .claude, fase: .espera, proyecto: String(localized: "prueba")))
  }

  /// Lo que venció a esta hora. Interna para los tests; en la app la llama
  /// el plazo que programa `reprogramar`.
  func limpiar() {
    aplicar(registro.limpiar(ahora: ahora()))
  }

  private func aplicar(_ cambios: [RegistroDeAgentes.Cambio]) {
    for cambio in cambios {
      switch cambio {
      case let .publicar(sesion):
        publicar(SegmentoDeAgente.actividad(sesion), SegmentoDeAgente.contenido(sesion))
      case let .retirar(id):
        retirar(id)
      }
    }
    reprogramar()
  }

  /// Duerme hasta el próximo vencimiento y no sondea: con agentes vivos y
  /// la muesca en reposo, Dilo no gasta CPU entre aviso y aviso.
  private func reprogramar() {
    vencimiento?.cancel()
    vencimiento = nil
    guard let proximo = registro.proximoVencimiento else { return }
    let espera = max(0, proximo.timeIntervalSince(ahora()))
    vencimiento = Task { [weak self] in
      try? await Task.sleep(for: .seconds(espera) + .milliseconds(50))
      guard !Task.isCancelled else { return }
      self?.limpiar()
    }
  }

  private func observarElInterruptor() {
    withObservationTracking {
      _ = settings.hudAgentes
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if !settings.hudAgentes { aplicar(registro.vaciar()) }
        observarElInterruptor()
      }
    }
  }

  static func motivo(_ rechazo: EnlaceDeDilo.Rechazo) -> String {
    switch rechazo {
    case .otroEsquema: "no es dilo://"
    case let .rutaDesconocida(ruta): "ruta desconocida «\(ruta.prefix(24))» (sólo existe «agente»)"
    case let .faseDesconocida(fase): "fase \(fase.map { "«\($0)»" } ?? "ausente") (trabajando, espera, listo, error o fin)"
    case .demasiadoLarga: "más de \(EnlaceDeDilo.largoMaximo) bytes"
    }
  }
}

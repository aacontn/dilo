import AppKit
import DiloAgentes
import EventKit

/// Lo que las herramientas del agente Dilo tocan en el Mac: el calendario de
/// hoy (EventKit), el portapapeles, Apple Notas y abrir apps y páginas.
///
/// Las reglas —qué se aprueba, qué URL se acepta, cuánto portapapeles va—
/// viven en `HerramientasDeLaConversacion` y se prueban con `swift test`; acá
/// sólo se hace. Lo de escritura llega acá **después** del clic.
struct MundoDelMac: MundoDeLaConversacion {
  func agendaDeHoy() async -> Result<[EventoDeLaAgenda], FallaDeHerramienta> {
    // Dilo no pide permisos desde una llamada: el diálogo de macOS en medio
    // de una conversación es una sorpresa. Se pide en Ajustes, al encender la
    // próxima reunión del panel.
    guard LectorDelCalendario.tienePermiso else {
      return .failure(FallaDeHerramienta(
        .noEncontrado, "Dilo no tiene permiso para leer el calendario.",
        arreglo: "Dile a la persona que lo dé en Dilo → Ajustes → Datos en la muesca, «Próxima reunión», o en Ajustes del Sistema → Privacidad → Calendarios."
      ))
    }
    return await Task.detached(priority: .userInitiated) {
      let almacen = EKEventStore()
      let calendario = Calendar.current
      let inicio = calendario.startOfDay(for: Date())
      let fin = calendario.date(byAdding: .day, value: 1, to: inicio) ?? inicio.addingTimeInterval(86_400)
      let eventos = almacen.events(matching: almacen.predicateForEvents(withStart: inicio, end: fin, calendars: nil))
      return .success(
        eventos.filter { $0.status != .canceled }.map { evento in
          let lugar = evento.location?.trimmingCharacters(in: .whitespacesAndNewlines)
          return EventoDeLaAgenda(
            titulo: evento.title ?? String(localized: "Evento"),
            empieza: evento.startDate,
            termina: evento.endDate,
            todoElDia: evento.isAllDay,
            lugar: lugar?.isEmpty == false ? lugar : nil,
            enlace: LectorDelCalendario.enlaceDeVideollamada(
              url: evento.url, textos: [evento.location, evento.notes].compactMap { $0 }
            )?.absoluteString
          )
        }
      )
    }.value
  }

  func portapapeles() async -> String? {
    await MainActor.run { VigiaDelPortapapeles.textoLegible(de: .general) }
  }

  func crearNota(_ texto: String) async -> ResultadoDeHerramienta {
    switch await NotasDeApple.guardar(texto) {
    case .guardada: ResultadoDeHerramienta("Nota creada en Apple Notas, carpeta «\(NotasDeApple.carpeta)».")
    case .sinPermiso:
      ResultadoDeHerramienta(
        "macOS no dejó a Dilo controlar Notas. La persona lo da en Ajustes del Sistema → Privacidad → Automatización.",
        esError: true
      )
    case .fallo: ResultadoDeHerramienta("No pude crear la nota en Apple Notas.", esError: true)
    }
  }

  func copiar(_ texto: String) async -> ResultadoDeHerramienta {
    await MainActor.run {
      let portapapeles = NSPasteboard.general
      portapapeles.clearContents()
      portapapeles.setString(texto, forType: .string)
    }
    return ResultadoDeHerramienta("Copiado al portapapeles.")
  }

  func abrirApp(_ nombre: String) async -> ResultadoDeHerramienta {
    let instaladas = await Task.detached(priority: .userInitiated) { Self.appsInstaladas() }.value
    guard let elegida = HerramientasDeLaConversacion.app(nombre, entre: instaladas.map(\.lastPathComponent)),
      let url = instaladas.first(where: { $0.lastPathComponent == elegida })
    else {
      return ResultadoDeHerramienta("No encontré una app que se llame \(nombre).", esError: true)
    }
    do {
      _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      return ResultadoDeHerramienta("Abrí \(url.deletingPathExtension().lastPathComponent).")
    } catch {
      return ResultadoDeHerramienta("No pude abrir \(elegida): \(error.localizedDescription)", esError: true)
    }
  }

  func abrirURL(_ url: URL) async -> ResultadoDeHerramienta {
    let abierta = await MainActor.run { NSWorkspace.shared.open(url) }
    return abierta
      ? ResultadoDeHerramienta("Abrí \(url.absoluteString) en el navegador.")
      : ResultadoDeHerramienta("No pude abrir \(url.absoluteString).", esError: true)
  }

  /// Las `.app` de las carpetas de aplicaciones, un nivel adentro (Utilidades
  /// incluida). Sin Spotlight: es una lista corta y no pide permisos.
  static func appsInstaladas() -> [URL] {
    let fm = FileManager.default
    let raices = [
      URL(filePath: "/Applications"), URL(filePath: "/System/Applications"),
      URL(filePath: "/System/Applications/Utilities"), URL(filePath: "/Applications/Utilities"),
      fm.homeDirectoryForCurrentUser.appending(path: "Applications"),
    ]
    return raices.flatMap { raiz in
      ((try? fm.contentsOfDirectory(at: raiz, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "app" }
    }
  }
}

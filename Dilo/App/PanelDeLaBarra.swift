import CoreGraphics
import Foundation

/// Qué abre un clic en el ícono de la barra de menús.
///
/// Alfonso, 2026-10-15: «con botón izquierdo que abra la app de Dilo, con
/// botón derecho alguna ventana como la de ahora pero que sea linda, así
/// como la de Switchboard». El izquierdo abre la ventana de la app —Ajustes,
/// que es la única que Dilo tiene— y el derecho, o ⌃clic como en todo el
/// Mac, el panel de la barra (`PanelDeLaBarra`).
///
/// **Un clic sin evento de mouse abre el panel.** Es lo que llega cuando
/// alguien aprieta el ícono por Accesibilidad —VoiceOver, un AppleScript—:
/// antes eso abría el menú con todas las acciones, y el panel es su
/// reemplazo; mandarlo a Ajustes le escondería todo lo demás.
///
/// Técnica observada en Switchboard (`StatusClick.opensPanel`, el botón con
/// `sendAction(on: [.leftMouseUp, .rightMouseUp])`); implementación propia.
enum ClicEnLaBarra: Equatable, Sendable {
  case abrirDilo
  case abrirPanel

  /// Lo que se sabe del clic, sin AppKit: así se prueba sin eventos.
  enum Boton: Equatable, Sendable {
    case izquierdo
    case derecho
    /// No llegó de un mouse (Accesibilidad) o no se reconoce.
    case otro
  }

  static func decidir(boton: Boton, conControl: Bool) -> ClicEnLaBarra {
    switch boton {
    case .izquierdo: conControl ? .abrirPanel : .abrirDilo
    case .derecho, .otro: .abrirPanel
    }
  }
}

/// El panel del clic derecho en el ícono de la barra, **en palabras y sin
/// dibujarlo**: así un test afirma que ofrece todo lo que ofrecía el menú gris
/// al que reemplaza (2026-10-15).
///
/// La jerarquía, de arriba abajo: quién es y en qué está (Dilo, listo /
/// dictando / transcribiendo, y el atajo), una toma que no salió si la hay,
/// lo último dictado con copiar —y lo dicho sin el modo, o lo que el modo
/// propuso, cuando son otra cosa—, las acciones, el modo del atajo general y,
/// al pie, los vínculos. La vista es `VistaDelPanelDeLaBarra`; la ventana y
/// cuándo se cierra, `ControlDelPanelDeLaBarra`.
///
/// Técnica observada en Switchboard (`BarPanelModel.content(_:)`: una foto de
/// los modelos vivos entra, el panel en palabras sale); implementación propia.
enum PanelDeLaBarra {
  /// Lo que se puede pedir desde el panel. Cada una era un ítem del menú,
  /// salvo elegir el modo, que viene del panel del hover.
  enum Accion: Hashable, Sendable {
    /// La ventana de la app: Ajustes.
    case abrirDilo
    /// Empezar o parar, según el estado: el mismo ítem del menú.
    case dictar
    case dictarNota
    /// Leer lo seleccionado, o dejar de leer.
    case leerSeleccion
    case transcribirArchivo
    case copiar(Copia)
    case reintentarToma
    case descartarToma
    /// Nil es el dictado normal, sin modo.
    case elegirModo(String?)
    case primerosPasos
    case novedades
    case buscarActualizaciones
    case salir

    /// Cuál de los textos del último dictado se copia: lo entregado, lo
    /// dicho sin el modo, o lo que el modo propuso y el validador rechazó.
    enum Copia: Hashable, Sendable {
      case entregado
      case original
      case propuesta
    }

    /// Qué hace el panel al elegirla.
    ///
    /// Casi todo lo cierra antes de hacer lo suyo, como un menú: dictar o
    /// leer con el panel encima es tapar justo lo que se dicta o se lee.
    /// Copiar se queda lo justo para mostrar el ✓ —es la única acción que no
    /// se ve en otra parte— y elegir el modo no cierra: el cambio se ve en el
    /// acto, que es el trato del interruptor de pausa de Switchboard.
    var cierre: Cierre {
      switch self {
      case .copiar: .trasElAcuse
      case .elegirModo: .seQueda
      default: .alTiro
      }
    }
  }

  enum Cierre: Equatable, Sendable {
    case alTiro
    case trasElAcuse
    case seQueda
  }

  /// Cuánto se ve el ✓ de copiado antes de que el panel se vaya.
  static let duracionDelAcuse: Duration = .milliseconds(650)

  /// En qué está Dilo, de lo más urgente a lo menos: el dictado le gana a la
  /// lectura y las dos a un archivo que se transcribe de fondo, que es el
  /// mismo orden en que el ícono los dice (`StatusItemController`).
  enum Actividad: Equatable, Sendable {
    case lista
    case dictando
    case leyendo
    case transcribiendo(Double)
  }

  /// Un modo como lo ofrece el panel.
  struct Modo: Equatable, Sendable {
    let id: String
    let nombre: String
  }

  /// Lo último dictado, en las tres versiones que el menú dejaba copiar.
  /// Valores sueltos y no `UltimoDictado`: el render del panel compila esto
  /// sin el paquete.
  struct Ultimo: Equatable, Sendable {
    var entregado: String
    var original: String
    /// Lo que el modo propuso y no se pegó; nil o vacío si no hubo.
    var propuesta: String?
    /// El modo que corrió, por nombre.
    var modo: String?
    var cuando: Date
  }

  /// Una foto de lo que el panel necesita, sacada de lo vivo cada vez que se
  /// abre o algo cambia.
  struct Entrada: Equatable, Sendable {
    var dictando = false
    var leyendo = false
    /// El avance de un archivo que se transcribe, 0…1, o nil.
    var progresoDeArchivo: Double?
    /// «fn», «⌃⌥Espacio»: la etiqueta del gatillo, tal como la dice Ajustes.
    var atajoDeDictar = ""
    var atajoDeLeer = ""
    var ultimo: Ultimo?
    /// El reloj de una toma que quedó en RAM («0:12»), o nil si no hay.
    var tomaGuardada: String?
    /// Lo que el anfitrión permite: lo que no, se esconde (`HostCapabilities`).
    var admiteNota = true
    var admiteLeer = true
    var modos: [Modo] = []
    var modoElegido: String?
    var ahora = Date()

    var actividad: Actividad {
      if dictando { return .dictando }
      if leyendo { return .leyendo }
      if let progresoDeArchivo { return .transcribiendo(progresoDeArchivo) }
      return .lista
    }
  }

  /// El panel en palabras.
  struct Contenido: Equatable, Sendable {
    /// El color del punto del encabezado. La vista lo traduce a la paleta.
    enum Tono: Equatable, Sendable {
      case reposo
      case activo
      case aviso
    }

    struct Encabezado: Equatable, Sendable {
      /// «Listo para dictar», «Dictando», «Transcribiendo · 40 %».
      let estado: String
      let tono: Tono
      /// El gatillo, o nil si no hay ninguno puesto.
      let atajo: String?
    }

    /// Un renglón que se aprieta.
    struct Fila: Equatable, Sendable, Identifiable {
      let titulo: String
      /// Un SF Symbol.
      let icono: String
      /// La tecla, a la derecha, en una píldora.
      var atajo: String?
      let accion: Accion
      let accesibilidad: String
      var id: Accion { accion }
    }

    struct Toma: Equatable, Sendable {
      let reloj: String
    }

    /// Lo último dictado y, debajo, las otras dos versiones si son otra cosa.
    struct UltimoDictado: Equatable, Sendable {
      /// Una línea de lo entregado.
      let titulo: String
      /// «Correo · hace 2 min».
      let detalle: String
      /// Lo dicho sin el modo y lo que el modo propuso, cada una con su
      /// etiqueta. Vacío casi siempre.
      let otras: [Otra]

      struct Otra: Equatable, Sendable {
        let etiqueta: String
        let vistazo: String
        let copia: Accion.Copia
      }
    }

    struct Chip: Equatable, Sendable {
      let nombre: String
      /// Nil es «Normal».
      let id: String?
      let elegido: Bool
    }

    let encabezado: Encabezado
    let toma: Toma?
    let ultimo: UltimoDictado?
    let acciones: [Fila]
    /// Vacío si no hay modos: con sólo «Normal» no hay nada que elegir.
    let modos: [Chip]
    let vinculos: [Fila]
    let salir: Fila

    /// Todo lo que el panel ofrece, para los tests: que nada del menú gris
    /// se pierda en el cambio.
    var todasLasAcciones: [Accion] {
      [.abrirDilo]
        + (toma == nil ? [] : [.reintentarToma, .descartarToma])
        + (ultimo.map { [.copiar(.entregado)] + $0.otras.map { .copiar($0.copia) } } ?? [])
        + acciones.map(\.accion)
        + modos.map { .elegirModo($0.id) }
        + vinculos.map(\.accion)
        + [salir.accion]
    }
  }

  static func contenido(_ entrada: Entrada) -> Contenido {
    Contenido(
      encabezado: encabezado(entrada),
      toma: entrada.tomaGuardada.map(Contenido.Toma.init(reloj:)),
      ultimo: ultimo(entrada),
      acciones: acciones(entrada),
      modos: modos(entrada),
      vinculos: [
        Contenido.Fila(
          titulo: String(localized: "Primeros pasos"),
          icono: "figure.wave",
          accion: .primerosPasos,
          accesibilidad: String(localized: "Abrir los Primeros pasos: permisos y un dictado de prueba")
        ),
        Contenido.Fila(
          titulo: String(localized: "Novedades"),
          icono: "sparkles",
          accion: .novedades,
          accesibilidad: String(localized: "Ver las novedades de esta versión")
        ),
        // «Actualizaciones» y no «Buscar actualizaciones»: el pie va en dos
        // columnas y la frase entera no cabe en la suya. La acción entera
        // va en la etiqueta de accesibilidad y en el tooltip.
        Contenido.Fila(
          titulo: String(localized: "Actualizaciones"),
          icono: "arrow.down.circle",
          accion: .buscarActualizaciones,
          accesibilidad: String(localized: "Buscar actualizaciones de Dilo")
        ),
      ],
      // Sin «⌘Q» al lado: el panel nunca toma el teclado (para no moverle el
      // foco a lo que se dicta), así que el atajo no correría desde ahí.
      salir: Contenido.Fila(
        titulo: String(localized: "Salir"),
        icono: "power",
        accion: .salir,
        accesibilidad: String(localized: "Salir de Dilo")
      )
    )
  }

  private static func encabezado(_ entrada: Entrada) -> Contenido.Encabezado {
    let atajo = entrada.atajoDeDictar.isEmpty ? nil : entrada.atajoDeDictar
    // Una toma guardada es lo único que pide algo de la persona: tiñe el
    // punto aunque Dilo esté listo para otro dictado.
    let reposo: Contenido.Tono = entrada.tomaGuardada == nil ? .reposo : .aviso
    switch entrada.actividad {
    case .lista:
      return .init(estado: String(localized: "Listo para dictar"), tono: reposo, atajo: atajo)
    case .dictando:
      return .init(estado: String(localized: "Dictando"), tono: .activo, atajo: atajo)
    case .leyendo:
      return .init(estado: String(localized: "Leyendo en voz alta"), tono: .activo, atajo: atajo)
    case let .transcribiendo(fraccion):
      let porcentaje = Int((min(max(fraccion, 0), 1) * 100).rounded())
      // Corto: la línea comparte el encabezado con «Abrir» y con la tecla.
      return .init(
        estado: String(localized: "Transcribiendo · \(porcentaje) %"),
        tono: .activo,
        atajo: atajo
      )
    }
  }

  /// Lo último, o nil si no hay nada que copiar. Las otras dos versiones
  /// sólo cuando son otra cosa: dos filas que copian el mismo texto es ruido
  /// (la regla de «Copiar lo que dijiste, sin el modo» del menú).
  private static func ultimo(_ entrada: Entrada) -> Contenido.UltimoDictado? {
    guard let ultimo = entrada.ultimo, !vistazo(ultimo.entregado).isEmpty else { return nil }
    var otras: [Contenido.UltimoDictado.Otra] = []
    if ultimo.original != ultimo.entregado, !vistazo(ultimo.original).isEmpty {
      otras.append(.init(
        etiqueta: String(localized: "Sin el modo"),
        vistazo: vistazo(ultimo.original),
        copia: .original
      ))
    }
    if let propuesta = ultimo.propuesta, !vistazo(propuesta).isEmpty {
      otras.append(.init(
        etiqueta: String(localized: "Lo que propuso"),
        vistazo: vistazo(propuesta),
        copia: .propuesta
      ))
    }
    let que = ultimo.modo ?? String(localized: "Dictado")
    return Contenido.UltimoDictado(
      titulo: vistazo(ultimo.entregado),
      detalle: "\(que) · \(TextoDelPanel.hace(ultimo.cuando, ahora: entrada.ahora))",
      otras: otras
    )
  }

  private static func acciones(_ entrada: Entrada) -> [Contenido.Fila] {
    var filas: [Contenido.Fila] = []
    let dictando = entrada.actividad == .dictando
    filas.append(Contenido.Fila(
      titulo: dictando ? String(localized: "Parar el dictado") : String(localized: "Empezar a dictar"),
      icono: dictando ? "stop.fill" : "waveform",
      accion: .dictar,
      accesibilidad: dictando ? String(localized: "Parar el dictado") : String(localized: "Empezar a dictar")
    ))
    // La nota, al lado de dictar: es un dictado que termina en Notas.
    if entrada.admiteNota {
      filas.append(Contenido.Fila(
        titulo: String(localized: "Dictar una nota"),
        icono: "square.and.pencil",
        accion: .dictarNota,
        accesibilidad: String(localized: "Dictar una nota que termina en Notas")
      ))
    }
    if entrada.admiteLeer {
      let leyendo = entrada.leyendo
      filas.append(Contenido.Fila(
        titulo: leyendo ? String(localized: "Dejar de leer") : String(localized: "Leer lo seleccionado"),
        icono: leyendo ? "speaker.slash" : "speaker.wave.2",
        atajo: entrada.atajoDeLeer.isEmpty ? nil : entrada.atajoDeLeer,
        accion: .leerSeleccion,
        accesibilidad: leyendo ? String(localized: "Dejar de leer") : String(localized: "Leer en voz alta lo seleccionado")
      ))
    }
    filas.append(Contenido.Fila(
      titulo: String(localized: "Transcribir un archivo…"),
      icono: "doc.text",
      accion: .transcribirArchivo,
      accesibilidad: String(localized: "Transcribir un archivo de audio o video")
    ))
    return filas
  }

  /// «Normal» y los modos, con el elegido marcado. Un modo borrado deja de
  /// estar elegido en vez de quedar apuntando a nada, como en el hover.
  private static func modos(_ entrada: Entrada) -> [Contenido.Chip] {
    guard !entrada.modos.isEmpty else { return [] }
    let elegido = entrada.modos.contains { $0.id == entrada.modoElegido } ? entrada.modoElegido : nil
    return [Contenido.Chip(nombre: String(localized: "Normal"), id: nil, elegido: elegido == nil)]
      + entrada.modos.map { Contenido.Chip(nombre: $0.nombre, id: $0.id, elegido: $0.id == elegido) }
  }

  /// Una línea, sin saltos ni espacios en los bordes. El recorte lo hace la
  /// vista, que sabe cuánto cabe.
  static func vistazo(_ texto: String) -> String {
    texto.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  /// Dónde va el panel: colgando del ícono, alineado a su derecha como los
  /// paneles del sistema, y dentro de la pantalla.
  ///
  /// `ancla` es el ícono —o la muesca, cuando el clic llega de ahí— en
  /// coordenadas de pantalla (origen abajo a la izquierda, como AppKit).
  /// Bajo la muesca va centrado: está al medio de la barra y no hay un
  /// borde al que alinearlo.
  static func marco(
    tamaño: CGSize,
    ancla: CGRect,
    pantalla: CGRect,
    centrado: Bool = false
  ) -> CGRect {
    let preferida = centrado
      ? ancla.midX - tamaño.width / 2
      : ancla.midX + aireDelIcono - tamaño.width
    let izquierda = pantalla.minX + margen
    let derecha = pantalla.maxX - margen - tamaño.width
    let x = max(izquierda, min(preferida, derecha))
    let arriba = min(ancla.minY, pantalla.maxY) - separacion
    return CGRect(x: x, y: arriba - tamaño.height, width: tamaño.width, height: tamaño.height)
  }

  /// Lo que el panel sobrepasa el centro del ícono hacia la derecha: el
  /// borde queda un poco más allá del ícono, como en Switchboard.
  static let aireDelIcono: CGFloat = 22
  /// Lo mínimo entre el panel y el borde de la pantalla.
  static let margen: CGFloat = 8
  /// El aire entre la barra y el panel: flota, no cuelga pegado.
  static let separacion: CGFloat = 6
}

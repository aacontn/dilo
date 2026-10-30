#if DEBUG
import Foundation
import os

/// Cada cosa que la muesca sabe dibujar, con un nombre que un agente puede
/// pedir. Sólo existe para mirar: ninguna escena abre el micrófono, pega,
/// copia, suena ni lee el calendario.
///
/// Existe porque la muesca se aprueba mirándola y casi ningún estado se puede
/// mirar a pedido: para ver la tarjeta de un dictado que no se pegó había que
/// hacer fallar un pegado, y para ver el aviso largo, esperar un error. Con
/// esto cada estado se pide por su nombre y se dibuja **en la ventana real y
/// en la pantalla real**, que es lo único que ni el PNG ni el canvas de Xcode
/// muestran.
///
/// Técnica observada en el arnés de otra isla de notch (un documento de
/// previsualización de su build de desarrollo: «show every HUD, eight seconds
/// each», nombres registrados, argumentos acotados, pedidos que vencen a los
/// diez segundos, botones apagados, sólo en DEBUG); la implementación es
/// propia y el pedido llega por una notificación distribuida.
///
/// Sólo en Debug, el archivo entero: en Release no existe, igual que el
/// gancho `DILO_METRICS_WAV`.
enum EscenaDeMuestra: String, CaseIterable, Sendable {
  case reposo
  case reposoConDatos = "reposo-datos"
  case cargandoModelo = "cargando-modelo"
  case faltaMicrofono = "falta-microfono"
  case dictando
  case dictandoLargo = "dictando-largo"
  /// Dictando desde «Traducir» del panel: el par de idiomas al principio de
  /// la línea y el ✓ para terminar, en los mismos 184×26.
  case dictandoTraduciendo = "dictando-traduciendo"
  case procesando
  case acuse
  case copiado
  case avisoLargo = "aviso-largo"
  /// La forma del aviso al estilo Droppy (`FormaAbierta`, 2026-10-14): un
  /// error corto con su ícono y el filo coral, y un arreglo con un clic con
  /// su botón. `aviso-largo` es el que no cabe.
  case aviso
  case avisoConArreglo = "aviso-arreglo"
  case retenido
  case hover
  case hoverCompleto = "hover-completo"
  /// El panel del hover al estilo Dynamic Glass (`PanelDeVidrio`), con el
  /// ajuste apagado o no: el vidrio no sale en PNG y sólo se juzga en la
  /// pantalla, sobre un fondo claro y uno oscuro.
  case hoverVidrio = "hover-vidrio"
  case hoverCompletoVidrio = "hover-completo-vidrio"
  /// El panel lleno con «Traducir» todavía sin idioma: el botón apagado que
  /// lleva a elegirlo.
  case hoverSinIdioma = "hover-sin-idioma"
  /// Los segmentos de los asientos (`AsientosDeLaMuesca`): la toma guardada
  /// a la derecha, el retenido a la izquierda, los dos, y los dos estirando
  /// la muesca dictando. Entran con la palabra y a los tres segundos se
  /// encogen al ícono, como en la app.
  case segmentoToma = "segmento-toma"
  case segmentoRetenido = "segmento-retenido"
  case dosSegmentos = "dos-segmentos"
  case dictandoConSegmentos = "dictando-segmentos"
  /// Los dos ya encogidos al ícono, y los dos con la palabra fija (lo que se
  /// ve con el puntero encima de uno).
  case segmentosEncogidos = "segmentos-encogidos"
  case segmentosConPalabra = "segmentos-palabra"
  /// Los datos de los costados encendidos y la toma a la derecha: el
  /// segmento ocupa el lugar del dato de su lado (`ReglaDeLosCostados`).
  /// `reposo-datos` es el antes.
  case segmentoConDatos = "segmento-datos"
  /// Un agente que avisa por su hook (`AgentesEnLaMuesca`): «Claude» con la
  /// mano levantada en el acento, al costado, como lo pone
  /// `dilo-agente.sh claude espera`.
  case agenteEsperando = "agente-esperando"
  /// Una reunión grabando sin dictado: `● 12:04` y las dos marcas con la
  /// forma (`HUDReunionEnLaMuesca`); la misma con el parlante en ámbar, que
  /// es la vigía a los 5 s de ceros; y dictando, la reunión al costado.
  case reunion
  case reunionSinLlamada = "reunion-sin-llamada"
  case dictandoConReunion = "dictando-reunion"

  /// El texto de muestra cuando el pedido no trae uno: largo a propósito en
  /// las escenas que tienen que probar el recorte por la izquierda.
  var textoDeMuestra: String? {
    switch self {
    case .dictando, .dictandoConSegmentos, .dictandoConReunion: "Aprieta, habla, suelta"
    case .dictandoTraduciendo: "nos vemos el martes en la oficina"
    case .dictandoLargo:
      "y entonces le dije que el informe de Kubernetes tenía que estar listo para el jueves a primera hora"
    case .procesando: "quedamos el martes a las diez"
    case .avisoLargo: "No pude pegarlo ahí: el texto quedó en el portapapeles y en «Copiar el último dictado»"
    case .aviso: "No pude pegarlo: quedó en el portapapeles"
    case .avisoConArreglo: "Falta el permiso del micrófono"
    case .retenido, .segmentoRetenido, .dosSegmentos, .segmentosEncogidos, .segmentosConPalabra:
      "quedamos el martes a las diez en la oficina de Providencia"
    case .hover, .hoverCompleto, .hoverVidrio, .hoverCompletoVidrio, .hoverSinIdioma:
      "Listo · «quedamos el martes a las diez»"
    default: nil
    }
  }

  /// En qué estado del contrato queda la muesca con esta escena. Es lo que
  /// un test recorre para afirmar que cada nombre dibuja lo que dice.
  var estado: EstadoDelNotch {
    switch self {
    case .reposo, .reposoConDatos, .hover, .hoverCompleto, .hoverVidrio, .hoverCompletoVidrio, .hoverSinIdioma:
      .reposo
    case .segmentoToma, .segmentoRetenido, .dosSegmentos, .segmentosEncogidos, .segmentosConPalabra,
      .segmentoConDatos, .agenteEsperando, .reunion, .reunionSinLlamada:
      .reposo
    case .cargandoModelo: .preparando(.cargandoModelo)
    case .faltaMicrofono: .preparando(.permisoDeMicrofono)
    case .dictando, .dictandoLargo, .dictandoConSegmentos, .dictandoTraduciendo, .dictandoConReunion: .dictando
    case .procesando: .procesando
    case .acuse: .resultado(.listo)
    case .copiado: .resultado(.copiado)
    case .avisoLargo, .aviso: .resultado(.aviso(textoDeMuestra ?? ""))
    case .avisoConArreglo: .resultado(.accionable(Self.arregloDeMuestra))
    case .retenido: .resultado(.retenido(Self.tarjetaDeMuestra))
    }
  }

  /// Qué segmentos pone la escena. Las demás no ponen ninguno, para que lo
  /// que se mira sea siempre lo mismo.
  var segmentos: (toma: Bool, retenido: Bool) {
    switch self {
    case .segmentoToma, .segmentoConDatos: (true, false)
    case .segmentoRetenido: (false, true)
    case .dosSegmentos, .dictandoConSegmentos, .segmentosEncogidos, .segmentosConPalabra: (true, true)
    default: (false, false)
    }
  }

  /// La reunión que pone la escena, o nil. Empezó hace doce minutos: el
  /// reloj corre desde ahí, como en la app.
  var reunionDeMuestra: ReunionEnLaMuesca? {
    let inicio = Date().addingTimeInterval(-(12 * 60 + 4))
    switch self {
    case .reunion, .dictandoConReunion:
      return ReunionEnLaMuesca(inicio: inicio, titulo: "Revisión semanal", microfono: .encendida, parlante: .encendida)
    case .reunionSinLlamada:
      return ReunionEnLaMuesca(inicio: inicio, titulo: "Revisión semanal", microfono: .encendida, parlante: .ambar)
    default:
      return nil
    }
  }

  /// Cómo queda la palabra de los segmentos de la escena.
  enum PalabraDeMuestra: Sendable {
    /// Entra y se encoge sola a los tres segundos.
    case entra
    case encogida
    case fija
  }

  var palabra: PalabraDeMuestra {
    switch self {
    case .segmentosEncogidos: .encogida
    case .segmentosConPalabra: .fija
    default: .entra
    }
  }

  /// Si la escena lleva los datos de los costados encendidos.
  var conDatos: Bool {
    self == .reposoConDatos || self == .hoverCompleto || self == .hoverCompletoVidrio || self == .segmentoConDatos
  }

  /// Si la escena abre el panel del hover.
  var abreElPanel: Bool {
    [.hover, .hoverCompleto, .hoverVidrio, .hoverCompletoVidrio, .hoverSinIdioma].contains(self)
  }
  /// Si el panel va lleno: recientes, datos, reunión y modos.
  var panelCompleto: Bool { [.hoverCompleto, .hoverCompletoVidrio, .hoverSinIdioma].contains(self) }
  /// Si el panel va con vidrio.
  var conVidrio: Bool { [.hoverVidrio, .hoverCompletoVidrio, .hoverSinIdioma].contains(self) }

  /// Un arreglo con un clic que no abre nada: en el arnés los botones están
  /// apagados, y el panel de Ajustes del Sistema es sólo el rótulo.
  static let arregloDeMuestra = AvisoConAccion(
    texto: EscenaDeMuestra.avisoConArreglo.textoDeMuestra ?? "",
    accion: .abrirAjustes("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
  )

  static let tarjetaDeMuestra = TarjetaDeRespaldo(
    texto: EscenaDeMuestra.retenido.textoDeMuestra ?? "",
    porque: .sinConfirmar
  )
}

/// Un pedido del arnés, ya validado. Llega como una línea de texto
/// (`mostrar dictando procesando --segundos 5`) para que el lado que pide sea
/// una línea de `osascript` y no un binario que compilar.
struct PedidoDeMuestras: Equatable, Sendable {
  enum Orden: Equatable, Sendable {
    case mostrar([EscenaDeMuestra], cada: Duration, mantener: Bool, texto: String?)
    case siguiente
    case cerrar
  }

  let orden: Orden
  let emitido: Date
  /// La paleta con que se dibujan las escenas (`--paleta glaciar`), o nil
  /// para la elegida. Sólo dura lo que dura la muestra.
  var paleta: PaletaDeDilo.Nombre?

  /// Un pedido que llega tarde no se obedece: una notificación distribuida
  /// puede quedar en cola mientras la app está suspendida, y una muesca que
  /// se pone a mostrar escenas sola un minuto después no la pidió nadie.
  static let vigencia: TimeInterval = 10
  static let segundos: ClosedRange<Int> = 1...30
  static let segundosDeFabrica = 8
  static let largoMaximoDelTexto = 200

  enum Rechazo: Error, Equatable {
    case vacio
    case ordenDesconocida(String)
    case escenaDesconocida(String)
    case segundosFueraDeRango
    case textoMuyLargo
    case vencido
    case paletaDesconocida(String)
  }

  /// `ahora` entra por parámetro para probar el vencimiento sin dormir.
  static func leer(_ linea: String, emitido: Date, ahora: Date) throws(Rechazo) -> PedidoDeMuestras {
    guard ahora.timeIntervalSince(emitido) <= vigencia else { throw .vencido }
    var palabras = linea.split(separator: " ").map(String.init)
    guard !palabras.isEmpty else { throw .vacio }
    let verbo = palabras.removeFirst()
    switch verbo {
    case "siguiente": return PedidoDeMuestras(orden: .siguiente, emitido: emitido)
    case "cerrar": return PedidoDeMuestras(orden: .cerrar, emitido: emitido)
    case "mostrar": break
    default: throw .ordenDesconocida(verbo)
    }

    var escenas: [EscenaDeMuestra] = []
    var cada = segundosDeFabrica
    var mantener = false
    var texto: String?
    var paleta: PaletaDeDilo.Nombre?
    var i = 0
    while i < palabras.count {
      let palabra = palabras[i]
      switch palabra {
      case "--segundos":
        guard i + 1 < palabras.count, let n = Int(palabras[i + 1]), segundos.contains(n) else {
          throw .segundosFueraDeRango
        }
        cada = n
        i += 1
      case "--mantener":
        mantener = true
      case "--paleta":
        guard i + 1 < palabras.count else { throw .paletaDesconocida("") }
        guard let nombre = PaletaDeDilo.Nombre(rawValue: palabras[i + 1]) else {
          throw .paletaDesconocida(palabras[i + 1])
        }
        paleta = nombre
        i += 1
      case "--texto":
        // El resto de la línea es el texto: así un texto con espacios no
        // necesita comillas que sobrevivan a tres capas de shell.
        let resto = palabras[(i + 1)...].joined(separator: " ")
        guard resto.count <= largoMaximoDelTexto else { throw .textoMuyLargo }
        texto = resto.isEmpty ? nil : resto
        i = palabras.count
      case "todas":
        escenas.append(contentsOf: EscenaDeMuestra.allCases)
      default:
        guard let escena = EscenaDeMuestra(rawValue: palabra) else { throw .escenaDesconocida(palabra) }
        escenas.append(escena)
      }
      i += 1
    }
    guard !escenas.isEmpty else { throw .vacio }
    return PedidoDeMuestras(
      orden: .mostrar(escenas, cada: .seconds(cada), mantener: mantener, texto: texto),
      emitido: emitido,
      paleta: paleta
    )
  }
}

/// Qué escena va ahora. Reductor puro con turno, como `MaquinaDelNotch`: un
/// plazo viejo no avanza un guion nuevo.
struct GuionDeMuestras: Equatable, Sendable {
  private(set) var cola: [EscenaDeMuestra] = []
  private(set) var actual: EscenaDeMuestra?
  private(set) var turno = 0
  private var cada: Duration = .seconds(PedidoDeMuestras.segundosDeFabrica)
  private var mantener = false

  enum Efecto: Equatable, Sendable {
    case dibujar(EscenaDeMuestra)
    case programarSiguiente(Duration, turno: Int)
    /// Volver al estado real del escenario.
    case soltar
  }

  mutating func recibir(_ orden: PedidoDeMuestras.Orden) -> [Efecto] {
    switch orden {
    case let .mostrar(escenas, cada, mantener, _):
      cola = escenas
      self.cada = cada
      self.mantener = mantener
      return avanzar()
    case .siguiente:
      return avanzar()
    case .cerrar:
      return olvidar()
    }
  }

  mutating func vencio(turno vencido: Int) -> [Efecto] {
    guard vencido == turno, !mantener else { return [] }
    return avanzar()
  }

  /// Deja el guion sin nada, como `cerrar`. Lo usa el escenario cuando un
  /// dictado de verdad le gana a la muestra.
  mutating func olvidar() -> [Efecto] {
    let habia = actual != nil
    cola = []
    actual = nil
    turno += 1
    return habia ? [.soltar] : []
  }

  private mutating func avanzar() -> [Efecto] {
    turno += 1
    guard !cola.isEmpty else {
      let habia = actual != nil
      actual = nil
      return habia ? [.soltar] : []
    }
    let escena = cola.removeFirst()
    actual = escena
    return mantener ? [.dibujar(escena)] : [.dibujar(escena), .programarSiguiente(cada, turno: turno)]
  }
}

/// Escucha los pedidos del arnés.
///
/// El nombre de la notificación lleva el bundle id de esta copia
/// (`cl.espaciodigital.dilo.debug.muesca`, `….prueba.debug.muesca`): con dos
/// builds de Debug abiertos —la de prueba de Alfonso y la de un agente— un
/// pedido sin destinatario los movería a los dos. Del lado que pide basta una
/// línea, que es lo que envuelve `scripts/muesca.sh`:
///
///     osascript -l JavaScript -e 'function run(a) { ObjC.import("Foundation");
///       $.NSDistributedNotificationCenter.defaultCenter
///       .postNotificationNameObjectUserInfoDeliverImmediately(
///       a[0], a[1], null, true) }' cl.espaciodigital.dilo.debug.muesca "mostrar todas --segundos 4"
@MainActor
final class ReceptorDeMuestras {
  nonisolated static func nombre(paraElBundle id: String?) -> Notification.Name {
    Notification.Name("\(id ?? "cl.espaciodigital.dilo").debug.muesca")
  }

  private static let log = Logger(subsystem: "cl.espaciodigital.dilo", category: "muesca")

  private var guion = GuionDeMuestras()
  private var plazo: Task<Void, Never>?
  private var observador: (any NSObjectProtocol)?
  private var textoPedido: String?
  private var paletaPedida: PaletaDeDilo.Nombre?

  /// Lo que `HUDStage` hace con cada efecto: dibujar la escena con contenido
  /// de muestra y botones apagados, o devolver la forma a su estado real.
  var alDibujar: ((EscenaDeMuestra, String?) -> Void)?
  var alSoltar: (() -> Void)?

  func escuchar(bundle: String? = Bundle.main.bundleIdentifier) {
    let nombre = Self.nombre(paraElBundle: bundle)
    observador = DistributedNotificationCenter.default().addObserver(
      forName: nombre, object: nil, queue: .main
    ) { [weak self] aviso in
      let linea = aviso.object as? String ?? ""
      MainActor.assumeIsolated { self?.recibir(linea) }
    }
    Self.log.notice("Arnés de la muesca escuchando en \(nombre.rawValue, privacy: .public)")
  }

  /// Una línea del arnés. Interna para que un test la mande sin pasar por la
  /// notificación distribuida, que no se puede esperar desde la suite.
  func recibir(_ linea: String, ahora: Date = Date()) {
    let pedido: PedidoDeMuestras
    do {
      pedido = try PedidoDeMuestras.leer(linea, emitido: ahora, ahora: ahora)
    } catch {
      Self.log.notice("Arnés: pedido rechazado (\(String(describing: error), privacy: .public)): \(linea, privacy: .public)")
      return
    }
    if case let .mostrar(_, _, _, texto) = pedido.orden {
      textoPedido = texto
      paletaPedida = pedido.paleta
    }
    aplicar(guion.recibir(pedido.orden))
  }

  /// Un dictado de verdad empezó encima de la muestra: el guion se olvida
  /// sin volver a soltar la forma, que ya es de la sesión real.
  func olvidar() {
    plazo?.cancel()
    _ = guion.olvidar()
    // Un dictado de verdad se dibuja con la paleta elegida, no con la de la
    // muestra que interrumpió.
    paletaPedida = nil
    PaletaActiva.compartida.mostrarDeMuestra(nil)
  }

  private func aplicar(_ efectos: [GuionDeMuestras.Efecto]) {
    for efecto in efectos {
      switch efecto {
      case let .dibujar(escena):
        Self.log.notice("Arnés: \(escena.rawValue, privacy: .public)")
        PaletaActiva.compartida.mostrarDeMuestra(paletaPedida)
        alDibujar?(escena, textoPedido ?? escena.textoDeMuestra)
      case .soltar:
        plazo?.cancel()
        textoPedido = nil
        paletaPedida = nil
        PaletaActiva.compartida.mostrarDeMuestra(nil)
        alSoltar?()
      case let .programarSiguiente(duracion, turno):
        plazo?.cancel()
        plazo = Task { [weak self] in
          try? await Task.sleep(for: duracion)
          guard !Task.isCancelled, let self else { return }
          self.aplicar(self.guion.vencio(turno: turno))
        }
      }
    }
  }
}
#endif

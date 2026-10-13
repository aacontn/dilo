import CoreGraphics
import Foundation

/// ¿El puntero vino a mirar la muesca o va de paso hacia un menú?
///
/// Antes el escenario esperaba un retardo fijo (medio segundo de fábrica,
/// `hudRetardoDeHover`) y abría el panel; al salir, esperaba el mismo retardo
/// y cerraba. Eso abría igual a quien cruzaba la barra camino a un menú si
/// se demoraba lo justo, y hacía esperar medio segundo a quien llegó, se
/// paró encima y ya estaba mirando. Esto decide con un poco más:
///
/// - **Se frenó encima**: abre antes del retardo. Un puntero quieto no manda
///   eventos, así que «se frenó» es también «no llegó ninguna muestra en
///   `permanencia`».
/// - **Va de paso hacia arriba**, rápido hacia la barra: esa muestra no abre
///   ni cuenta como frenado. Si de todos modos se queda, abre con el retardo
///   entero.
/// - **Al salir**, una gracia corta en vez del retardo entero: bajar del panel
///   a la barra de al lado y volver no lo cierra y lo reabre, y irse de verdad
///   lo cierra antes.
///
/// **Quién avisa no cambia**: sigue siendo el `NSTrackingArea` de
/// `HUDHostingView`, que es lo único que funcionó (tres intentos fallaron
/// antes, `AGENTS.md`). Esto sólo decide *cuándo*: recibe muestras con su
/// instante, no duerme ni lee el mouse, y devuelve cuándo volver a
/// preguntarle. `HUDStage` programa esos plazos con su reloj, como
/// `ControlDelNotch` con los de la máquina.
///
/// La idea de intención, permanencia y gracia es la de otras islas de notch;
/// los números son de partida, sin medir con Alfonso todavía.
struct IntencionDelPuntero: Equatable, Sendable {
  struct Ajustes: Equatable, Sendable {
    /// El retardo de Ajustes (`hudRetardoDeHover`). Cero es «al instante».
    var retardo: Duration = .milliseconds(500)
    /// Frenado: menos de esta rapidez, sostenida `permanencia`, abre ya.
    var velocidadDeFrenado: Double = 120  // puntos por segundo
    var permanencia: Duration = .milliseconds(160)
    /// De paso: subir más rápido que esto no abre en esa muestra.
    var velocidadDePaso: Double = 900
    /// Lo que espera al salir antes de cerrar.
    var gracia: Duration = .milliseconds(250)

    /// La permanencia que de verdad se pide, con el retardo de Ajustes
    /// mandando: quien subió el retardo a 1,2 s porque el panel se le abría
    /// sin querer tampoco quiere que se le abra a los 160 ms por dejar el
    /// mouse quieto. Crece en proporción desde el medio segundo de fábrica,
    /// y nunca es más que el retardo.
    var permanenciaEfectiva: Duration {
      let proporcion = IntencionDelPuntero.segundos(retardo) / IntencionDelPuntero.segundos(Self.retardoDeReferencia)
      return proporcion >= 1 ? permanencia * proporcion : min(permanencia, retardo)
    }

    static let retardoDeReferencia = Duration.milliseconds(500)
  }

  enum Decision: Equatable, Sendable {
    case nada
    case abrir
    case cerrar
    /// Volver a preguntar (`revisar(t:)`) dentro de este plazo.
    case revisarEn(Duration)
  }

  var ajustes = Ajustes()
  private(set) var abierto = false
  private var entro: Duration?
  private var salio: Duration?
  private var frenadoDesde: Duration?
  private var ultima: Muestra?
  /// Si la última muestra iba de paso hacia la barra: entonces quedarse
  /// quieto no cuenta como frenado, porque el borde de la pantalla frena a
  /// cualquiera que sube.
  private var ultimaDePaso = false

  private struct Muestra: Equatable, Sendable {
    let punto: CGPoint
    let t: Duration
    let dentro: Bool
  }

  /// Una muestra del puntero. `t` es tiempo monótono (`DeadlineClock.now`);
  /// `dentro`, si cae en la silueta —o en el panel, si está abierto—.
  /// `punto` en coordenadas de pantalla, con la y creciendo hacia arriba.
  mutating func muestra(_ punto: CGPoint, dentro: Bool, t: Duration) -> Decision {
    let velocidad = velocidad(hasta: punto, t: t)
    ultima = Muestra(punto: punto, t: t, dentro: dentro)
    ultimaDePaso = (velocidad?.dy ?? 0) > ajustes.velocidadDePaso

    guard dentro else {
      entro = nil
      frenadoDesde = nil
      guard abierto else { return .nada }
      if salio == nil { salio = t }
      return .revisarEn(ajustes.gracia - (t - (salio ?? t)))
    }

    salio = nil
    if abierto { return .nada }
    if entro == nil { entro = t }
    if ajustes.retardo == .zero { return abrir() }

    if ultimaDePaso {
      // De paso hacia la barra: esta muestra no cuenta como frenado.
      frenadoDesde = nil
    } else if let velocidad, velocidad.rapidez < ajustes.velocidadDeFrenado {
      if frenadoDesde == nil { frenadoDesde = t }
    } else if velocidad != nil {
      frenadoDesde = nil
    }
    return decidirDentro(t: t)
  }

  /// Cuando vence un `revisarEn`, sin muestra nueva: el puntero quieto no
  /// manda eventos, y quieto encima es justamente frenado.
  mutating func revisar(t: Duration) -> Decision {
    if abierto {
      guard let salio else { return .nada }
      guard t - salio >= ajustes.gracia else { return .revisarEn(ajustes.gracia - (t - salio)) }
      return cerrar()
    }
    guard entro != nil else { return .nada }
    return decidirDentro(t: t)
  }

  /// El panel se cerró o dejó de poder abrirse por otro camino: un cambio de
  /// estado, la red de seguridad. Se olvida todo, incluida la última muestra.
  mutating func reiniciar() {
    self = IntencionDelPuntero(ajustes: ajustes)
  }

  private mutating func decidirDentro(t: Duration) -> Decision {
    guard let entro else { return .nada }
    if t - entro >= ajustes.retardo { return abrir() }
    if let frenadoDesde, t - frenadoDesde >= ajustes.permanenciaEfectiva { return abrir() }
    // Quieto: la última muestra fue dentro, no iba de paso, y desde
    // entonces no llegó otra.
    let quietoDesde = ultima.flatMap { $0.dentro && !ultimaDePaso ? $0.t : nil }
    if let quietoDesde, t - quietoDesde >= ajustes.permanenciaEfectiva { return abrir() }
    let alRetardo = ajustes.retardo - (t - entro)
    let alFrenar: Duration = {
      if let frenadoDesde { return ajustes.permanenciaEfectiva - (t - frenadoDesde) }
      if let quietoDesde { return ajustes.permanenciaEfectiva - (t - quietoDesde) }
      return alRetardo
    }()
    return .revisarEn(max(.milliseconds(1), min(alRetardo, alFrenar)))
  }

  private mutating func abrir() -> Decision {
    abierto = true
    frenadoDesde = nil
    salio = nil
    return .abrir
  }

  private mutating func cerrar() -> Decision {
    abierto = false
    salio = nil
    entro = nil
    frenadoDesde = nil
    return .cerrar
  }

  private func velocidad(hasta punto: CGPoint, t: Duration) -> (rapidez: Double, dy: Double)? {
    guard let ultima else { return nil }
    let dt = Self.segundos(t - ultima.t)
    guard dt > 0 else { return nil }
    let dx = Double(punto.x - ultima.punto.x) / dt
    let dy = Double(punto.y - ultima.punto.y) / dt
    return ((dx * dx + dy * dy).squareRoot(), dy)
  }

  static func segundos(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
  }
}

import AppKit
import Observation
import SwiftUI
import Synchronization

/// Un color en sRGB, guardado como números.
///
/// Números y no `Color`: la misma paleta tiene que servirle a SwiftUI, a los
/// `NSImage` del status item y al render de la muesca en PNG, y los números
/// se comparan en un test sin dibujar nada.
struct Tono: Equatable, Sendable {
  var rojo: Double
  var verde: Double
  var azul: Double
  var alfa: Double = 1

  init(rojo: Double, verde: Double, azul: Double, alfa: Double = 1) {
    self.rojo = rojo
    self.verde = verde
    self.azul = azul
    self.alfa = alfa
  }

  /// `0xFF9E1B`, como se escribe en el SVG y en la landing.
  init(hex: UInt32, alfa: Double = 1) {
    self.init(
      rojo: Double((hex >> 16) & 0xFF) / 255,
      verde: Double((hex >> 8) & 0xFF) / 255,
      azul: Double(hex & 0xFF) / 255,
      alfa: alfa
    )
  }

  static let blanco = Tono(rojo: 1, verde: 1, azul: 1)

  func opacidad(_ alfa: Double) -> Tono {
    Tono(rojo: rojo, verde: verde, azul: azul, alfa: alfa)
  }

  var color: Color { Color(.sRGB, red: rojo, green: verde, blue: azul, opacity: alfa) }
  var nsColor: NSColor { NSColor(srgbRed: rojo, green: verde, blue: azul, alpha: alfa) }
}

/// Los colores de Dilo con el nombre de **lo que hacen**, no de qué color son.
///
/// Existe para que cambiar el acento sea cambiar una línea. Antes cada vista
/// pedía `DiloBrand.mango` o `DiloBrand.menta` por su nombre, y un acento
/// nuevo era recorrer cuarenta archivos sabiendo cuál mango era el cursor y
/// cuál era un botón. Ahora la muesca y Ajustes piden `PaletaDeDilo.actual` y
/// el token de lo que dibujan (`cursor`, `acuse`, `acentoDeAjustes`…); qué
/// color es cada uno se decide acá, en una sola tabla.
///
/// **De fábrica es `mango`, que es lo de siempre, número por número.** Las
/// otras tres son la exploración del 2026-10-14 («el color naranja ya no me
/// gusta», con el makeover al estilo Droppy) y se eligen con un ajuste oculto
/// (`defaults write cl.espaciodigital.dilo diloPaleta glaciar`), con el
/// selector de Debug en Apariencia o con `--paleta` en el arnés de la muesca.
///
/// Fuera de la paleta, a propósito: las paletas del Edge Glow (las elige la
/// persona y nunca recolorean el caparazón), el arcoíris del estilo Siri y
/// el ícono de la app, que es un activo (`brand/`).
struct PaletaDeDilo: Equatable, Sendable, Identifiable {
  /// Cuál es. El `rawValue` se guarda en `UserDefaults`: no se renombra.
  enum Nombre: String, CaseIterable, Sendable, Identifiable {
    case mango
    case grafito
    case glaciar
    case menta

    var id: String { rawValue }

    /// Nombre propio de cada paleta: no se traduce.
    var titulo: String {
      switch self {
      case .mango: "Mango"
      case .grafito: "Grafito"
      case .glaciar: "Glaciar"
      case .menta: "Menta"
      }
    }

    var paleta: PaletaDeDilo {
      switch self {
      case .mango: .mango
      case .grafito: .grafito
      case .glaciar: .glaciar
      case .menta: .menta
      }
    }
  }

  /// Los colores de categoría de Ajustes: cada atajo y cada serie de
  /// Actividad tiene el suyo para distinguirse de los otros, no para decir
  /// la marca. Van acá porque uno de los de fábrica es naranja.
  struct Categorias: Equatable, Sendable {
    var sesiones: Tono
    var tiempo: Tono
    var segundoIdioma: Tono
    var traducir: Tono
    var leerEnVoz: Tono
  }

  let nombre: Nombre
  var id: Nombre { nombre }

  /// Lo que se puede tocar o hay que mirar dentro de la muesca: el modo
  /// elegido, «Nota», «Unirse», la reunión que empieza, la etiqueta de nota
  /// o de idioma, el ✓ de terminar un dictado trabado.
  var acento: Tono
  /// La onda de brasas: de `ondaBase` abajo a `ondaPunta` arriba, con
  /// `halo` alrededor (`HUDOndaDeBrasas`).
  var ondaBase: Tono
  var ondaPunta: Tono
  var halo: Tono
  /// El cuerpo de los otros estilos de onda; sus puntas son `ondaBase`.
  var ondaCuerpo: Tono
  /// El punto de tres puntos de la muesca en reposo (`HUDMarcaDeReposo`).
  var puntoDeReposo: Tono
  /// El cursor que parpadea mientras el micrófono está abierto.
  var cursor: Tono
  /// El check del dictado que aterrizó, y el ✓ de copiado del panel. Tiene
  /// que ser distinto de la onda que reemplaza (`HUDCheckDeAcuse`).
  var acuse: Tono
  /// El texto de un aviso o un error en la muesca.
  var error: Tono
  /// El ícono y la palabra de un segmento que se puede tocar ya
  /// («Reintentar»).
  var segmento: Tono
  /// Un dato de los costados que se acerca al límite (75 %).
  var aviso: Tono
  /// Un dato de los costados en el límite (90 %).
  var alerta: Tono
  /// El micrófono muerto: quieto y de otro color que el silencio
  /// (CONTEXT.md, «el silencio y un micrófono muerto tienen que verse
  /// distinto»).
  var microfonoMuerto: Tono

  /// El acento de la ventana de Ajustes y de los Primeros pasos:
  /// interruptores, selección, la sección elegida.
  var acentoDeAjustes: Tono
  /// Lo que salió bien en Ajustes: «LOCAL», «Listo», copiado.
  var exito: Tono
  var fondoDeAjustes: Tono
  var barraLateral: Tono
  var tarjetaDeAjustes: Tono
  var categorias: Categorias

  /// El color con que se llena el ícono de la barra de menús mientras
  /// transcribe un archivo, y el de las superficies de arrastrar un archivo.
  /// En reposo el ícono es plantilla y no lleva color.
  var acentoDeLaBarra: Tono
}

extension PaletaDeDilo {
  /// La de siempre: tinta, mango y menta, con los números exactos que cada
  /// vista tenía escritos antes de esta capa. Un test la compara con
  /// `DiloBrand`.
  static let mango = PaletaDeDilo(
    nombre: .mango,
    acento: Tono(hex: 0xFF9E1B),
    ondaBase: Tono(hex: 0xFF9E1B),
    ondaPunta: Tono(hex: 0xFF5C5C),
    halo: Tono(hex: 0xFF5C5C, alfa: 0.5),
    ondaCuerpo: Tono(hex: 0x2EE6A8),
    puntoDeReposo: Tono(hex: 0xFF9E1B, alfa: 0.9),
    cursor: Tono(hex: 0xFF9E1B),
    acuse: Tono(hex: 0x2EE6A8),
    error: Tono.blanco.opacidad(0.9),
    segmento: Tono(hex: 0xFF9E1B),
    aviso: Tono(hex: 0xFF9E1B),
    alerta: Tono(rojo: 1, verde: 0.38, azul: 0.32),
    microfonoMuerto: Tono(rojo: 1, verde: 0.6, azul: 0.16),
    acentoDeAjustes: Tono(hex: 0xFF9E1B),
    exito: Tono(hex: 0x2EE6A8),
    fondoDeAjustes: Tono(rojo: 0.025, verde: 0.027, azul: 0.035),
    barraLateral: Tono(rojo: 0.035, verde: 0.038, azul: 0.049),
    tarjetaDeAjustes: Tono(rojo: 0.065, verde: 0.069, azul: 0.087),
    categorias: Categorias(
      sesiones: Tono(rojo: 0.20, verde: 0.82, azul: 0.58),
      tiempo: Tono(rojo: 0.62, verde: 0.50, azul: 0.98),
      segundoIdioma: Tono(rojo: 0.45, verde: 0.82, azul: 0.6),
      traducir: Tono(rojo: 0.66, verde: 0.55, azul: 0.95),
      leerEnVoz: Tono(rojo: 0.95, verde: 0.7, azul: 0.35)
    ),
    acentoDeLaBarra: Tono(hex: 0xFF9E1B)
  )

  /// Blanco y grafito, como Droppy y como el sistema: la muesca es negra y
  /// todo lo que dice es blanco en distintas intensidades. El único color que
  /// queda es semántico —verde lo que salió bien, coral lo que no—, así que
  /// cuando aparece se lee. La onda va de gris a blanco y el halo es una luz,
  /// no una brasa.
  static let grafito = PaletaDeDilo(
    nombre: .grafito,
    acento: .blanco,
    ondaBase: Tono(hex: 0x8E8E93),
    ondaPunta: .blanco,
    halo: Tono.blanco.opacidad(0.35),
    ondaCuerpo: Tono(hex: 0xD1D1D6),
    puntoDeReposo: Tono.blanco.opacidad(0.7),
    cursor: .blanco,
    acuse: Tono(hex: 0x30D158),
    error: Tono(hex: 0xFF6B6B),
    segmento: .blanco,
    aviso: Tono(hex: 0xFFD60A),
    alerta: Tono(hex: 0xFF6B6B),
    microfonoMuerto: Tono(hex: 0xFFD60A),
    acentoDeAjustes: Tono(hex: 0xAEAEB2),
    exito: Tono(hex: 0x30D158),
    fondoDeAjustes: Tono(hex: 0x0A0A0B),
    barraLateral: Tono(hex: 0x111112),
    tarjetaDeAjustes: Tono(hex: 0x1C1C1E),
    categorias: Categorias(
      sesiones: Tono(hex: 0xD1D1D6),
      tiempo: Tono(hex: 0x8E8E93),
      segundoIdioma: Tono(hex: 0xC7C7CC),
      traducir: Tono(hex: 0xAEAEB2),
      leerEnVoz: Tono(hex: 0x98989D)
    ),
    acentoDeLaBarra: Tono(hex: 0x8E8E93)
  )

  /// Fría: celeste sobre negro, del azul de Apple al cian. Es la familia de
  /// color de Droppy —su ícono va de lavanda a azul eléctrico— pero más
  /// clara, porque su azul `#1219ED` sobre negro casi no se ve. El acuse es
  /// una menta pálida, del mismo frío pero otra cosa que la onda.
  static let glaciar = PaletaDeDilo(
    nombre: .glaciar,
    acento: Tono(hex: 0x64D2FF),
    ondaBase: Tono(hex: 0x0A84FF),
    ondaPunta: Tono(hex: 0x64D2FF),
    halo: Tono(hex: 0x64D2FF, alfa: 0.45),
    ondaCuerpo: Tono(hex: 0x64D2FF),
    puntoDeReposo: Tono(hex: 0x64D2FF, alfa: 0.9),
    cursor: Tono(hex: 0x64D2FF),
    acuse: Tono(hex: 0x7DF9C4),
    error: Tono(hex: 0xFF6B6B),
    segmento: Tono(hex: 0x64D2FF),
    aviso: Tono(hex: 0xFFD60A),
    alerta: Tono(hex: 0xFF6B6B),
    microfonoMuerto: Tono(hex: 0xFFD60A),
    acentoDeAjustes: Tono(hex: 0x0A84FF),
    exito: Tono(hex: 0x7DF9C4),
    fondoDeAjustes: Tono(rojo: 0.025, verde: 0.027, azul: 0.035),
    barraLateral: Tono(rojo: 0.035, verde: 0.038, azul: 0.049),
    tarjetaDeAjustes: Tono(rojo: 0.065, verde: 0.069, azul: 0.087),
    categorias: Categorias(
      sesiones: Tono(hex: 0x64D2FF),
      tiempo: Tono(hex: 0x8486F6),
      segundoIdioma: Tono(hex: 0x7DF9C4),
      traducir: Tono(hex: 0xA5A7FA),
      leerEnVoz: Tono(hex: 0x5AC8FA)
    ),
    acentoDeLaBarra: Tono(hex: 0x0A84FF)
  )

  /// La menta, que ya era de Dilo, pasa a protagonista: la onda, el cursor,
  /// el punto y el acento. Como la onda ahora es menta, el acuse pasa a
  /// blanco —un check del color de la onda que reemplaza no se lee como un
  /// cambio de estado—. Ajustes vuelve a la tinta del ícono.
  static let menta = PaletaDeDilo(
    nombre: .menta,
    acento: Tono(hex: 0x2EE6A8),
    ondaBase: Tono(hex: 0x14B8A6),
    ondaPunta: Tono(hex: 0x2EE6A8),
    halo: Tono(hex: 0x2EE6A8, alfa: 0.45),
    ondaCuerpo: Tono(hex: 0x2EE6A8),
    puntoDeReposo: Tono(hex: 0x2EE6A8, alfa: 0.9),
    cursor: Tono(hex: 0x2EE6A8),
    acuse: .blanco,
    error: Tono(hex: 0xFF6B6B),
    segmento: Tono(hex: 0x2EE6A8),
    aviso: Tono(hex: 0xFFD60A),
    alerta: Tono(hex: 0xFF6B6B),
    microfonoMuerto: Tono(hex: 0xFFD60A),
    acentoDeAjustes: Tono(hex: 0x2EE6A8),
    exito: Tono(hex: 0x2EE6A8),
    fondoDeAjustes: Tono(hex: 0x080B0F),
    barraLateral: Tono(hex: 0x0D1117),
    tarjetaDeAjustes: Tono(hex: 0x161B22),
    categorias: Categorias(
      sesiones: Tono(hex: 0x2EE6A8),
      tiempo: Tono(hex: 0x8486F6),
      segundoIdioma: Tono(hex: 0x7DD3FC),
      traducir: Tono(hex: 0xA5A7FA),
      leerEnVoz: Tono(hex: 0x5EEAD4)
    ),
    acentoDeLaBarra: Tono(hex: 0x14B8A6)
  )

  /// La paleta con que se dibuja ahora: la elegida o, mientras el arnés
  /// muestra una escena con `--paleta`, la de la muestra.
  ///
  /// Se lee de cualquier hilo y, dentro de un `body`, SwiftUI queda
  /// observándola: cambiar de paleta redibuja la muesca y Ajustes sin que
  /// ninguna vista la reciba por parámetro.
  static var actual: PaletaDeDilo { PaletaActiva.compartida.paleta }
}

/// Cuál paleta está puesta. Una sola por proceso, como `UserDefaults`.
///
/// Observable a mano y no con la macro: la macro no es segura entre hilos, y
/// la paleta se lee desde vistas, desde los `NSImage` del status item y
/// desde inicializadores estáticos que no viven en el hilo principal.
final class PaletaActiva: Observable, Sendable {
  static let compartida = PaletaActiva()

  private struct Estado {
    var elegida: PaletaDeDilo.Nombre = .mango
    var deMuestra: PaletaDeDilo.Nombre?
  }

  private let registro = ObservationRegistrar()
  private let estado = Mutex(Estado())

  var paleta: PaletaDeDilo {
    registro.access(self, keyPath: \.paleta)
    return estado.withLock { ($0.deMuestra ?? $0.elegida).paleta }
  }

  var elegida: PaletaDeDilo.Nombre { estado.withLock { $0.elegida } }

  /// La que eligió la persona (`AppSettings.paleta`).
  func elegir(_ nombre: PaletaDeDilo.Nombre) {
    guard elegida != nombre else { return }
    registro.withMutation(of: self, keyPath: \.paleta) {
      estado.withLock { $0.elegida = nombre }
    }
  }

  /// La que pide el arnés para una escena, o nil para volver a la elegida.
  /// No se guarda: soltar la muestra la olvida.
  func mostrarDeMuestra(_ nombre: PaletaDeDilo.Nombre?) {
    registro.withMutation(of: self, keyPath: \.paleta) {
      estado.withLock { $0.deMuestra = nombre }
    }
  }
}

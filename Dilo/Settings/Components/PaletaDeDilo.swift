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

  /// El tono a `t` del camino hacia `otro` (0 es éste, 1 es el otro), en
  /// sRGB y sin corregir la luz: entre dos azules vecinos no hace falta más.
  func mezcla(con otro: Tono, _ t: Double) -> Tono {
    let t = min(max(t, 0), 1)
    return Tono(
      rojo: rojo + (otro.rojo - rojo) * t,
      verde: verde + (otro.verde - verde) * t,
      azul: azul + (otro.azul - azul) * t,
      alfa: alfa + (otro.alfa - alfa) * t
    )
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
/// **De fábrica es `glaciar`; `grafito` se elige en Ajustes → Apariencia →
/// Color.** Decisión de Alfonso del 2026-10-14, con el makeover al estilo
/// Droppy: «el color naranja ya no me gusta». El mango y la menta de antes
/// salieron como opciones; siguen siendo los colores del ícono (`DiloBrand`,
/// `brand/`) hasta que se regenere. El arnés de la muesca dibuja con
/// cualquiera de las dos con `--paleta`.
///
/// Fuera de la paleta, a propósito: las paletas del Edge Glow (las elige la
/// persona y nunca recolorean el caparazón), el arcoíris del estilo Siri y
/// el ícono de la app, que es un activo (`brand/`).
struct PaletaDeDilo: Equatable, Sendable, Identifiable {
  /// Cuál es. El `rawValue` se guarda en `UserDefaults`: no se renombra.
  enum Nombre: String, CaseIterable, Sendable, Identifiable {
    case glaciar
    case grafito

    /// La de fábrica.
    static let deFabrica = Nombre.glaciar

    var id: String { rawValue }

    /// Lo que dice el selector de Ajustes. El `rawValue` es lo que se guarda
    /// y no se traduce nunca; esto sí.
    var titulo: String {
      switch self {
      case .glaciar: String(localized: "Glaciar")
      case .grafito: String(localized: "Grafito")
      }
    }

    var paleta: PaletaDeDilo {
      switch self {
      case .glaciar: .glaciar
      case .grafito: .grafito
      }
    }
  }

  /// Los colores de categoría de Ajustes: cada atajo y cada serie de
  /// Actividad tiene el suyo para distinguirse de los otros, no para decir
  /// la marca. Van acá porque antes uno era naranja.
  struct Categorias: Equatable, Sendable {
    var sesiones: Tono
    var tiempo: Tono
    var segundoIdioma: Tono
    var traducir: Tono
    var leerEnVoz: Tono
  }

  /// Los íconos de la barra lateral de Ajustes, uno por familia de
  /// secciones (2026-10-19): el color dice de qué grupo es cada una, como en
  /// Ajustes del Sistema, sin que cada sección invente el suyo.
  struct IconosDeAjustes: Equatable, Sendable {
    var portada: Tono
    var voz: Tono
    var claude: Tono
    var sistema: Tono
    var dilo: Tono
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
  /// El filo de color del borde de abajo de la muesca abierta
  /// (`FiloDeLaMuesca`): lo que dice, sin una palabra, que la forma está
  /// haciendo algo. Con alfa: es una luz sobre el negro, no una línea.
  var filo: Tono
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
  /// El punto «grabando» de una reunión (`HUDReunionEnLaMuesca`). Rojo en
  /// las dos paletas: es la convención de todo lo que graba, y con Grafito es
  /// justo el color semántico que la regla deja pasar.
  var grabando: Tono

  /// El acento de la ventana de Ajustes y de los Primeros pasos:
  /// interruptores, selección, la sección elegida.
  var acentoDeAjustes: Tono
  /// Lo que salió bien en Ajustes: «LOCAL», «Listo», copiado.
  var exito: Tono
  var fondoDeAjustes: Tono
  var barraLateral: Tono
  var tarjetaDeAjustes: Tono
  var categorias: Categorias
  var iconosDeAjustes: IconosDeAjustes

  /// El color con que se llena el ícono de la barra de menús mientras
  /// transcribe un archivo, y el de las superficies de arrastrar un archivo.
  /// En reposo el ícono es plantilla y no lleva color.
  var acentoDeLaBarra: Tono
}

extension PaletaDeDilo {
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
    filo: Tono.blanco.opacidad(0.22),
    puntoDeReposo: Tono.blanco.opacidad(0.7),
    cursor: .blanco,
    acuse: Tono(hex: 0x30D158),
    error: Tono(hex: 0xFF6B6B),
    segmento: .blanco,
    aviso: Tono(hex: 0xFFD60A),
    alerta: Tono(hex: 0xFF6B6B),
    microfonoMuerto: Tono(hex: 0xFFD60A),
    grabando: Tono(hex: 0xFF453A),
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
    iconosDeAjustes: IconosDeAjustes(
      portada: .blanco,
      voz: Tono(hex: 0xD1D1D6),
      claude: Tono(hex: 0xC7C7CC),
      sistema: Tono(hex: 0x98989D),
      dilo: Tono(hex: 0xAEAEB2)
    ),
    acentoDeLaBarra: Tono(hex: 0x8E8E93)
  )

  /// **La de fábrica** (2026-10-14). Fría: celeste sobre negro, del azul de
  /// Apple al cian. Es la familia de color de Droppy —su ícono va de lavanda
  /// a azul eléctrico— pero más clara, porque su azul `#1219ED` sobre negro
  /// casi no se ve. El acuse es una menta pálida, del mismo frío pero otra
  /// cosa que la onda. Los fondos de Ajustes son los de siempre, que ya
  /// tiraban a azul.
  static let glaciar = PaletaDeDilo(
    nombre: .glaciar,
    acento: Tono(hex: 0x64D2FF),
    ondaBase: Tono(hex: 0x0A84FF),
    ondaPunta: Tono(hex: 0x64D2FF),
    halo: Tono(hex: 0x64D2FF, alfa: 0.6),
    ondaCuerpo: Tono(hex: 0x64D2FF),
    filo: Tono(hex: 0x64D2FF, alfa: 0.85),
    puntoDeReposo: Tono(hex: 0x64D2FF, alfa: 0.9),
    cursor: Tono(hex: 0x64D2FF),
    acuse: Tono(hex: 0x7DF9C4),
    error: Tono(hex: 0xFF6B6B),
    segmento: Tono(hex: 0x64D2FF),
    aviso: Tono(hex: 0xFFD60A),
    alerta: Tono(hex: 0xFF6B6B),
    microfonoMuerto: Tono(hex: 0xFFD60A),
    grabando: Tono(hex: 0xFF453A),
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
    // Del azul de la onda al celeste del caret para lo que es dictar, la
    // lavanda de Actividad para Claude, un gris pizarra para lo que es
    // ajuste del Mac y la menta del acuse para lo que es de Dilo.
    iconosDeAjustes: IconosDeAjustes(
      portada: Tono(hex: 0x0A84FF),
      voz: Tono(hex: 0x64D2FF),
      claude: Tono(hex: 0xA5A7FA),
      sistema: Tono(hex: 0x9AA6B8),
      dilo: Tono(hex: 0x7DF9C4)
    ),
    acentoDeLaBarra: Tono(hex: 0x0A84FF)
  )

  /// Los dos colores de una barra de la onda, abajo y arriba.
  ///
  /// La fila entera es un degradado de izquierda a derecha —de `ondaBase` en
  /// la primera barra a `ondaPunta` en la última— y cada barra, además, se
  /// aclara hacia la punta. Con un solo degradado vertical, cinco barras de
  /// tres puntos se leían como un celeste parejo y el azul no aparecía
  /// nunca (2026-10-14: «no le veo mucho cambio a los colores en el notch»).
  func coloresDeLaBarra(_ indice: Int, de barras: Int) -> (abajo: Tono, arriba: Tono) {
    let t = barras > 1 ? Double(indice) / Double(barras - 1) : 1
    return (
      abajo: ondaBase.mezcla(con: ondaPunta, t * 0.55),
      arriba: ondaBase.mezcla(con: ondaPunta, 0.45 + t * 0.55)
    )
  }

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
    var elegida: PaletaDeDilo.Nombre = .deFabrica
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

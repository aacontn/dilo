// Propio de Dilo. Ideas, sin código: las variables de contexto de Spokenly,
// cada una con su interruptor, y las categorías de app de Wispr Flow
// (propietarias); los topes de largo y el contexto marcado como no confiable,
// de Muesli (MIT).
import Foundation

/// En qué tipo de app se dicta. Le sirve al prompt («Mensaje» no es
/// «Correo») y sale de una lista de bundle ids, sin modelo.
///
/// El `rawValue` viaja al modelo dentro del sobre: va en español y no se
/// renombra.
public enum CategoriaDeApp: String, Codable, CaseIterable, Sendable {
  case mensajeria, correo, codigo, navegador, documento, asistente, otra

  public static func de(bundleID: String?) -> CategoriaDeApp {
    guard let id = bundleID?.lowercased() else { return .otra }
    return porBundle[id] ?? .otra
  }

  /// Se completa a mano y con tests; nunca se baja de internet.
  static let porBundle: [String: CategoriaDeApp] = [
    "net.whatsapp.whatsapp": .mensajeria, "com.tinyspeck.slackmacgap": .mensajeria,
    "ru.keepcoder.telegram": .mensajeria, "com.apple.mobilesms": .mensajeria,
    "com.hnc.discord": .mensajeria, "desktop.whatsapp": .mensajeria,
    "com.apple.mail": .correo, "com.readdle.smartemail-mac": .correo,
    "com.microsoft.outlook": .correo, "com.superhuman.electron": .correo,
    "com.apple.dt.xcode": .codigo, "com.microsoft.vscode": .codigo,
    "com.todesktop.230313mzl4w4u92": .codigo, "dev.zed.zed": .codigo,
    "com.apple.terminal": .codigo, "com.googlecode.iterm2": .codigo,
    "com.mitchellh.ghostty": .codigo, "dev.warp.warp-stable": .codigo,
    "com.apple.safari": .navegador, "com.google.chrome": .navegador,
    "company.thebrowser.browser": .navegador, "company.thebrowser.dia": .navegador,
    "com.brave.browser": .navegador, "com.microsoft.edgemac": .navegador,
    "org.mozilla.firefox": .navegador,
    "com.apple.notes": .documento, "com.apple.iwork.pages": .documento,
    "com.microsoft.word": .documento, "md.obsidian": .documento,
    "com.anthropic.claudefordesktop": .asistente, "com.openai.chat": .asistente,
  ]
}

/// Qué le cuenta Dilo al modelo de texto sobre dónde estás dictando. Cada
/// fuente con su interruptor.
///
/// De fábrica sólo la app: el nombre y la categoría no dicen nada de lo que
/// escribes. Lo que se lee de otra app (el texto alrededor del cursor, la
/// selección, el sitio) se prende a mano, y en App Store no existe.
///
/// El `Codable` es lo que se guarda en `diloFuentesDeContexto`: los nombres de
/// los campos no se renombran.
public struct FuentesDeContexto: Codable, Equatable, Sendable {
  public var app = true
  public var textoAlrededor = false
  public var seleccion = false
  public var sitio = false
  /// Con un proveedor en línea el contexto viaja con el dictado. Apagado de
  /// fábrica: con el modelo del chip el contexto nunca sale del Mac, y con
  /// uno en línea sólo sale si la persona lo pidió.
  public var tambienEnLinea = false

  public init(
    app: Bool = true, textoAlrededor: Bool = false, seleccion: Bool = false,
    sitio: Bool = false, tambienEnLinea: Bool = false
  ) {
    self.app = app
    self.textoAlrededor = textoAlrededor
    self.seleccion = seleccion
    self.sitio = sitio
    self.tambienEnLinea = tambienEnLinea
  }

  public static let deFabrica = FuentesDeContexto()

  /// Si hay que leer algo de la otra app al empezar el dictado.
  public var leeElCampo: Bool { textoAlrededor || seleccion }

  /// Un campo nuevo no puede costar la elección guardada.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    app = try c.decodeIfPresent(Bool.self, forKey: .app) ?? true
    textoAlrededor = try c.decodeIfPresent(Bool.self, forKey: .textoAlrededor) ?? false
    seleccion = try c.decodeIfPresent(Bool.self, forKey: .seleccion) ?? false
    sitio = try c.decodeIfPresent(Bool.self, forKey: .sitio) ?? false
    tambienEnLinea = try c.decodeIfPresent(Bool.self, forKey: .tambienEnLinea) ?? false
  }
}

/// Lo que rodeaba al dictado, leído al empezar. Vive en RAM lo que dura la
/// sesión: se arma, se usa en el prompt y en la elección del modo, y se
/// suelta. Nunca va al historial, al disco ni a un log.
public struct ContextoCapturado: Equatable, Sendable {
  public var nombreDeApp: String?
  public var bundleID: String?
  public var textoAntes = ""
  public var textoDespues = ""
  public var seleccion = ""
  /// Sólo dominio y ruta, sin consulta: `mail.google.com/mail`.
  public var sitio: String?

  public init(
    nombreDeApp: String? = nil, bundleID: String? = nil,
    textoAntes: String = "", textoDespues: String = "", seleccion: String = "",
    sitio: String? = nil
  ) {
    self.nombreDeApp = nombreDeApp
    self.bundleID = bundleID
    self.textoAntes = textoAntes
    self.textoDespues = textoDespues
    self.seleccion = seleccion
    self.sitio = sitio
  }

  public var categoria: CategoriaDeApp { .de(bundleID: bundleID) }

  /// Lo que entra al sobre del dictado según los interruptores, o nil si no
  /// queda nada. El recorte por largo lo hace el sobre al codificarse.
  public func paraElSobre(_ fuentes: FuentesDeContexto) -> SobreDelDictado.ContextoDeLaApp? {
    var contexto = SobreDelDictado.ContextoDeLaApp()
    if fuentes.app, let nombreDeApp, !nombreDeApp.isEmpty {
      contexto.app = nombreDeApp
      contexto.categoria = categoria == .otra ? nil : categoria.rawValue
    }
    if fuentes.sitio, let sitio, !sitio.isEmpty { contexto.sitio = sitio }
    if fuentes.textoAlrededor {
      contexto.textoAntesDelCursor = textoAntes.isEmpty ? nil : textoAntes
      contexto.textoDespuesDelCursor = textoDespues.isEmpty ? nil : textoDespues
    }
    if fuentes.seleccion, !seleccion.isEmpty { contexto.seleccion = seleccion }
    return contexto.estaVacio ? nil : contexto
  }
}

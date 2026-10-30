import AppKit
import CoreGraphics

/// Aprieta ↩ por la persona cuando el dictado terminó con «envía» y
/// `PoliticaDelEnvio` dijo que sí.
///
/// Si sostiene un modificador se le espera un rato —acaba de soltar el
/// gatillo y puede que un ⌃ o un ⌥ todavía vengan subiendo—; si sigue ahí,
/// no se manda. Los eventos los arma `AtajoSimulado`, con la marca de Dilo,
/// y van por el mismo canal que el ⌘V que acaba de pegar.
enum EnvioDelMensaje {
  /// Lo más que se espera a que la persona suelte un modificador.
  static let esperaPorModificadores = Duration.seconds(2)
  static let cadaCuantoMira = Duration.milliseconds(50)
  /// El respiro entre el pegado confirmado y el ↩: un campo que todavía está
  /// pintando el texto pegado puede tomar el ↩ antes que el texto.
  static let respiroTrasPegar = Duration.milliseconds(50)

  /// - Returns: false si no se apretó nada.
  @MainActor
  static func apretarIntro(
    por canal: CanalDelAtajo,
    apretadas: () -> AtajoSimulado.TeclasApretadas = { .delTeclado() },
    crear: ((AtajoSimulado.Pulsacion) -> CGEvent?)? = nil,
    publicar: ((CGEvent) -> Void)? = nil,
    dormir: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async -> Bool {
    try? await dormir(respiroTrasPegar)
    var esperado = Duration.zero
    var pulsaciones = AtajoSimulado.pulsacionesDeIntro(con: apretadas())
    while pulsaciones == nil, esperado < esperaPorModificadores {
      do { try await dormir(cadaCuantoMira) } catch { return false }
      esperado += cadaCuantoMira
      pulsaciones = AtajoSimulado.pulsacionesDeIntro(con: apretadas())
    }
    guard let pulsaciones else { return false }
    let crear = crear ?? { [fuente = CGEventSource(stateID: .hidSystemState)] pulsacion in
      AtajoSimulado.evento(pulsacion, fuente: fuente)
    }
    return AtajoSimulado.publicar(pulsaciones, crear: crear, publicar: publicar ?? canal.publicar)
  }
}

/// Si una palabra es común en español, para `AjusteAlCursor`: «quedó» baja a
/// minúscula a mitad de frase, «Martina» no.
///
/// La primera consulta al corrector del sistema puede tardar un tercio de
/// segundo —se despierta el servidor de ortografía—, y eso no puede caer al
/// soltar (spec §3: < 300 ms). Por eso se calienta al empezar el dictado, en
/// segundo plano, y mientras no esté caliente **no baja nada**: ante la duda,
/// la palabra se queda como vino.
@MainActor
final class CorrectorEnEspanol {
  static let compartido = CorrectorEnEspanol()

  private var caliente = false
  private var calentando = false
  private let ortografia = NSOrthography(dominantScript: "Latn", languageMap: ["Latn": ["es"]])

  func calentar() {
    guard !caliente, !calentando else { return }
    calentando = true
    let muestra = "hola quedó"
    NSSpellChecker.shared.requestChecking(
      of: muestra,
      range: NSRange(location: 0, length: (muestra as NSString).length),
      types: NSTextCheckingResult.CheckingType.spelling.rawValue,
      options: [.orthography: ortografia],
      inSpellDocumentWithTag: 0
    ) { [weak self] _, _, _, _ in
      Task { @MainActor in
        self?.caliente = true
        self?.calentando = false
      }
    }
  }

  func esPalabraComun(_ palabra: String) -> Bool {
    guard caliente else { return false }
    let rango = NSSpellChecker.shared.checkSpelling(
      of: palabra, startingAt: 0, language: "es", wrap: false,
      inSpellDocumentWithTag: 0, wordCount: nil
    )
    return rango.location == NSNotFound
  }
}

import Foundation

/// Qué deja grabar un grabador de atajos, antes de que el validador opine.
///
/// Es la otra mitad de `ValidadorDeGatillos`: el validador dice si un gatillo
/// **sirve**, y esto dice si el grabador siquiera lo deja llegar hasta él.
/// Existe porque las dos mitades estaban separadas y se desincronizaron:
/// Modos apagaba a mano los modificadores solos y los botones del mouse, así
/// que `fn` —el gatillo de fábrica de Dilo, que el validador bendice y que
/// Atajos sí acepta— no se le podía asignar a un modo. La pantalla decidía
/// por su cuenta lo que el AGENTS.md dice que decide una sola regla.
///
/// Dos pantallas que asignan la misma clase de tecla ofrecen lo mismo, y para
/// eso la política vive en un solo lugar y las dos la nombran.
public struct PoliticaDeGrabador: Equatable, Sendable {
  /// Un modificador solo —`fn`/🌐, ⌘ derecha— puede ser el gatillo.
  public var admiteModificadorSolo: Bool
  /// Un botón auxiliar del mouse puede ser el gatillo.
  public var admiteBotonDelMouse: Bool

  public init(admiteModificadorSolo: Bool, admiteBotonDelMouse: Bool) {
    self.admiteModificadorSolo = admiteModificadorSolo
    self.admiteBotonDelMouse = admiteBotonDelMouse
  }

  /// Sostener para hablar: se aprieta, se habla y se suelta. Acepta todo lo
  /// que el validador bendiga, modificadores solos y botones del mouse
  /// incluidos, porque sostener es justamente lo que esas entradas hacen bien.
  public static let sostenerYHablar = PoliticaDeGrabador(
    admiteModificadorSolo: true, admiteBotonDelMouse: true
  )

  /// Apretar y soltar: una acción que dispara en `keyDown` y no tiene camino
  /// de mouse ni de modificador suelto. Grabar uno ahí sería guardar una
  /// tecla muerta. Hoy es sólo Leer en voz alta.
  public static let apretarYSoltar = PoliticaDeGrabador(
    admiteModificadorSolo: false, admiteBotonDelMouse: false
  )

  /// La del gatillo de un modo. Un modo se dicta sosteniendo su tecla, igual
  /// que el dictado normal, así que es la misma —y el test lo vigila.
  public static let deUnModo = sostenerYHablar

  /// La de los atajos de dictar, segundo idioma y traducir.
  public static let deDictado = sostenerYHablar

  /// Si este grabador deja grabar este gatillo **y** el validador lo bendice.
  /// Las dos condiciones juntas: por separado es como se desincronizaron.
  public func admite(_ gatillo: Gatillo) -> Bool {
    if gatillo.botonDelMouse != nil { return admiteBotonDelMouse }
    if gatillo.esModificador, !admiteModificadorSolo { return false }
    return ValidadorDeGatillos.revisar(gatillo).sirve
  }
}

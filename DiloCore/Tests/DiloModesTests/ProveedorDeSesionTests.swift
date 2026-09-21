import Foundation
import Testing

@testable import DiloModes

/// El proveedor se congela al empezar el dictado y no hay segundo intento.
///
/// La regla que estos tests defienden: **nunca un salto silencioso de local a
/// remoto**. Un modo que pedía correr en el chip y no puede no se va a una
/// nube; se dice y el dictado sale tal cual.
struct ProveedorDeSesionTests {
  private let catalogo: [Proveedor] = [
    Proveedor(id: "chip", nombre: "El modelo de Apple, acá mismo", dialecto: .enElChip),
    Proveedor(
      id: "openai", nombre: "OpenAI", dialecto: .compatibleOpenAI,
      urlBase: URL(string: "https://api.openai.com/v1"), modelo: "gpt-5"
    ),
    Proveedor(
      id: "propio", nombre: "El tuyo", dialecto: .compatibleOpenAI,
      urlBase: URL(string: "http://localhost:11434/v1"), modelo: "llama"
    ),
    // El mismo de arriba pero sin modelo: configurado a medias, no usable.
    Proveedor(
      id: "aMedias", nombre: "A medias", dialecto: .compatibleOpenAI,
      urlBase: URL(string: "http://localhost:11434/v1"), modelo: ""
    ),
  ]

  private func modo(_ proveedorID: String?) -> Modo {
    Modo(id: "correo", nombre: "Correo", prompt: "x", proveedorID: proveedorID)
  }

  private func deSesion(
    _ modo: Modo, general: String?, conClaves: Bool = true
  ) -> ResolucionDeProveedor.DeSesion {
    ResolucionDeProveedor.deSesion(
      para: modo, general: general, catalogo: catalogo,
      tieneClave: { _ in conClaves }
    )
  }

  @Test func elProveedorDelModoManda() {
    guard case let .corre(resuelto) = deSesion(modo("openai"), general: "chip") else {
      Issue.record("No corrió con el proveedor del modo")
      return
    }
    #expect(resuelto.proveedor.id == "openai")
    #expect(!resuelto.esLocal)
  }

  @Test func sinProveedorPropioHeredaElGeneral() {
    guard case let .corre(resuelto) = deSesion(modo(nil), general: "openai") else {
      Issue.record("No heredó el general")
      return
    }
    #expect(resuelto.proveedor.id == "openai")
  }

  /// El caso que da nombre al encargo: el modo pedía local, lo local no
  /// resuelve, y el general es una nube. No se cruza.
  @Test func unModoLocalQueNoResuelveNoSeVaALaNube() {
    guard case let .seNiegaACruzar(aviso) = deSesion(modo("aMedias"), general: "openai") else {
      Issue.record("Cruzó a la nube en silencio")
      return
    }
    #expect(aviso.contains("Correo"))
    #expect(aviso.contains("OpenAI"))
    #expect(aviso.contains("tal cual"))
  }

  /// Lo mismo, pero cayendo a otro proveedor local: eso sí se puede, porque
  /// el texto no sale de la compu.
  @Test func caerDeUnLocalAOtroLocalSiSePuede() {
    guard case let .corre(resuelto) = deSesion(modo("aMedias"), general: "chip") else {
      Issue.record("No usó el respaldo local")
      return
    }
    #expect(resuelto.esLocal)
  }

  @Test func sinNadaConfiguradoElDictadoSaleLimpio() {
    #expect(deSesion(modo("aMedias"), general: "aMedias") == .sinProveedor)
    #expect(deSesion(modo(nil), general: nil) == .sinProveedor)
  }

  /// Una nube sin clave no está disponible. Si lo que queda es el chip, se
  /// usa: caer hacia adentro de la compu no es el peligro — el peligro es el
  /// revés, y ése está cubierto arriba.
  @Test func unaNubeSinClaveCaeAlChipYNoAlVacio() {
    guard case let .corre(resuelto) = deSesion(
      modo("openai"), general: "chip", conClaves: false
    ) else {
      Issue.record("Una nube sin clave dejó el dictado sin proveedor")
      return
    }
    #expect(resuelto.esLocal)
  }

  @Test func unaNubeSinClaveYSinRespaldoDejaElDictadoLimpio() {
    #expect(deSesion(modo("openai"), general: "openai", conClaves: false) == .sinProveedor)
  }

  /// Congelar quiere decir esto: el proveedor que se resolvió al empezar es
  /// el que corre, aunque Ajustes cambie a mitad de dictado.
  @Test func loQueSeResolvioAlEmpezarNoLoCambiaAjustes() {
    let congelado = deSesion(modo("openai"), general: "chip")
    // Ajustes cambia el general mientras la persona habla. El valor ya
    // resuelto es un valor: no hay nada que pueda alterarlo.
    let despues = deSesion(modo("openai"), general: "propio")
    #expect(congelado == despues)
    guard case let .corre(resuelto) = congelado else { return }
    #expect(resuelto.modelo == "gpt-5")
  }

  @Test func laPildoraDiceQuePasoCuandoElProveedorCongeladoFalla() {
    let aviso = ResolucionDeProveedor.avisoDeFalla(
      modo: modo("openai"), proveedor: catalogo[1]
    )
    #expect(aviso.contains("Correo"))
    #expect(aviso.contains("OpenAI"))
    #expect(aviso.contains("Copiar el último dictado"))
  }
}

/// Lo último que dictaste, recuperable sin encender el historial.
struct UltimoDictadoTests {
  private let conModo = UltimoDictado(
    original: "eh o sea mándale el correo a juan po",
    limpio: "mándale el correo a juan",
    transformado: "Estimado Juan:\n\nTe escribo para…",
    modo: "Correo"
  )

  @Test func lasDosMitadesSeGuardanSeparadas() {
    #expect(conModo.texto(.original) == "eh o sea mándale el correo a juan po")
    #expect(conModo.texto(.entregado).hasPrefix("Estimado Juan:"))
    #expect(conModo.tieneDosMitades)
  }

  /// Sin modo, lo entregado es lo limpio: ofrecer dos opciones que copian lo
  /// mismo es ruido en el menú.
  @Test func sinModoLoEntregadoEsLoLimpio() {
    let sinModo = UltimoDictado(original: "hola hola", limpio: "hola hola")
    #expect(sinModo.texto(.entregado) == "hola hola")
    #expect(!sinModo.tieneDosMitades)
  }

  /// Aunque el modo haya corrido, si devolvió exactamente lo mismo tampoco
  /// hay dos mitades que ofrecer.
  @Test func unModoQueNoCambioNadaNoAgregaUnaMitad() {
    let igual = UltimoDictado(
      original: "hola", limpio: "hola", transformado: "hola", modo: "Limpio"
    )
    #expect(!igual.tieneDosMitades)
  }

  @Test func elVistazoCabeEnUnaLineaYNoParteElTexto() {
    let largo = UltimoDictado(
      original: String(repeating: "palabra ", count: 20),
      limpio: "una\nlínea\ny otra"
    )
    #expect(largo.vistazo(.entregado) == "una línea y otra")
    #expect(largo.vistazo(.original).count <= 43)
    #expect(largo.vistazo(.original).hasSuffix("…"))
    // Corto de verdad no se toca.
    #expect(UltimoDictado(original: "hola", limpio: "hola").vistazo(.entregado) == "hola")
  }
}

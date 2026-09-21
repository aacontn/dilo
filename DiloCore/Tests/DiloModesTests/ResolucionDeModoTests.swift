import Testing

@testable import DiloModes

struct ResolucionDeModoTests {
  private let modos = Modo.deFabrica

  @Test func elAtajoDelModoDisparaEseModoYNoOtro() {
    let elegido = ResolucionDeModo.porAtajo(.controlComandoL, entre: modos)
    #expect(elegido?.id == "limpio")
  }

  @Test func unaTeclaDeNadieNoEsUnError() {
    #expect(ResolucionDeModo.porAtajo(.fn, entre: modos) == nil)
  }

  @Test func laEtiquetaNoDecideCualModoDispara() {
    // El mismo gatillo grabado en otro teclado trae otra etiqueta; lo que
    // dispara es la tecla más los modificadores.
    var mismaTecla = Gatillo.controlComandoL
    mismaTecla.etiqueta = "Control Comando L"
    #expect(ResolucionDeModo.porAtajo(mismaTecla, entre: modos)?.id == "limpio")
  }

  @Test func sinLaOpcionPrendidaNingunDictadoSeVaAUnModoSolo() async {
    let eleccion = await ResolucionDeModo.resolver(
      gatillo: nil,
      texto: "hay que revisar el commit antes del deploy",
      contexto: ContextoDeDecision(appAlFrente: "Ghostty"),
      modos: modos,
      unAtajoDiloDecide: false,
      decider: DeciderPorReglas(modos: modos)
    )
    #expect(eleccion.modo == nil)
    #expect(eleccion.razon == .ninguna)
  }

  @Test func conLaOpcionPrendidaLaAppAlFrenteDecide() async {
    let eleccion = await ResolucionDeModo.resolver(
      gatillo: nil,
      texto: "hola, esto es cualquier cosa",
      contexto: ContextoDeDecision(appAlFrente: "Ghostty"),
      modos: modos,
      unAtajoDiloDecide: true,
      decider: DeciderPorReglas(modos: modos)
    )
    #expect(eleccion.modo?.id == "codigo")
    #expect(eleccion.razon == .reglas(probabilidad: 0.95))
  }

  @Test func elAtajoLeGanaAlDecididor() async {
    // Apretaste la tecla de Limpio desde el terminal: manda la tecla. Lo que
    // la persona dijo explícitamente no lo contradice ningún decididor.
    let eleccion = await ResolucionDeModo.resolver(
      gatillo: .controlComandoL,
      texto: "el commit del deploy",
      contexto: ContextoDeDecision(appAlFrente: "Ghostty"),
      modos: modos,
      unAtajoDiloDecide: true,
      decider: DeciderPorReglas(modos: modos)
    )
    #expect(eleccion.modo?.id == "limpio")
    #expect(eleccion.razon == .atajo)
  }

  @Test func laDudaDejaElDictadoComoSalio() async {
    let eleccion = await ResolucionDeModo.resolver(
      gatillo: nil,
      texto: "no sé qué estoy diciendo",
      contexto: ContextoDeDecision(appAlFrente: "Finder"),
      modos: modos,
      unAtajoDiloDecide: true,
      decider: DeciderPorReglas(modos: modos)
    )
    #expect(eleccion.modo == nil)
  }

  @Test func avisaCuandoDosModosSePeleanLaMismaTecla() {
    var correo = Modo.deFabrica[3]
    correo.gatillo = .controlComandoL
    let conflicto = [Modo.deFabrica[0], correo]
    #expect(conflicto.modosQueYaUsan(.controlComandoL, salvo: "correo").count == 1)
    #expect(conflicto.modosQueYaUsan(.controlComandoL).count == 2)
  }
}

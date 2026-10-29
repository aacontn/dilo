import DiloCapabilities
import DiloEngines
import DiloModes
import Testing
@testable import Dilo

/// Inicio dice si se puede dictar y qué falta, y cada aviso lleva a su
/// arreglo (`PortadaDeAjustes`).
@MainActor
struct PortadaDeAjustesTests {
  private func entrada() -> PortadaDeAjustes.Entrada {
    var entrada = PortadaDeAjustes.Entrada()
    entrada.permisosPedidos = [.microfono, .accesibilidad, .monitoreoDeEntrada]
    entrada.motorElegido = .apple
    entrada.hayClave = true
    entrada.modosConClaude = true
    return entrada
  }

  @Test func todoEnOrdenEsListoYSinAvisos() {
    let portada = PortadaDeAjustes(entrada())
    #expect(portada.listo)
    #expect(portada.avisos.isEmpty)
    #expect(portada.motorEnUso == .apple)
  }

  @Test func unPermisoQueFaltaBloqueaYSeArreglaPidiendolo() {
    var entrada = entrada()
    entrada.permisosQueFaltan = [.accesibilidad]
    let portada = PortadaDeAjustes(entrada)
    #expect(!portada.listo)
    #expect(portada.avisos.map(\.accion) == [.pedirPermiso(.accesibilidad)])
  }

  @Test func unPermisoQueEstaCopiaNoPideNoSeAvisa() {
    var entrada = entrada()
    // Los pedidos no incluyen el Reconocimiento de voz (como con Parakeet):
    // que falte no importa.
    entrada.permisosQueFaltan = [.reconocimientoDeVoz]
    #expect(PortadaDeAjustes(entrada).avisos.isEmpty)
  }

  @Test func parakeetSinModeloDictaConAppleYOfreceBajarUltra() {
    var entrada = entrada()
    entrada.motorElegido = .parakeet
    entrada.parakeetEnDisco = []
    let portada = PortadaDeAjustes(entrada)
    #expect(portada.motorEnUso == .apple)
    #expect(portada.listo, "dictar con Apple mientras tanto no es un bloqueo")
    #expect(portada.avisos.map(\.accion) == [.bajar(.ultra)])

    entrada.parakeetBajando = true
    #expect(PortadaDeAjustes(entrada).avisos.map(\.accion) == [.ir(.modeloDeParakeet)])
  }

  /// Quien ya tenía v3 sigue dictando con v3, y se le ofrece Ultra con su
  /// tamaño sin bloquear nada.
  @Test func conV3SeSigueDictandoYSeOfreceUltra() {
    var entrada = entrada()
    entrada.motorElegido = .parakeet
    entrada.parakeetEnDisco = [.v3]
    let portada = PortadaDeAjustes(entrada)
    #expect(portada.motorEnUso == .parakeet)
    #expect(portada.varianteEnUso == .v3)
    #expect(portada.listo)
    let aviso = try? #require(portada.avisos.first)
    #expect(aviso?.accion == .bajar(.ultra))
    #expect(aviso?.detalle.contains("\(VarianteDeParakeet.ultra.megasDeDescarga)") == true)
  }

  @Test func conUltraNoHayNadaQueOfrecer() {
    var entrada = entrada()
    entrada.motorElegido = .parakeet
    entrada.parakeetEnDisco = [.ultra, .v3]
    let portada = PortadaDeAjustes(entrada)
    #expect(portada.varianteEnUso == .ultra)
    #expect(portada.avisos.isEmpty)
  }

  @Test func sinClaveSeAvisaSoloSiAlgoUsaClaude() {
    var entrada = entrada()
    entrada.hayClave = false
    #expect(PortadaDeAjustes(entrada).avisos.map(\.id) == ["clave"])
    let tareasSinClave = PortadaDeAjustes(entrada).tareas.filter { $0.conClaude }
    #expect(tareasSinClave.allSatisfy { $0.sinClave })

    entrada.modosConClaude = false
    entrada.aprenderConClaude = false
    entrada.motorDeTraduccion = .apple
    #expect(PortadaDeAjustes(entrada).avisos.isEmpty)
  }

  @Test func mientrasElLlaveroNoContestaNoSeAvisaNada() {
    var entrada = entrada()
    entrada.hayClave = nil
    #expect(PortadaDeAjustes(entrada).avisos.isEmpty)
  }

  @Test func lasTareasDicenQuienLasHace() {
    var entrada = entrada()
    entrada.modeloDeLosModos = ModelosDeAnthropic.haiku.id
    entrada.modeloParaOrdenar = ModelosDeAnthropic.sonnet.id
    let tareas = PortadaDeAjustes(entrada).tareas
    #expect(tareas.map(\.id) == ["modos", "traducir", "revisar", "ordenar"])
    #expect(tareas[0].quien == "Claude Haiku 5.5")
    #expect(tareas[3].quien == "Claude Sonnet 5.5")
    // Sin elegir, con clave, traduce Claude.
    #expect(tareas[1].conClaude)
  }

  @Test func cadaAvisoYCadaTareaLlevaAUnaFilaQueExiste() {
    var entrada = entrada()
    entrada.permisosQueFaltan = Set(Permiso.allCases)
    entrada.motorElegido = .parakeet
    entrada.hayClave = false
    let portada = PortadaDeAjustes(entrada)
    let navegables = Set(SettingsSectionGroup.allCases.flatMap(\.sections))
    for aviso in portada.avisos {
      if case let .ir(ajuste) = aviso.accion {
        #expect(navegables.contains(ajuste.seccion))
      }
    }
    for tarea in portada.tareas {
      #expect(navegables.contains(tarea.ajuste.seccion))
    }
  }
}

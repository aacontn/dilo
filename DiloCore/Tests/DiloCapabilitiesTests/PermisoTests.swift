import ApplicationServices
import Foundation
import Testing

@testable import DiloCapabilities

/// Un anfitrión de mentira al que se le dicta qué esconde, para poder probar
/// la lista de permisos sin depender de lo que hoy puede el sandbox.
private struct AnfitrionDeMentira: HostCapabilities {
  var escondidas: Set<Capacidad> = []

  var nombre: String { "mentira" }
  func admite(_ capacidad: Capacidad) -> Bool { !escondidas.contains(capacidad) }
  var tieneAccesibilidad: Bool { false }
  func pedirAccesibilidad() -> Bool { false }
  func elementoEnfocado() -> AXUIElement? { nil }
  func elemento(_ duenno: AXUIElement, atributo: String) -> AXUIElement? { nil }
  func pid(de elemento: AXUIElement) -> pid_t { 0 }
  func esCampoSeguro(_ elemento: AXUIElement) -> Bool { false }
  func marco(de elemento: AXUIElement) -> CGRect? { nil }
  func sigueSiendoElFoco(elemento: AXUIElement?, pid: pid_t) -> Bool { false }
  func focoParaLeer() -> FocoLegible? { nil }
  func tituloDeVentanaActiva() -> String? { nil }
}

struct PermisosDelOnboardingTests {
  @Test func conElMotorDeAppleSePidenLosCuatro() {
    let pasos = Permiso.pasos(anfitrion: AnfitrionDeMentira(), motorEsApple: true)
    #expect(pasos == [.microfono, .reconocimientoDeVoz, .accesibilidad, .monitoreoDeEntrada])
  }

  /// Parakeet transcribe con su propio modelo: pedir Reconocimiento de voz
  /// sería pedir un permiso que ese motor no llega a usar nunca.
  @Test func conParakeetNoSePideReconocimientoDeVoz() {
    let pasos = Permiso.pasos(anfitrion: AnfitrionDeMentira(), motorEsApple: false)
    #expect(!pasos.contains(.reconocimientoDeVoz))
    #expect(pasos == [.microfono, .accesibilidad, .monitoreoDeEntrada])
  }

  /// La regla de la capa de capacidades, aplicada al onboarding: un permiso
  /// para algo que este anfitrión no puede hacer no se pide.
  @Test func loQueElAnfitrionEscondeNoSePide() {
    let sinPegar = AnfitrionDeMentira(escondidas: [.pegadoDirecto])
    #expect(!Permiso.pasos(anfitrion: sinPegar, motorEsApple: false).contains(.accesibilidad))

    let sinGatillo = AnfitrionDeMentira(escondidas: [.atajoGlobal])
    #expect(
      !Permiso.pasos(anfitrion: sinGatillo, motorEsApple: false).contains(.monitoreoDeEntrada)
    )
  }

  /// Hoy el target de App Store pega y oye el gatillo, así que pide lo mismo
  /// que el directo. Si algún día deja de poder una de las dos, este test
  /// cambia junto con `SandboxedHost` y no tres pantallas después.
  @Test func hoyElSandboxPideLosMismosQueElDirecto() {
    let sandbox = Permiso.pasos(anfitrion: SandboxedHost(lector: LectorEspia()), motorEsApple: true)
    let directo = Permiso.pasos(anfitrion: FullHost(lector: LectorEspia()), motorEsApple: true)
    #expect(sandbox == directo)
  }

  @Test("cada permiso dice por qué y a qué panel lleva", arguments: Permiso.allCases)
  func cadaPermisoSeExplica(_ permiso: Permiso) {
    #expect(!permiso.titulo.isEmpty)
    #expect(permiso.porque.hasSuffix("."), "el porqué es una frase, no una etiqueta")
    #expect(permiso.panelDeAjustes.hasPrefix("x-apple.systempreferences:"))
  }
}

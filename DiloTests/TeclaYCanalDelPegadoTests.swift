import AppKit
import ApplicationServices
import DiloCapabilities
import Testing

@testable import Dilo

struct TeclaDelAtajoTests {
  /// Una distribución inventada donde la V está en la tecla 47, como en
  /// Dvorak: el ⌘V tiene que salir por la 47 y no por la 9 de QWERTY.
  @Test func laTeclaSaleDeLaDistribucionConComando() {
    let dvorak: [CGKeyCode: String] = [9: "k", 47: "v", 8: "j", 34: "c"]
    #expect(TeclaDelAtajo.tecla(para: "v", traducir: { dvorak[$0] }) == 47)
    #expect(TeclaDelAtajo.tecla(para: "c", traducir: { dvorak[$0] }) == 34)
  }

  /// Una tabla que da mayúsculas con ⌘ (algunas lo hacen) sigue sirviendo.
  @Test func laLetraSeComparaSinMayusculas() {
    #expect(TeclaDelAtajo.tecla(para: "v", traducir: { $0 == 9 ? "V" : nil }) == 9)
  }

  @Test func sinTraduccionNoInventaUnaTecla() {
    #expect(TeclaDelAtajo.tecla(para: "v", traducir: { _ in nil }) == nil)
  }

  /// En cualquier distribución que tenga la máquina que corre esto, la
  /// respuesta es una tecla real y nunca el modificador.
  @Test func laDistribucionDeEstaMaquinaDaUnaTecla() {
    let tecla = TeclaDelAtajo.resolver("v")
    #expect(tecla < 128)
    #expect(!AtajoSimulado.teclasModificadoras.contains(tecla))
  }
}

struct CanalDelAtajoTests {
  @Test func conProcesoElAtajoVaAlPid() {
    #expect(CanalDelAtajo.para(pid: 42, alProceso: true) == .alProceso(42))
  }

  @Test func sinProcesoOSinPidVaAlSistema() {
    #expect(CanalDelAtajo.para(pid: 42, alProceso: false) == .alSistema)
    #expect(CanalDelAtajo.para(pid: 0, alProceso: true) == .alSistema)
  }
}

@MainActor
struct CompuertasDelPegadoEnElServicioTests {
  private func servicio(
    _ pasteboard: NSPasteboard,
    teclado: LecturasDelTeclado,
    canales: @escaping @MainActor (CanalDelAtajo) -> Bool,
    politica: (@MainActor (TextInsertionService.Target) -> PoliticaDeEntrega)? = nil
  ) -> TextInsertionService {
    nonisolated(unsafe) let deFondo = pasteboard
    var dependencias = TextInsertionService.Dependencies(
      pasteboard: pasteboard,
      readClipboardItems: { TextInsertionService.snapshot(of: deFondo) },
      snapshotTimeout: .milliseconds(100),
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: teclado,
      postPasteShortcut: canales,
      waitForPasteRead: {},
      clock: DrivenClock().deadlineClock
    )
    if let politica { dependencias.politica = politica }
    return TextInsertionService(dependencies: dependencias)
  }

  private func portapapeles() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("CompuertasDelPegado-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("lo tuyo", forType: .string)
    return pasteboard
  }

  private func destino() -> TextInsertionService.Target {
    .init(element: AXUIElementCreateSystemWide(), processIdentifier: 42, isSecure: false, displayID: nil)
  }

  @Test func elAtajoVaAlProcesoDelDestino() async {
    var canales: [CanalDelAtajo] = []
    let servicio = servicio(portapapeles(), teclado: .libre, canales: { canales.append($0); return true })
    _ = await servicio.insert("hola", into: destino())
    #expect(canales == [.alProceso(42)])
  }

  @Test func aUnRemotoElAtajoVaAlSistema() async {
    var canales: [CanalDelAtajo] = []
    let servicio = servicio(
      portapapeles(), teclado: .libre,
      canales: { canales.append($0); return true },
      politica: { _ in .para(.escritorioRemoto) }
    )
    _ = await servicio.insert("hola", into: destino())
    #expect(canales == [.alSistema])
  }

  /// Con la entrada segura encendida el foco está en una contraseña: no se
  /// manda ningún ⌘V y el portapapeles no se fotografía.
  @Test func conEntradaSeguraNoPega() async {
    var pegados = 0
    let segura = LecturasDelTeclado(entradaSegura: { true }, modificadores: { [] })
    let servicio = servicio(portapapeles(), teclado: segura, canales: { _ in pegados += 1; return true })
    let resultado = await servicio.insert("hola", into: destino())
    #expect(pegados == 0)
    #expect(resultado != .inserted)
  }
}

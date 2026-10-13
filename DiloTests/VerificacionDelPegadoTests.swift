import AppKit
import ApplicationServices
import DiloCapabilities
import os
import Testing

@testable import Dilo

/// Un campo de texto de mentira: lo que Accesibilidad diría de él, y que el
/// pegado o el tecleo pueden cambiar.
private final class CampoFalso: Sendable {
  private let estado: OSAllocatedUnfairLock<FotoDelCampo>
  private let lecturas = OSAllocatedUnfairLock(initialState: 0)

  init(_ foto: FotoDelCampo) {
    estado = OSAllocatedUnfairLock(initialState: foto)
  }

  var foto: FotoDelCampo {
    lecturas.withLock { $0 += 1 }
    return estado.withLock { $0 }
  }

  var vecesLeido: Int { lecturas.withLock { $0 } }

  func escribir(_ texto: String) {
    estado.withLock { foto in
      let valor = (foto.valor ?? "") + texto
      foto = FotoDelCampo(
        conteo: valor.utf16.count,
        valor: valor,
        seleccion: RangoDeTexto(ubicacion: valor.utf16.count, largo: 0)
      )
    }
  }
}

@MainActor
struct VerificacionDelPegadoTests {
  private let ancla = AnclaDelFoco(
    pid: 42,
    elemento: AXUIElementCreateSystemWide(),
    seleccion: RangoDeTexto(ubicacion: 5, largo: 0),
    marcador: nil
  )

  private func destino(bundleID: String? = nil) -> TextInsertionService.Target {
    TextInsertionService.Target(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      isSecure: false,
      displayID: nil,
      bundleID: bundleID,
      ancla: ancla
    )
  }

  private func portapapeles() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("VerificacionDelPegado-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("lo tuyo", forType: .string)
    return pasteboard
  }

  /// Lo que el servicio necesita para un pegado con campo legible. Por
  /// defecto, el ⌘V no lo lee nadie y el campo no cambia: la app ignoró el
  /// pegado.
  private func servicio(
    _ pasteboard: NSPasteboard,
    campo: CampoFalso,
    cursorQuieto: Bool = true,
    pegar: @escaping @MainActor (CanalDelAtajo) -> Bool = { _ in true },
    teclear: @escaping @MainActor ([TecleoDelDictado.Pedazo], CanalDelAtajo) async -> Bool = { _, _ in false },
    huboEntrada: Bool = false
  ) -> TextInsertionService {
    nonisolated(unsafe) let deFondo = pasteboard
    var dependencias = TextInsertionService.Dependencies(
      pasteboard: pasteboard,
      readClipboardItems: { TextInsertionService.snapshot(of: deFondo) },
      snapshotTimeout: RelojQueAvanzaAlDormir.plazoQueNoVence,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: pegar,
      clock: RelojQueAvanzaAlDormir().deadlineClock
    )
    dependencias.anclaDelFoco = { _ in nil }
    dependencias.anclaSigueIgual = { _ in cursorQuieto }
    dependencias.fotoDelCampo = { _ in campo.foto }
    dependencias.teclear = teclear
    dependencias.huboEntradaDeLaPersona = { _ in huboEntrada }
    return TextInsertionService(dependencies: dependencias)
  }

  private let antes = FotoDelCampo(conteo: 5, valor: "hola ", seleccion: RangoDeTexto(ubicacion: 5, largo: 0))

  /// El cursor se movió desde que empezó el dictado: no se pega en otro
  /// lado, se ofrece en la tarjeta.
  @Test func unCursorQueSeMovioNoRecibeElPegado() async {
    var pegados = 0
    let pasteboard = portapapeles()
    let servicio = servicio(pasteboard, campo: CampoFalso(antes), cursorQuieto: false, pegar: { _ in
      pegados += 1
      return true
    })

    let resultado = await servicio.entregar("qué tal", a: destino())

    #expect(resultado == .retenido(.focoCambio))
    #expect(pegados == 0)
    #expect(pasteboard.string(forType: .string) == "qué tal")
  }

  /// La app no lee el portapapeles por la promesa, pero Accesibilidad ve
  /// entrar el dictado: eso también confirma.
  @Test func elCampoQueCambiaConfirmaElPegado() async {
    let campo = CampoFalso(antes)
    let servicio = servicio(portapapeles(), campo: campo, pegar: { _ in
      campo.escribir("qué tal")
      return true
    })

    #expect(await servicio.entregar("qué tal", a: destino()) == .pegado(.campo))
  }

  /// El ⌘V no movió el campo en ninguna de las tres lecturas: se teclea una
  /// vez, por el mismo canal, y el campo confirma.
  @Test func campoQuietoReintentaTecleandoYConfirma() async {
    let campo = CampoFalso(antes)
    var tecleos: [([TecleoDelDictado.Pedazo], CanalDelAtajo)] = []
    let pasteboard = portapapeles()
    let servicio = servicio(pasteboard, campo: campo, teclear: { pedazos, canal in
      tecleos.append((pedazos, canal))
      campo.escribir("qué tal")
      return true
    })

    let resultado = await servicio.entregar("qué tal", a: destino())
    await servicio.tareaDeDevolucion?.value

    #expect(resultado == .pegado(.tecleo))
    #expect(tecleos.count == 1)
    #expect(tecleos.first?.0 == [.texto("qué tal")])
    #expect(tecleos.first?.1 == .alProceso(42))
    #expect(pasteboard.string(forType: .string) == "lo tuyo")
  }

  /// Si tampoco entra tecleado, no hay tercer intento: el dictado queda en
  /// la tarjeta y en el portapapeles.
  @Test func siTampocoEntraTecleadoQuedaParaPegarAMano() async {
    var tecleos = 0
    let pasteboard = portapapeles()
    let servicio = servicio(pasteboard, campo: CampoFalso(antes), teclear: { _, _ in
      tecleos += 1
      return true
    })

    let resultado = await servicio.entregar("qué tal", a: destino())

    #expect(resultado == .retenido(.noEntro))
    #expect(tecleos == 1)
    #expect(pasteboard.string(forType: .string) == "qué tal")
  }

  /// Una tecla de la persona después del ⌘V vuelve dudoso «no cambió»: el
  /// campo puede ser obra suya. No se teclea encima de alguien escribiendo.
  @Test func unaTeclaDeLaPersonaImpideTeclear() async {
    var tecleos = 0
    let servicio = servicio(portapapeles(), campo: CampoFalso(antes), teclear: { _, _ in
      tecleos += 1
      return true
    }, huboEntrada: true)

    #expect(await servicio.entregar("qué tal", a: destino()) == .pegadoSinConfirmar)
    #expect(tecleos == 0)
  }

  /// En una terminal un salto tecleado ejecuta y el valor es el historial:
  /// ni se lee el campo ni se teclea, aunque haya ancla.
  @Test func enUnaTerminalNoSeTecleaNiSeLeeElCampo() async {
    let campo = CampoFalso(antes)
    var tecleos = 0
    let servicio = servicio(portapapeles(), campo: campo, cursorQuieto: false, teclear: { _, _ in
      tecleos += 1
      return true
    })

    let resultado = await servicio.entregar("ls -la", a: destino(bundleID: "com.apple.Terminal"))

    #expect(resultado == .pegadoSinConfirmar)
    #expect(tecleos == 0)
    #expect(campo.vecesLeido == 0)
  }

  /// La lectura de la app gana: no se gasta Accesibilidad en confirmar lo
  /// que ya está confirmado.
  @Test func conAcuseNoSeLeeElCampoDespues() async {
    let campo = CampoFalso(antes)
    let pasteboard = portapapeles()
    let servicio = servicio(pasteboard, campo: campo, pegar: { _ in
      _ = pasteboard.string(forType: .string)
      return true
    })

    #expect(await servicio.entregar("qué tal", a: destino()) == .pegado(.lectura))
    // La única lectura es la de antes del ⌘V.
    #expect(campo.vecesLeido == 1)
  }
}

struct TecleoSimuladoTests {
  /// Cada pedazo de texto viaja en un evento sin modificadores; el salto es
  /// ⇧↩ con ⇧ bajando y subiendo, y el último evento queda limpio.
  @Test func lasPulsacionesDelTecleo() {
    let texto = AtajoSimulado.pulsaciones(deTecleo: .texto("hola"))
    #expect(texto.map(\.texto) == ["hola", "hola"])
    #expect(texto.allSatisfy { $0.modificadores.isEmpty && $0.tecla == 0 })

    let salto = AtajoSimulado.pulsaciones(deTecleo: .saltoDeLinea)
    #expect(salto.map(\.tecla) == [56, 36, 36, 56])
    #expect(salto.map(\.abajo) == [true, true, false, false])
    #expect(salto.dropLast().allSatisfy { $0.modificadores.contains(.maskShift) })
    #expect(salto.last?.modificadores.isEmpty == true)
  }

  /// Si un evento no se puede crear no se teclea nada: la mitad de un
  /// dictado es peor que ninguno.
  @Test @MainActor func siUnEventoNoSeCreaNoSeTecleaNada() async {
    var publicados = 0
    var creados = 0
    let salio = await TecleoSimulado.teclear(
      [.texto("hola"), .saltoDeLinea, .texto("chao")],
      crear: { pulsacion in
        creados += 1
        return creados == 5 ? nil : AtajoSimulado.evento(pulsacion, fuente: nil)
      },
      publicar: { _ in publicados += 1 },
      dormir: { _ in }
    )
    #expect(!salio)
    #expect(publicados == 0)
  }

  @Test @MainActor func todoLoTecleadoLlevaLaMarcaYElTexto() async {
    var eventos: [CGEvent] = []
    var pausas: [Duration] = []
    let salio = await TecleoSimulado.teclear(
      [.texto("qué"), .texto("😀")],
      crear: { AtajoSimulado.evento($0, fuente: nil) },
      publicar: { eventos.append($0) },
      dormir: { pausas.append($0) }
    )
    #expect(salio)
    #expect(eventos.count == 4)
    #expect(eventos.allSatisfy(AtajoSimulado.esDeDilo))
    #expect(pausas == [TecleoDelDictado.pausa])
    var largo = 0
    var unidades = [UniChar](repeating: 0, count: 8)
    eventos[2].keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &largo, unicodeString: &unidades)
    #expect(String(utf16CodeUnits: unidades, count: largo) == "😀")
  }
}

import AppKit
import ApplicationServices
import DiloCapabilities
import os
import Testing
@testable import Dilo

@MainActor
struct TextInsertionServiceTests {
  /// La app de destino leyendo al recibir el ⌘V, que es lo que hace cualquier
  /// app al pegar. Leer `.string` dispara la promesa de Dilo.
  private func laAppLee(_ pasteboard: NSPasteboard) -> String? {
    pasteboard.string(forType: .string)
  }

  /// El servicio con lo de casi todos los tests: un reloj que avanza al
  /// dormir, una foto que nunca vence mientras el lector trabaja y el teclado
  /// libre.
  private func makeService(
    _ pasteboard: NSPasteboard,
    reloj: DeadlineClock = RelojQueAvanzaAlDormir().deadlineClock,
    readClipboardItems: (@Sendable () -> [TextInsertionService.ClipboardItemSnapshot]?)? = nil,
    snapshotTimeout: Duration = RelojQueAvanzaAlDormir.plazoQueNoVence,
    isProcessRunning: @escaping @MainActor (pid_t) -> Bool = { _ in true },
    isTargetFocused: @escaping @MainActor (TextInsertionService.Target) -> Bool = { _ in true },
    teclado: LecturasDelTeclado = .libre,
    pegar: @escaping @MainActor (CanalDelAtajo) -> Bool
  ) -> TextInsertionService {
    TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: readClipboardItems ?? makeClipboardReader(for: pasteboard),
      snapshotTimeout: snapshotTimeout,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: isProcessRunning,
      isTargetFocused: isTargetFocused,
      teclado: teclado,
      postPasteShortcut: pegar,
      clock: reloj
    ))
  }

  // El camino feliz: la promesa, el acuse y la devolución.

  /// La app lee después del ⌘V: eso confirma el pegado, y lo que había
  /// vuelve después de la gracia.
  @Test func elAcuseConfirmaYDevuelveLoQueHabia() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var textAvailableWhileTargetReads: String?
    let service = makeService(pasteboard) { _ in
      textAvailableWhileTargetReads = self.laAppLee(pasteboard)
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())
    #expect(outcome == .pegado(.lectura))
    #expect(textAvailableWhileTargetReads == "dictated text")

    await service.tareaDeDevolucion?.value
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
    #expect(service.pegadoPendiente == nil)
  }

  /// Verifies snapshot restoration preserves ordered multi-type item payloads.
  @Test func fastSnapshotRestoresEveryClipboardTypeInOrder() async {
    let pasteboard = makePasteboard(con: nil)
    let customType = NSPasteboard.PasteboardType(
      "cl.espaciodigital.dilo.tests.custom-data"
    )
    let previousString = "previous clipboard"
    let previousStringData = Data(previousString.utf8)
    let previousCustomData = Data([0x00, 0x2A, 0x7F, 0xFF])
    let previousItem = NSPasteboardItem()
    previousItem.setData(previousStringData, forType: .string)
    previousItem.setData(previousCustomData, forType: customType)
    pasteboard.writeObjects([previousItem])
    var textAvailableWhileTargetReads: String?

    let service = makeService(pasteboard) { _ in
      textAvailableWhileTargetReads = self.laAppLee(pasteboard)
      return true
    }
    let outcome = await service.entregar("dictated text", a: makeTarget())
    await service.tareaDeDevolucion?.value

    let restoredItem = pasteboard.pasteboardItems?.first
    #expect(outcome == .pegado(.lectura))
    #expect(textAvailableWhileTargetReads == "dictated text")
    #expect(pasteboard.pasteboardItems?.count == 1)
    #expect(restoredItem?.types == [.string, customType])
    #expect(restoredItem?.data(forType: .string) == previousStringData)
    #expect(restoredItem?.data(forType: customType) == previousCustomData)
  }

  /// Verifies a confirmed empty clipboard restores to empty after the paste.
  @Test func fastEmptySnapshotRestoresClipboardToEmpty() async {
    let pasteboard = makePasteboard(con: nil)
    var textAvailableWhileTargetReads: String?
    let service = makeService(pasteboard) { _ in
      textAvailableWhileTargetReads = self.laAppLee(pasteboard)
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())
    await service.tareaDeDevolucion?.value

    #expect(outcome == .pegado(.lectura))
    #expect(textAvailableWhileTargetReads == "dictated text")
    #expect((pasteboard.pasteboardItems ?? []).isEmpty)
  }

  /// Sin acuse no se sabe si entró: el dictado se queda en el portapapeles
  /// lo que dura la tarjeta, para pegarlo a mano, y recién ahí vuelve lo de
  /// la persona.
  @Test func sinLecturaElDictadoSeQuedaMientrasDuraLaTarjeta() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let reloj = RelojQueAvanzaAlDormir()
    let service = makeService(pasteboard, reloj: reloj.deadlineClock) { _ in true }

    let outcome = await service.entregar("dictated text", a: makeTarget())
    #expect(outcome == .pegadoSinConfirmar)
    #expect(pasteboard.types?.contains(TextInsertionService.tipoDeLaMarca) == true)
    let alContestar = reloj.ahora

    await service.tareaDeDevolucion?.value
    #expect(reloj.ahora - alContestar >= TiemposDePegado.deFabrica.esperaSinSenal)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Si la persona pega a mano mientras la tarjeta está arriba, lo suyo
  /// vuelve medio segundo después y no a los ocho.
  @Test func pegarAManoDuranteLaTarjetaAdelantaLaDevolucion() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let reloj = RelojQueAvanzaAlDormir()
    let service = makeService(pasteboard, reloj: reloj.deadlineClock) { _ in true }

    #expect(await service.entregar("dictated text", a: makeTarget()) == .pegadoSinConfirmar)
    let alContestar = reloj.ahora
    #expect(laAppLee(pasteboard) == "dictated text")

    await service.tareaDeDevolucion?.value
    #expect(reloj.ahora - alContestar < .seconds(2))
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Una lectura antes del ⌘V es de un gestor de portapapeles, no de la app
  /// de destino: no confirma. Y como AppKit guarda lo entregado en caché, la
  /// lectura del pegado de verdad ya no llega: queda sin confirmar.
  @Test func unaLecturaAntesDelAtajoNoCuenta() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var focusChecks = 0
    let service = makeService(
      pasteboard,
      isTargetFocused: { _ in
        focusChecks += 1
        // La segunda mirada es la de justo antes del ⌘V, con la promesa ya
        // escrita: un gestor que lee acá se adelanta al pegado.
        if focusChecks == 2 { _ = pasteboard.string(forType: .string) }
        return true
      },
      pegar: { _ in
        _ = self.laAppLee(pasteboard)
        return true
      }
    )

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(focusChecks == 2)
    #expect(outcome == .pegadoSinConfirmar)
  }

  /// Verifies an external write after staging is not overwritten by restore.
  @Test func clipboardChangeDuringPasteIsNeverOverwritten() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let service = makeService(pasteboard) { _ in
      pasteboard.clearContents()
      pasteboard.setString("new clipboard", forType: .string)
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())
    await service.tareaDeDevolucion?.value

    #expect(outcome == .pegadoSinConfirmar)
    #expect(service.pegadoPendiente == nil)
    #expect(pasteboard.string(forType: .string) == "new clipboard")
  }

  /// Dos dictados seguidos: el segundo hereda la foto del primero, que
  /// todavía no volvía. Si la tomara de nuevo, guardaría el primer dictado
  /// como si fuera de la persona.
  @Test func dosDictadosSeguidosDevuelvenLoDeAntesDeAmbos() async {
    let pasteboard = makePasteboard(con: "lo tuyo")
    var leer = false
    var pegados: [String?] = []
    let service = makeService(pasteboard) { _ in
      pegados.append(leer ? self.laAppLee(pasteboard) : nil)
      return true
    }

    #expect(await service.entregar("primero", a: makeTarget()) == .pegadoSinConfirmar)
    leer = true
    #expect(await service.entregar("segundo", a: makeTarget()) == .pegado(.lectura))
    await service.tareaDeDevolucion?.value

    #expect(pegados == [nil, "segundo"])
    #expect(pasteboard.string(forType: .string) == "lo tuyo")
  }

  /// The paste write is marked as machine-generated and short-lived, so a
  /// clipboard manager honouring nspasteboard.com's types keeps every
  /// dictated phrase out of its history; and it carries Dilo's own mark.
  @Test func theStagedPasteIsMarkedTransient() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var typesWhileStaged: [String] = []
    let service = makeService(pasteboard) { _ in
      // Read while Dilo's text is on the pasteboard, which is the only
      // moment a clipboard manager would see it.
      typesWhileStaged = pasteboard.types?.map(\.rawValue) ?? []
      _ = self.laAppLee(pasteboard)
      return true
    }

    let outcome = await service.entregar("dictated words", a: makeTarget(), segun: .insert)
    await service.tareaDeDevolucion?.value

    #expect(outcome == .pegado(.lectura))
    #expect(typesWhileStaged.contains("org.nspasteboard.TransientType"))
    #expect(typesWhileStaged.contains("org.nspasteboard.AutoGeneratedType"))
    #expect(typesWhileStaged.contains(TextInsertionService.tipoDeLaMarca.rawValue))
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Cada pegado lleva su propia marca: dos dictados iguales no se
  /// confunden entre sí.
  @Test func cadaPegadoLlevaSuMarca() async {
    let pasteboard = makePasteboard(con: nil)
    var marcas: [String?] = []
    let service = makeService(pasteboard) { _ in
      marcas.append(pasteboard.string(forType: TextInsertionService.tipoDeLaMarca))
      return true
    }

    _ = await service.entregar("igual", a: makeTarget())
    _ = await service.entregar("igual", a: makeTarget())

    #expect(marcas.count == 2)
    #expect(marcas.allSatisfy { $0 != nil })
    #expect(marcas.first != marcas.last)
  }

  // Lo que no se pega: retenido, sin perder nada.

  /// Verifies a completed nil read keeps the dictation off the clipboard.
  @Test func failedClipboardReadIsRetainedWithoutPostingPaste() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPaste = false
    let service = makeService(pasteboard, readClipboardItems: { nil }) { _ in
      postedPaste = true
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.sinRespaldo))
    #expect(!postedPaste)
    // Lo de la persona no se pudo guardar, así que no se toca: el dictado
    // queda en la tarjeta.
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Verifies a missing advertised payload rejects the partial snapshot.
  @Test func missingClipboardRepresentationIsRetained() async {
    let pasteboard = makePasteboard(con: nil)
    let missingType = NSPasteboard.PasteboardType(
      "cl.espaciodigital.dilo.tests.missing-data"
    )
    let provider = MissingPasteboardDataProvider()
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [missingType])
    pasteboard.writeObjects([item])
    var postedPaste = false

    let service = makeService(pasteboard) { _ in
      postedPaste = true
      return true
    }
    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.sinRespaldo))
    #expect(!postedPaste)
    #expect(pasteboard.types == [missingType])
  }

  /// Verifies a count change after acquisition prevents any staging or paste.
  @Test func clipboardChangeAfterAcceptedSnapshotPreventsStaging() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var focusCheckCount = 0
    var postedPaste = false
    let service = makeService(
      pasteboard,
      isTargetFocused: { _ in
        focusCheckCount += 1
        if focusCheckCount == 1 {
          pasteboard.clearContents()
          pasteboard.setString("new clipboard", forType: .string)
        }
        return true
      },
      pegar: { _ in
        postedPaste = true
        return true
      }
    )

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.portapapelesAjeno))
    #expect(focusCheckCount == 1)
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "new clipboard")
  }

  /// Un atajo que no se pudo crear deja el dictado para pegarlo a mano, y lo
  /// de la persona vuelve cuando la tarjeta se va.
  @Test func failedPasteShortcutLeavesTheDictationForAManualPaste() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var attemptedPaste = false
    let service = makeService(pasteboard) { _ in
      attemptedPaste = true
      return false
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.sinAtajo))
    #expect(attemptedPaste)
    #expect(pasteboard.string(forType: .string) == "dictated text")
    await service.tareaDeDevolucion?.value
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Verifies an invalid initial target receives no paste and keeps the words.
  @Test func changedTargetReceivesNoPasteEvent() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPaste = false
    let service = makeService(pasteboard, isTargetFocused: { _ in false }) { _ in
      postedPaste = true
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.focoCambio))
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "dictated text")
    await service.tareaDeDevolucion?.value
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// La última mirada, justo antes del ⌘V, también manda: el foco que se fue
  /// después de escribir la promesa no recibe el pegado.
  @Test func targetChangedRightBeforeThePasteReceivesNothing() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var focusCheckCount = 0
    var postedPaste = false
    let service = makeService(
      pasteboard,
      isTargetFocused: { _ in
        focusCheckCount += 1
        return focusCheckCount == 1
      },
      pegar: { _ in
        postedPaste = true
        return true
      }
    )

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.focoCambio))
    #expect(focusCheckCount == 2)
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// Verifies an exited frontmost target keeps the words for a manual paste.
  @Test func missingFocusedElementCapturesFrontmostApplication() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let application = NSRunningApplication.current
    var checkedProcessIdentifier: pid_t?
    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: makeClipboardReader(for: pasteboard),
      snapshotTimeout: RelojQueAvanzaAlDormir.plazoQueNoVence,
      focusedElement: { nil },
      frontmostApplication: { application },
      isProcessRunning: { processIdentifier in
        checkedProcessIdentifier = processIdentifier
        return false
      },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: { _ in true },
      clock: RelojQueAvanzaAlDormir().deadlineClock
    ))

    let target = service.captureFocusedTarget()
    #expect(target != nil)
    #expect(target?.bundleID == application.bundleIdentifier)
    let outcome = await service.entregar("dictated text", a: target)
    #expect(checkedProcessIdentifier == application.processIdentifier)
    #expect(outcome == .retenido(.focoCambio))
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// Con ⌥ sostenida más de dos segundos no se pega: ⌥⌘V es otro comando.
  /// El dictado se queda para pegarlo a mano.
  @Test func conTeclasSostenidasNoPega() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPaste = false
    let sostenida = LecturasDelTeclado(entradaSegura: { false }, modificadores: { .maskAlternate })
    let service = makeService(pasteboard, teclado: sostenida) { _ in
      postedPaste = true
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.teclasSostenidas))
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// El bit de fn que deja colgado un gatillo F19 no detiene el ⌘V: fn no
  /// cambia lo que pega. Antes cada dictado así terminaba en la tarjeta.
  @Test func elBitDeFnDeUnGatilloF19NoImpidePegar() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPaste = false
    let bitDeF19 = LecturasDelTeclado(
      entradaSegura: { false }, modificadores: { CGEventFlags(rawValue: 0x2080_0000) })
    let service = makeService(pasteboard, teclado: bitDeF19) { _ in
      postedPaste = true
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(postedPaste)
    #expect(outcome != .retenido(.teclasSostenidas))
  }

  /// La entrada segura encendida es una contraseña con el foco: no hay ⌘V.
  @Test func conEntradaSeguraNoPega() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPaste = false
    let segura = LecturasDelTeclado(entradaSegura: { true }, modificadores: { [] })
    let service = makeService(pasteboard, teclado: segura) { _ in
      postedPaste = true
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.entradaSegura))
    #expect(!postedPaste)
  }

  // La foto del portapapeles.

  /// Una imagen enorme o cientos de ítems no se leen enteros para pegar una
  /// frase: se cuentan antes de leer un byte y no se tocan.
  @Test func laFotoRespetaLosTopes() {
    let pasteboard = makePasteboard(con: nil)
    let items = (0..<3).map { indice -> NSPasteboardItem in
      let item = NSPasteboardItem()
      item.setString("ítem \(indice)", forType: .string)
      return item
    }
    pasteboard.writeObjects(items)

    var pocosItems = TextInsertionService.TopesDeLaFoto()
    pocosItems.items = 2
    var pocosBytes = TextInsertionService.TopesDeLaFoto()
    pocosBytes.bytes = 10
    var pocosTipos = TextInsertionService.TopesDeLaFoto()
    pocosTipos.tipos = 2

    if case .excedida = TextInsertionService.foto(de: pasteboard, topes: pocosItems) {} else {
      Issue.record("tres ítems con tope de dos tenían que exceder")
    }
    if case .excedida = TextInsertionService.foto(de: pasteboard, topes: pocosBytes) {} else {
      Issue.record("veinte bytes con tope de diez tenían que exceder")
    }
    if case .excedida = TextInsertionService.foto(de: pasteboard, topes: pocosTipos) {} else {
      Issue.record("tres tipos con tope de dos tenían que exceder")
    }
    #expect(TextInsertionService.foto(de: pasteboard).items?.count == 3)
  }

  @Test func unaFotoIncompletaNoSeDevuelveAMedias() {
    let pasteboard = makePasteboard(con: nil)
    let item = NSPasteboardItem()
    item.setDataProvider(MissingPasteboardDataProvider(), forTypes: [.string])
    pasteboard.writeObjects([item])

    #expect(TextInsertionService.foto(de: pasteboard).items == nil)
  }

  // Al cerrar Dilo.

  /// Nadie leyó: el dictado se queda como texto de verdad, porque una
  /// promesa cuyo dueño murió no entrega nada.
  @Test func alCerrarSinLecturaElDictadoSeVuelveTexto() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let service = makeService(pasteboard) { _ in true }
    #expect(await service.entregar("dictated text", a: makeTarget()) == .pegadoSinConfirmar)

    service.alCerrar()

    #expect(service.pegadoPendiente == nil)
    #expect(pasteboard.types?.contains(TextInsertionService.tipoDeLaMarca) == false)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// La app ya lo tiene: al cerrar vuelve lo de la persona.
  @Test func alCerrarTrasLaLecturaVuelveLoDeLaPersona() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let service = makeService(pasteboard) { _ in
      _ = self.laAppLee(pasteboard)
      return true
    }
    #expect(await service.entregar("dictated text", a: makeTarget()) == .pegado(.lectura))

    service.alCerrar()

    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  // Los destinos de Ajustes.

  /// Verifies clipboard-only delivery replaces the clipboard without pasting.
  @Test func clipboardOnlyReplacesClipboardWithoutPosting() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPaste = false
    let service = makeService(pasteboard) { _ in
      postedPaste = true
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget(), segun: .clipboardOnly)

    #expect(outcome == .copiado)
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// Verifies clipboard-only delivery never consults the target guards.
  @Test func clipboardOnlySkipsEveryTargetGuard() async {
    let pasteboard = makePasteboard(con: nil)
    let service = makeService(
      pasteboard,
      isProcessRunning: { _ in false },
      isTargetFocused: { _ in false },
      pegar: { _ in true }
    )

    let outcome = await service.entregar("dictated text", a: makeTarget(), segun: .clipboardOnly)

    #expect(outcome == .copiado)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// Verifies clipboard-only delivery succeeds without any captured target.
  @Test func clipboardOnlyDeliversWithoutTarget() async {
    let pasteboard = makePasteboard(con: nil)
    let service = makeService(pasteboard) { _ in true }

    let outcome = await service.entregar("dictated text", a: nil, segun: .clipboardOnly)

    #expect(outcome == .copiado)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// Copiar al portapapeles es una copia cualquiera: un gestor de
  /// portapapeles la guarda como cualquier otra.
  @Test func textMeantToStayIsNotMarkedTransient() async {
    let pasteboard = makePasteboard(con: nil)
    let service = makeService(pasteboard) { _ in true }

    _ = await service.entregar("dictated words", a: makeTarget(), segun: .clipboardOnly)

    let types = pasteboard.types?.map(\.rawValue) ?? []
    #expect(!types.contains("org.nspasteboard.TransientType"))
    #expect(!types.contains(TextInsertionService.tipoDeLaMarca.rawValue))
    #expect(pasteboard.string(forType: .string) == "dictated words")
  }

  /// Verifies insert-and-copy pastes once and leaves the text on the clipboard.
  @Test func bothPastesAndLeavesTextOnClipboard() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPasteCount = 0
    var textAvailableWhileTargetReads: String?
    let service = makeService(pasteboard) { _ in
      postedPasteCount += 1
      textAvailableWhileTargetReads = self.laAppLee(pasteboard)
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget(), segun: .both)

    #expect(outcome == .pegado(.lectura))
    #expect(postedPasteCount == 1)
    #expect(textAvailableWhileTargetReads == "dictated text")
    #expect(service.pegadoPendiente == nil)
    let types = pasteboard.types?.map(\.rawValue) ?? []
    #expect(!types.contains("org.nspasteboard.TransientType"))
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// «Pegar y copiar» sin foco no pega, pero deja el dictado copiado: es lo
  /// que la persona pidió de todos modos.
  @Test func bothWithUnfocusedTargetKeepsTheCopy() async {
    let pasteboard = makePasteboard(con: nil)
    var postedPaste = false
    let service = makeService(pasteboard, isTargetFocused: { _ in false }) { _ in
      postedPaste = true
      return true
    }

    let outcome = await service.entregar("dictated text", a: makeTarget(), segun: .both)

    #expect(outcome == .retenido(.focoCambio))
    #expect(!postedPaste)
    #expect(service.pegadoPendiente == nil)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// Verifies a failed paste shortcut leaves the text as a plain copy.
  @Test func bothWithFailedPasteShortcutKeepsStagedText() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let service = makeService(pasteboard) { _ in false }

    let outcome = await service.entregar("dictated text", a: makeTarget(), segun: .both)

    #expect(outcome == .retenido(.sinAtajo))
    #expect(service.pegadoPendiente == nil)
    #expect(pasteboard.string(forType: .string) == "dictated text")
  }

  /// Verifies insert-and-copy refuses to write while a read owns the lease.
  @Test func bothWithHeldReadLeaseTouchesNothing() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    var postedPaste = false
    let service = makeService(pasteboard) { _ in
      postedPaste = true
      return true
    }
    service.clipboardReadLease.withLock { $0 = true }
    let outcome = await service.entregar("dictated text", a: makeTarget(), segun: .both)
    service.clipboardReadLease.withLock { $0 = false }

    #expect(outcome == .retenido(.portapapelesAjeno))
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Verifies empty text completes as a no-op before destination handling.
  @Test func emptyTextWithClipboardOnlyLeavesClipboardUntouched() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let service = makeService(pasteboard) { _ in true }

    let outcome = await service.entregar("", a: makeTarget(), segun: .clipboardOnly)

    #expect(outcome == .nadaQueEntregar)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Leer una selección mientras un dictado espera volver: primero vuelve lo
  /// de la persona, y la copia no fotografía la promesa como si fuera suya.
  @Test func copiarUnaSeleccionConUnDictadoPendienteDevuelveAntes() async {
    let pasteboard = makePasteboard(con: "previous clipboard")
    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: makeClipboardReader(for: pasteboard),
      snapshotTimeout: RelojQueAvanzaAlDormir.plazoQueNoVence,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: { _ in true },
      postCopyShortcut: {
        pasteboard.clearContents()
        pasteboard.setString("the selected sentence", forType: .string)
        return true
      },
      clock: RelojQueAvanzaAlDormir().deadlineClock
    ))
    #expect(await service.entregar("dictated text", a: makeTarget()) == .pegadoSinConfirmar)

    let copied = await service.copySelection()

    #expect(copied == "the selected sentence")
    #expect(service.pegadoPendiente == nil)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  // La foto bajo presión: lecturas lentas, cambios a mitad y plazos.

  /// Verifies a healthy delayed read still pastes and restores within its budget.
  ///
  /// The delay is in driven-clock time: the read is held open across a 100ms
  /// advance of a 150ms budget, so what is asserted is that a slow but
  /// in-budget read pastes, not that this machine got there in time.
  @Test nonisolated func delayedSnapshotWithinDeadlinePastesAndRestores() async {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name(
        "TextInsertionServiceTests-\(UUID().uuidString)"
      )
    )
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)
    let clock = DrivenClock()
    let readerStarted = DispatchSemaphore(value: 0)
    let allowReadToFinish = DispatchSemaphore(value: 0)
    let pastedText = OSAllocatedUnfairLock<String?>(initialState: nil)
    defer {
      allowReadToFinish.signal()
    }

    nonisolated(unsafe) let observedPasteboard = pasteboard
    let service = await MainActor.run {
      TextInsertionService(dependencies: .init(
        pasteboard: observedPasteboard,
        readClipboardItems: {
          readerStarted.signal()
          _ = allowReadToFinish.wait(timeout: .now() + 10)
          return TextInsertionService.snapshot(of: observedPasteboard)
        },
        snapshotTimeout: .milliseconds(150),
        focusedElement: { nil },
        frontmostApplication: { nil },
        isProcessRunning: { _ in true },
        isTargetFocused: { _ in true },
        teclado: .libre,
        postPasteShortcut: { _ in
          pastedText.withLock { $0 = observedPasteboard.string(forType: .string) }
          return true
        },
        clock: clock.deadlineClock
      ))
    }

    let insertion = Task { @MainActor in
      await service.entregar("dictated text", a: makeTarget())
    }
    #expect(wait(for: readerStarted, timeout: .now() + 10) == .success)
    clock.advance(by: .milliseconds(100))
    allowReadToFinish.signal()

    let outcome = await insertion.value
    #expect(outcome == .pegado(.lectura))
    #expect(pastedText.withLock { $0 } == "dictated text")
    await drenarLaDevolucion(de: service, con: clock)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Verifies one changed read accepts and restores the stable second snapshot.
  @Test func oneClipboardChangeUsesStableSecondSnapshot() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("first clipboard", forType: .string)
    let readCount = OSAllocatedUnfairLock(initialState: 0)
    var pastedText: String?

    nonisolated(unsafe) let backgroundPasteboard = pasteboard
    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: {
        let attempt = readCount.withLock { count in
          count += 1
          return count
        }
        let snapshot = TextInsertionService.snapshot(of: backgroundPasteboard)
        if attempt == 1 {
          backgroundPasteboard.clearContents()
          backgroundPasteboard.setString("second clipboard", forType: .string)
        }
        return snapshot
      },
      snapshotTimeout: RelojQueAvanzaAlDormir.plazoQueNoVence,
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: { _ in
        pastedText = pasteboard.string(forType: .string)
        return true
      },
      clock: RelojQueAvanzaAlDormir().deadlineClock
    ))

    let outcome = await service.entregar("dictated text", a: makeTarget())
    await service.tareaDeDevolucion?.value

    #expect(outcome == .pegado(.lectura))
    #expect(readCount.withLock { $0 } == 2)
    #expect(pastedText == "dictated text")
    #expect(pasteboard.string(forType: .string) == "second clipboard")
  }

  /// Verifies two unstable reads leave the latest clipboard value untouched.
  @Test func changesDuringBothSnapshotReadsLeaveLatestClipboardUntouched() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("first clipboard", forType: .string)
    let readCount = OSAllocatedUnfairLock(initialState: 0)
    var postedPaste = false

    nonisolated(unsafe) let backgroundPasteboard = pasteboard
    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: {
        let attempt = readCount.withLock { count in
          count += 1
          return count
        }
        let snapshot = TextInsertionService.snapshot(of: backgroundPasteboard)
        backgroundPasteboard.clearContents()
        backgroundPasteboard.setString(
          attempt == 1 ? "second clipboard" : "third clipboard",
          forType: .string
        )
        return snapshot
      },
      snapshotTimeout: .milliseconds(100),
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: { _ in
        postedPaste = true
        return true
      },
      clock: makeHeldClock()
    ))

    let outcome = await service.entregar("dictated text", a: makeTarget())

    #expect(outcome == .retenido(.sinRespaldo))
    #expect(readCount.withLock { $0 } == 2)
    #expect(!postedPaste)
    #expect(pasteboard.string(forType: .string) == "third clipboard")
  }

  /// Verifies a timed-out result stays unavailable after its reader releases the lease.
  @Test nonisolated func timeoutRemainsUnavailableAfterReaderReturnsBeforeRouting() async {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name(
        "TextInsertionServiceTests-\(UUID().uuidString)"
      )
    )
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    // An event wait, not a time bound: the budget is only spent when the run
    // is already broken, so it can be generous instead of measuring how fast
    // a loaded runner schedules the reader (#82).
    let eventWaitBudget = DispatchTimeInterval.seconds(10)
    let blockingWaitBudget = DispatchTimeInterval.seconds(10)
    let snapshotTimeout = Duration.milliseconds(25)
    let clock = DrivenClock()
    let readerStartedForBlocker = DispatchSemaphore(value: 0)
    let readerStartedForTest = DispatchSemaphore(value: 0)
    let allowReaderToFinish = DispatchSemaphore(value: 0)
    let mainActorBlocked = DispatchSemaphore(value: 0)
    let allowMainActorToResume = DispatchSemaphore(value: 0)
    let blockerFinished = DispatchSemaphore(value: 0)
    let blockerScheduled = OSAllocatedUnfairLock(initialState: false)
    let blockerObservedReaderStart = OSAllocatedUnfairLock(initialState: false)
    let blockerReleasedByTest = OSAllocatedUnfairLock(initialState: false)
    let readerReleasedByTest = OSAllocatedUnfairLock(initialState: false)
    let insertionCompleted = OSAllocatedUnfairLock(initialState: false)
    let postedPaste = OSAllocatedUnfairLock(initialState: false)
    defer {
      allowReaderToFinish.signal()
      allowMainActorToResume.signal()
    }

    nonisolated(unsafe) let observedPasteboard = pasteboard
    let service = await MainActor.run {
      TextInsertionService(dependencies: .init(
        pasteboard: observedPasteboard,
        readClipboardItems: {
          // El bloqueo del actor principal se agenda desde el lector y no
          // desde la mirada al foco: la entrega fotografía el portapapeles
          // antes de mirar el foco.
          let shouldScheduleBlocker = blockerScheduled.withLock { scheduled in
            guard !scheduled else { return false }
            scheduled = true
            return true
          }
          if shouldScheduleBlocker {
            DispatchQueue.main.async {
              let readerStartResult = readerStartedForBlocker.wait(
                timeout: .now() + eventWaitBudget
              )
              blockerObservedReaderStart.withLock {
                $0 = readerStartResult == .success
              }
              mainActorBlocked.signal()

              if readerStartResult == .success {
                let releaseResult = allowMainActorToResume.wait(
                  timeout: .now() + blockingWaitBudget
                )
                blockerReleasedByTest.withLock {
                  $0 = releaseResult == .success
                }
              }
              blockerFinished.signal()
            }
          }
          readerStartedForBlocker.signal()
          readerStartedForTest.signal()
          let releaseResult = allowReaderToFinish.wait(
            timeout: .now() + blockingWaitBudget
          )
          readerReleasedByTest.withLock {
            $0 = releaseResult == .success
          }
          guard releaseResult == .success else { return nil }
          return TextInsertionService.snapshot(of: observedPasteboard)
        },
        snapshotTimeout: snapshotTimeout,
        focusedElement: { nil },
        frontmostApplication: { nil },
        isProcessRunning: { _ in true },
        isTargetFocused: { _ in true },
        teclado: .libre,
        postPasteShortcut: { _ in
          postedPaste.withLock { $0 = true }
          return true
        },
        clock: clock.deadlineClock
      ))
    }
    let clipboardReaderQueue = await MainActor.run {
      service.clipboardReaderQueue
    }

    let insertion = Task { @MainActor in
      let outcome = await service.entregar("dictated text", a: makeTarget())
      insertionCompleted.withLock { $0 = true }
      return outcome
    }
    #expect(
      wait(
        for: readerStartedForTest,
        timeout: .now() + eventWaitBudget
      ) == .success
    )
    #expect(
      wait(for: mainActorBlocked, timeout: .now() + eventWaitBudget) == .success
    )
    #expect(blockerObservedReaderStart.withLock { $0 })
    #expect(!insertionCompleted.withLock { $0 })

    // Drive the injected clock past the snapshot budget instead of sleeping
    // it away: the timeout is forced by the test, not raced against the
    // runner (#82).
    await clock.waitForSleeper()
    clock.advance(by: snapshotTimeout)

    allowReaderToFinish.signal()
    let readerQueueDrained = DispatchSemaphore(value: 0)
    clipboardReaderQueue.async(flags: .barrier) {
      readerQueueDrained.signal()
    }
    #expect(
      wait(for: readerQueueDrained, timeout: .now() + eventWaitBudget)
        == .success
    )
    #expect(readerReleasedByTest.withLock { $0 })
    #expect(!insertionCompleted.withLock { $0 })

    allowMainActorToResume.signal()
    #expect(
      wait(for: blockerFinished, timeout: .now() + eventWaitBudget) == .success
    )
    #expect(blockerReleasedByTest.withLock { $0 })

    let outcome = await insertion.value
    #expect(outcome == .retenido(.sinRespaldo))
    #expect(!postedPaste.withLock { $0 })
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Verifies a live read lease skips concurrent work and permits later recovery.
  @Test nonisolated func activeReadSkipsLaterInsertionImmediatelyAndRecovers() async {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name(
        "TextInsertionServiceTests-\(UUID().uuidString)"
      )
    )
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let clock = DrivenClock()
    let readerStarted = DispatchSemaphore(value: 0)
    let allowFirstReadToFinish = DispatchSemaphore(value: 0)
    let readerReturned = DispatchSemaphore(value: 0)
    let readerReleaseState = OSAllocatedUnfairLock(initialState: false)
    let readCount = OSAllocatedUnfairLock(initialState: 0)
    let postedPasteCount = OSAllocatedUnfairLock(initialState: 0)
    let pastedTexts = OSAllocatedUnfairLock(initialState: [String]())
    let releaseReader: @Sendable () -> Void = {
      let shouldSignal = readerReleaseState.withLock { wasReleased in
        if wasReleased {
          return false
        }
        wasReleased = true
        return true
      }
      if shouldSignal {
        allowFirstReadToFinish.signal()
      }
    }
    defer {
      releaseReader()
    }

    nonisolated(unsafe) let observedPasteboard = pasteboard
    let service = await MainActor.run {
      TextInsertionService(dependencies: .init(
        pasteboard: observedPasteboard,
        readClipboardItems: {
          let attempt = readCount.withLock { count in
            count += 1
            return count
          }
          if attempt == 1 {
            readerStarted.signal()
            allowFirstReadToFinish.wait()
          }
          let snapshot = TextInsertionService.snapshot(of: observedPasteboard)
          if attempt == 1 {
            readerReturned.signal()
          }
          return snapshot
        },
        snapshotTimeout: .milliseconds(100),
        focusedElement: { nil },
        frontmostApplication: { nil },
        isProcessRunning: { _ in true },
        isTargetFocused: { _ in true },
        teclado: .libre,
        postPasteShortcut: { _ in
          postedPasteCount.withLock { $0 += 1 }
          if let text = observedPasteboard.string(forType: .string) {
            pastedTexts.withLock { $0.append(text) }
          }
          return true
        },
        clock: clock.deadlineClock
      ))
    }
    let insert: @MainActor @Sendable (String) async
      -> ResultadoDeEntrega = { text in
      await service.entregar(text, a: makeTarget())
    }

    let firstInsertion = Task {
      await insert("first dictated text")
    }
    // An event wait, not a time bound: the budget is only spent when the run
    // is already broken, so it can be generous instead of measuring how fast
    // a loaded runner schedules the reader (#82).
    #expect(wait(for: readerStarted, timeout: .now() + 10) == .success)

    let secondOutcome = await insert("second dictated text")

    #expect(secondOutcome == .retenido(.sinRespaldo))
    // The busy skip never consults the clock, and only this test advances it,
    // so coming back at all proves the skip did not queue behind the held-open
    // read: an implementation that waited for it would hang here forever. The
    // wall-clock ceiling this replaces measured the runner's load instead,
    // which failed this test on CI at 50ms.
    #expect(readCount.withLock { $0 } == 1)
    #expect(postedPasteCount.withLock { $0 } == 0)
    #expect(pastedTexts.withLock { $0 }.isEmpty)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")

    // The held-open read is meant to outlive its budget: arm the deadline and
    // drive the clock past it, so the first insertion's timeout is forced
    // rather than waited for.
    await clock.waitForSleeper()
    clock.advance(by: .milliseconds(100))
    let firstOutcome = await firstInsertion.value
    #expect(firstOutcome == .retenido(.sinRespaldo))
    #expect(readCount.withLock { $0 } == 1)
    #expect(postedPasteCount.withLock { $0 } == 0)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")

    releaseReader()
    #expect(wait(for: readerReturned, timeout: .now() + 10) == .success)
    // The reader signals from inside the read closure, so the lease is still
    // held for a moment after it. Retrying rather than sleeping a fixed 10ms
    // keeps this from depending on how fast the machine gets there; a refused
    // attempt reads nothing and posts nothing, so the counts below still only
    // count the recovery.
    var recoveryOutcome = ResultadoDeEntrega.retenido(.sinRespaldo)
    for _ in 0..<200 where recoveryOutcome == .retenido(.sinRespaldo) {
      recoveryOutcome = await insert("third dictated text")
      if recoveryOutcome == .retenido(.sinRespaldo) {
        try? await Task.sleep(for: .milliseconds(10))
      }
    }

    #expect(recoveryOutcome == .pegado(.lectura))
    await drenarLaDevolucion(de: service, con: clock)
    #expect(readCount.withLock { $0 } == 2)
    #expect(postedPasteCount.withLock { $0 } == 1)
    #expect(pastedTexts.withLock { $0 } == ["third dictated text"])
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// The deadline is honoured, not raced: with the read held open, driving
  /// the clock past the snapshot budget is the only thing that times the
  /// acquisition out. No real time passes here, so a starved runner cannot
  /// change the answer either way.
  @Test nonisolated func drivingTheClockPastTheSnapshotBudgetTimesTheReadOut() async {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name(
        "TextInsertionServiceTests-\(UUID().uuidString)"
      )
    )
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)
    let clock = DrivenClock()
    let readerStarted = DispatchSemaphore(value: 0)
    let allowReadToFinish = DispatchSemaphore(value: 0)
    let postedPaste = OSAllocatedUnfairLock(initialState: false)
    defer {
      allowReadToFinish.signal()
    }

    nonisolated(unsafe) let observedPasteboard = pasteboard
    let service = await MainActor.run {
      TextInsertionService(dependencies: .init(
        pasteboard: observedPasteboard,
        readClipboardItems: {
          readerStarted.signal()
          _ = allowReadToFinish.wait(timeout: .now() + 10)
          return TextInsertionService.snapshot(of: observedPasteboard)
        },
        snapshotTimeout: .milliseconds(100),
        focusedElement: { nil },
        frontmostApplication: { nil },
        isProcessRunning: { _ in true },
        isTargetFocused: { _ in true },
        teclado: .libre,
        postPasteShortcut: { _ in
          postedPaste.withLock { $0 = true }
          return true
        },
        clock: clock.deadlineClock
      ))
    }

    let insertion = Task { @MainActor in
      await service.entregar("dictated text", a: makeTarget())
    }
    #expect(wait(for: readerStarted, timeout: .now() + 10) == .success)
    await clock.waitForSleeper()
    clock.advance(by: .milliseconds(100))

    let outcome = await insertion.value
    #expect(outcome == .retenido(.sinRespaldo))
    #expect(!postedPaste.withLock { $0 })
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Copying is how a selection is read where Accessibility answers nothing,
  /// which is every browser. The clipboard has to come back afterwards.
  @Test func copyingASelectionReadsItAndPutsTheClipboardBack() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: makeClipboardReader(for: pasteboard),
      snapshotTimeout: .milliseconds(200),
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: { _ in true },
      // What Copy does in the focused application, which here is the selection
      // arriving on the pasteboard.
      postCopyShortcut: {
        pasteboard.clearContents()
        pasteboard.setString("the selected sentence", forType: .string)
        return true
      },
      clock: makeHeldClock()
    ))

    let copied = await service.copySelection()

    #expect(copied == "the selected sentence")
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// Nothing selected is known, not guessed: Copy that finds nothing leaves
  /// the change count alone, so the old clipboard is never read back as if it
  /// were the selection.
  @Test func copyingWithNothingSelectedReadsNothing() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)
    let clock = DrivenClock()
    let copyFired = OSAllocatedUnfairLock(initialState: false)

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: makeClipboardReader(for: pasteboard),
      snapshotTimeout: .milliseconds(200),
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: { _ in true },
      // Copy fired and nothing came of it, exactly as an empty selection does.
      postCopyShortcut: {
        copyFired.withLock { $0 = true }
        return true
      },
      copyTimeout: .milliseconds(60),
      clock: clock.deadlineClock
    ))

    // The copy deadline is driven, not waited out. Advancing only once Copy
    // has fired keeps the snapshot's own timer out of it: by then that timer
    // is cancelled, so the sleeper this wakes is the copy poll's.
    let driver = Task.detached {
      while !copyFired.withLock({ $0 }) {
        await Task.yield()
      }
      await clock.waitForSleeper()
      clock.advance(by: .milliseconds(60))
    }
    let copied = await service.copySelection()
    await driver.value

    #expect(copied == nil)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  /// A clipboard that cannot be captured cannot be put back, so the copy is
  /// never attempted.
  @Test func copyingIsRefusedWhenTheClipboardCannotBeSnapshotted() async {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)
    let didCopy = OSAllocatedUnfairLock(initialState: false)

    let service = TextInsertionService(dependencies: .init(
      pasteboard: pasteboard,
      readClipboardItems: { nil },
      snapshotTimeout: .milliseconds(200),
      focusedElement: { nil },
      frontmostApplication: { nil },
      isProcessRunning: { _ in true },
      isTargetFocused: { _ in true },
      teclado: .libre,
      postPasteShortcut: { _ in true },
      postCopyShortcut: {
        didCopy.withLock { $0 = true }
        return true
      },
      clock: makeHeldClock()
    ))

    let copied = await service.copySelection()

    #expect(copied == nil)
    #expect(didCopy.withLock { $0 } == false)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
  }

  private func makePasteboard(con texto: String? = nil) -> NSPasteboard {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("TextInsertionServiceTests-\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    if let texto { pasteboard.setString(texto, forType: .string) }
    return pasteboard
  }

  /// Waits for a test-only semaphore without invoking its no-async API from
  /// the surrounding asynchronous test body.
  ///
  /// - Parameters:
  ///   - semaphore: The synchronization point to wait for.
  ///   - timeout: The absolute deadline that bounds the test wait.
  /// - Returns: Whether the semaphore was signaled before the deadline.
  private nonisolated func wait(
    for semaphore: DispatchSemaphore,
    timeout: DispatchTime
  ) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
  }

  /// A clock nothing advances. Deadlines armed on it can never elapse, so a
  /// test that expects no timeout cannot lose one to a starved runner, which
  /// is exactly how this family flaked on CI (#82).
  private nonisolated func makeHeldClock() -> DeadlineClock {
    DrivenClock().deadlineClock
  }

  /// Builds the same optional all-or-nothing snapshot closure used in production.
  ///
  /// The closure retains the named pasteboard for background use so tests keep
  /// the production reader's isolation and lifetime semantics.
  ///
  /// - Parameter pasteboard: The test pasteboard captured by the reader.
  /// - Returns: A Sendable closure that distinguishes failure from empty state.
  private nonisolated func makeClipboardReader(
    for pasteboard: NSPasteboard
  ) -> @Sendable () -> [TextInsertionService.ClipboardItemSnapshot]? {
    // Named test pasteboards are isolated to one test, but AppKit does not
    // declare NSPasteboard Sendable for this background-capable API.
    nonisolated(unsafe) let backgroundPasteboard = pasteboard

    return {
      TextInsertionService.snapshot(of: backgroundPasteboard)
    }
  }

  private func makeTarget() -> TextInsertionService.Target {
    TextInsertionService.Target(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      isSecure: false,
      displayID: nil
    )
  }

  /// Corre la devolución pendiente hasta el final sobre un reloj que sólo
  /// avanza a mano: cada vuelta despierta la espera que haya.
  private nonisolated func drenarLaDevolucion(
    de service: TextInsertionService,
    con clock: DrivenClock
  ) async {
    guard let tarea = await MainActor.run(body: { service.tareaDeDevolucion }) else { return }
    let termino = OSAllocatedUnfairLock(initialState: false)
    let espera = Task {
      await tarea.value
      termino.withLock { $0 = true }
    }
    while !termino.withLock({ $0 }) {
      if clock.hasSleeper { clock.advance(by: .milliseconds(50)) }
      await Task.yield()
    }
    await espera.value
  }
}

/// Advertises a type while withholding its data to model a partial AppKit read.
private final class MissingPasteboardDataProvider:
  NSObject,
  NSPasteboardItemDataProvider {
  /// Deliberately supplies no value for the requested representation.
  ///
  /// - Parameters:
  ///   - pasteboard: The pasteboard requesting its promised data.
  ///   - item: The item whose advertised representation is requested.
  ///   - type: The advertised type for which this provider withholds data.
  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {}
}

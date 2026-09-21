import Foundation
import Testing
@testable import Dilo

/// Leer el historial: buscar, quedarse con el modo, y borrar una entrada sin
/// llevarse el resto del día.
struct DictationHistoryBusquedaTests {
  @Test func elModoQuedaEscritoJuntoALaApp() async throws {
    let folder = carpetaTemporal()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendar = calendarioDePrueba()
    let fecha = try #require(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 20, hour: 9, minute: 0, second: 0
    )))
    let store = DictationHistoryStore(calendar: calendar)

    try await store.record(
      "hay que hacer el deploy", from: "Ghostty", modo: "Código",
      at: fecha, in: folder
    )

    let entradas = try await store.entradas(in: folder)
    #expect(entradas.count == 1)
    #expect(entradas[0].fuente == "Ghostty")
    #expect(entradas[0].modo == "Código")
    #expect(entradas[0].texto == "hay que hacer el deploy")
  }

  /// Un dictado sin modo se escribe como se escribió siempre: el historial de
  /// alguien que viene de antes se lee igual.
  @Test func unaEntradaSinModoSigueLeyendoseIgual() async throws {
    let folder = carpetaTemporal()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("[14:03:05] Mail\nhola a todos\n\n".utf8)
      .write(to: folder.appending(path: "2026-08-17.txt"))

    let entradas = try await DictationHistoryStore().entradas(in: folder)
    #expect(entradas.count == 1)
    #expect(entradas[0].fuente == "Mail")
    #expect(entradas[0].modo == nil)
  }

  /// Una traducción son dos líneas y siguen siendo una entrada.
  @Test func unaTraduccionNoSePartEnDos() async throws {
    let folder = carpetaTemporal()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("[14:03:05] Mail\nEN: hello\nES: hola\n\n".utf8)
      .write(to: folder.appending(path: "2026-08-17.txt"))

    let entradas = try await DictationHistoryStore().entradas(in: folder)
    #expect(entradas.count == 1)
    #expect(entradas[0].texto == "EN: hello\nES: hola")
  }

  @Test func seBuscaComoSeRecuerda() async throws {
    let folder = carpetaTemporal()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendar = calendarioDePrueba()
    let store = DictationHistoryStore(calendar: calendar)
    let base = try #require(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 20, hour: 9, minute: 0, second: 0
    )))

    try await store.record("mandé la cotización", from: "Mail", modo: "Correo", at: base, in: folder)
    try await store.record(
      "hay que hacer el deploy", from: "Ghostty", modo: "Código",
      at: base.addingTimeInterval(60), in: folder
    )

    // Sin tildes y sin mayúsculas.
    #expect(try await store.buscar("COTIZACION", in: folder).count == 1)
    // También por el modo y por la app.
    #expect(try await store.buscar("código", in: folder).count == 1)
    #expect(try await store.buscar("ghostty", in: folder).count == 1)
    // Vacío es todo.
    #expect(try await store.buscar("", in: folder).count == 2)
  }

  @Test func borrarUnaEntradaDejaElRestoDelDiaEnPie() async throws {
    let folder = carpetaTemporal()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendar = calendarioDePrueba()
    let store = DictationHistoryStore(calendar: calendar)
    let base = try #require(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 20, hour: 9, minute: 0, second: 0
    )))

    try await store.record("la primera", from: "Mail", modo: "Correo", at: base, in: folder)
    try await store.record(
      "la segunda", from: "Ghostty", modo: "Código",
      at: base.addingTimeInterval(60), in: folder
    )

    let entradas = try await store.entradas(in: folder)
    let segunda = try #require(entradas.first { $0.texto == "la segunda" })
    try await store.borrar(segunda, in: folder)

    let quedan = try await store.entradas(in: folder)
    #expect(quedan.count == 1)
    #expect(quedan[0].texto == "la primera")
    #expect(quedan[0].modo == "Correo")
  }

  /// Borrar la última entrada de un día se lleva el archivo: un archivo vacío
  /// es basura en una carpeta que la persona ve en el Finder.
  @Test func elUltimoDictadoDelDiaSeLlevaElArchivo() async throws {
    let folder = carpetaTemporal()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendar = calendarioDePrueba()
    let store = DictationHistoryStore(calendar: calendar)
    let fecha = try #require(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 20, hour: 9, minute: 0, second: 0
    )))

    try await store.record("la única", at: fecha, in: folder)
    let entrada = try #require(try await store.entradas(in: folder).first)
    try await store.borrar(entrada, in: folder)

    let archivo = folder.appending(path: "2026-09-20.txt")
    #expect(!FileManager.default.fileExists(atPath: archivo.path))
  }

  @Test func lasMasNuevasPrimero() async throws {
    let folder = carpetaTemporal()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calendar = calendarioDePrueba()
    let store = DictationHistoryStore(calendar: calendar)
    let ayer = try #require(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 19, hour: 23, minute: 0, second: 0
    )))

    try await store.record("lo de ayer", at: ayer, in: folder)
    try await store.record("lo de hoy", at: ayer.addingTimeInterval(7200), in: folder)

    let entradas = try await store.entradas(in: folder)
    #expect(entradas.map(\.texto) == ["lo de hoy", "lo de ayer"])
  }

  private func carpetaTemporal() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  private func calendarioDePrueba() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    return calendar
  }
}

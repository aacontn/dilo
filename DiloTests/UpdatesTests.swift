import Foundation
import Testing
@testable import Dilo

@MainActor
struct UpdatesTests {
  /// The updater is inert until `start()`, which the composition root calls
  /// last. A preview or a test must never reach the network by constructing it.
  @Test func anUnstartedUpdaterCannotCheck() {
    let updater = SparkleUpdaterService()
    #expect(!updater.canCheckForUpdates)
    #expect(updater.availableVersion == nil)
    #expect(updater.lastCheckedAt == nil)
  }

  /// Starting the real updater against the real app bundle. This is the check
  /// that catches a broken configuration: Sparkle refuses to run when
  /// `SUPublicEDKey` is missing or malformed, or when `SUFeedURL` is absent, and
  /// `canCheckForUpdates` stays false. Nothing here contacts the network — the
  /// assertion is about Sparkle accepting the bundle, not about the feed.
  @Test func sparkleAcceptsTheShippedConfiguration() async throws {
    let bundle = Bundle.main
    let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    #expect(key?.isEmpty == false, "SUPublicEDKey is missing from the built bundle")
    #expect(feed?.hasPrefix("https://") == true, "SUFeedURL is missing or not https")
    // An EdDSA public key is 32 bytes, base64-encoded.
    #expect(Data(base64Encoded: key ?? "")?.count == 32)

    let updater = SparkleUpdaterService()
    updater.start()
    // Never check on a schedule from a test run.
    updater.automaticallyChecksForUpdates = false

    #expect(updater.canCheckForUpdates, "Sparkle started but refuses to check — bad configuration")
  }

  @Test func theUpdatesSectionIsRegistered() {
    #expect(SettingsSection.allCases.contains(.updates))
    #expect(SettingsSection.updates.title == String(localized: "Actualizaciones"))
    #expect(Self.copiaEnEspanol("Actualizaciones") == "Actualizaciones")
    #expect(!SettingsSection.updates.icon.isEmpty)
  }

  /// Sparkle es la única dependencia de terceros y vive encerrada en
  /// `Dilo/Updates/` (AGENTS.md). Esto falla en el momento en que otro
  /// archivo la importe, que es el punto: la regla sólo es real si algo mira.
  @Test func onlyTheUpdatesModuleImportsSparkle() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Dilo")

    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" } ?? []
    #expect(!files.isEmpty, "no Swift sources found under \(root.path)")

    let importers = try files
      .filter { url in
        try String(contentsOf: url, encoding: .utf8)
          .split(separator: "\n")
          .contains { $0.trimmingCharacters(in: .whitespaces) == "import Sparkle" }
      }
      .map { $0.lastPathComponent }
      .sorted()

    #expect(importers == ["SparkleUpdaterService.swift"])
  }

  /// The feed Sparkle polls has to parse and name the app, even before the
  /// first release adds an item: a missing or broken file reports a failed
  /// check instead of "you're up to date".
  @Test func theCommittedAppcastParses() throws {
    let appcast = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "appcast.xml")

    let xml = try String(contentsOf: appcast, encoding: .utf8)
    #expect(xml.contains("<title>Dilo</title>"))
    #expect(try XMLDocument(contentsOf: appcast, options: []).rootElement()?.name == "rss")
  }

  /// Acerca de existe y nombra el fork. La atribución a Talkify es condición
  /// de la licencia MIT: si alguien saca la sección, esto falla.
  @Test func laSeccionAcercaDeEstaRegistrada() {
    #expect(SettingsSection.allCases.contains(.about))
    #expect(SettingsSection.about.title == String(localized: "Acerca de"))
    #expect(Self.copiaEnEspanol("Acerca de") == "Acerca de")
    #expect(!SettingsSection.about.icon.isEmpty)
  }

  /// El copy en español sacado del catálogo del bundle, corra el Mac en el
  /// idioma que corra.
  ///
  /// `title` pasa por el catálogo, así que en un Mac en inglés —el runner de
  /// CI lo es— vale "Updates" y compararlo contra el literal español fallaba
  /// sin que nada estuviera roto. Lo que se quiere afirmar es que la sección
  /// trae ese copy y que el español, que es el idioma en que se escribe la
  /// app, sigue en el catálogo: eso se pregunta acá, a `es.lproj` directo.
  /// El centinela importa: `localizedString` devuelve la clave cuando no
  /// encuentra la entrada, y entonces una traducción borrada pasaría igual.
  static func copiaEnEspanol(_ clave: String) -> String {
    guard let carpeta = Bundle.main.url(forResource: "es", withExtension: "lproj"),
      let catalogo = Bundle(url: carpeta)
    else { return "sin es.lproj" }
    return catalogo.localizedString(forKey: clave, value: "sin traducción al español", table: nil)
  }
}

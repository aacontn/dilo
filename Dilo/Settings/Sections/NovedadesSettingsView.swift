import DiloText
import SwiftUI

/// La sección Novedades: qué trae la versión que estás corriendo.
///
/// El árbol de origen traía su changelog de GitHub. Eso significaba que la app sabía
/// menos de sí misma que un servidor, que sin internet no tenía nada que
/// contar, y que las notas estaban en inglés porque venían del release. Las de
/// Dilo viajan dentro del `.app`, en español, y son el mismo archivo que
/// `scripts/release.sh` publica: uno solo, imposible de desincronizar.
struct NovedadesSettingsView: View {
  @Environment(\.colorSchemeContrast) private var contrast

  private let notas = NotasDeVersion.deEstaVersion()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let notas {
        Text("Dilo \(notas.version)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(SettingsTheme.accent)

        ForEach(Array(secciones(de: notas).enumerated()), id: \.offset) { _, seccion in
          if let titulo = seccion.titulo {
            SettingsCard(title: "\(titulo)") {
              cuerpo(seccion.bloques)
                .padding(.vertical, 10)
            }
          } else {
            cuerpo(seccion.bloques)
              .padding(.bottom, 2)
          }
        }
      } else {
        AvisoDeDilo(
          texto: "No pude cargar las novedades de esta versión. Puedes seguir usando Dilo."
        )
      }
    }
  }

  @ViewBuilder
  private func cuerpo(_ bloques: [NotasDeVersion.Bloque]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(bloques.enumerated()), id: \.offset) { _, bloque in
        switch bloque {
        case let .parrafo(texto):
          linea(texto)
        case let .lista(items):
          VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
              HStack(alignment: .top, spacing: 8) {
                Circle()
                  .fill(SettingsTheme.accent.opacity(0.7))
                  .frame(width: 4, height: 4)
                  .padding(.top, 7)
                linea(item)
              }
            }
          }
        case .titulo:
          // Los títulos los dibuja la tarjeta que envuelve a su sección.
          EmptyView()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// La negrita y los enlaces de adentro de la línea los resuelve
  /// `AttributedString`; si el Markdown viniera roto, se muestra tal cual en
  /// vez de no mostrar nada.
  private func linea(_ texto: String) -> Text {
    if let atribuido = try? AttributedString(markdown: texto) {
      return Text(atribuido)
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(contrast == .increased ? 0.88 : 0.72))
    }
    return Text(texto)
      .font(.system(size: 13))
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.88 : 0.72))
  }

  private struct Seccion {
    var titulo: String?
    var bloques: [NotasDeVersion.Bloque] = []
  }

  /// Parte las notas en secciones por título, para que cada una caiga en su
  /// tarjeta como cualquier otro grupo de Ajustes.
  private func secciones(de notas: NotasDeVersion) -> [Seccion] {
    var secciones: [Seccion] = []
    var actual = Seccion(titulo: nil)

    for bloque in notas.bloques {
      if case let .titulo(texto) = bloque {
        if !actual.bloques.isEmpty { secciones.append(actual) }
        actual = Seccion(titulo: texto)
        continue
      }
      actual.bloques.append(bloque)
    }
    if !actual.bloques.isEmpty { secciones.append(actual) }
    return secciones
  }
}

extension NotasDeVersion {
  /// La versión que corre, o nil si el `.app` no trae su archivo.
  static func deEstaVersion() -> NotasDeVersion? {
    guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    else { return nil }
    return deLaVersion(version)
  }

  /// El archivo viaja en el bundle plano, así que se busca por nombre completo
  /// ("0.4.0.md") y no por carpeta.
  static func deLaVersion(_ version: String) -> NotasDeVersion? {
    guard let url = Bundle.main.url(forResource: version, withExtension: "md"),
      let markdown = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    return NotasDeVersion(version: version, markdown: markdown)
  }
}

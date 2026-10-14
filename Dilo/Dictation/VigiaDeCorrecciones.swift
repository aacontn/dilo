// Propio de Dilo. Idea y tiempos de referencia: BetterWispr CorrectionWatcher
// (derivado de VoiceInk, GPL-3: sólo la idea, nada de su código) y Muesli
// DictationCorrectionMonitor.swift (MIT: mirar un rato después del pegado y
// esperar la calma antes de comparar).
import AppKit
import Carbon.HIToolbox
import DiloCapabilities
import DiloModes
import DiloText

/// Mira el campo donde se pegó un dictado y avisa cuando la persona terminó
/// de editarlo. Sólo target directo: lee otra app por Accesibilidad, y en
/// MAS `Capacidad.vigiaDeCorrecciones` está escondida.
///
/// No decide nada sobre palabras: entrega «lo pegado, editado» y el resto lo
/// hace `AprendizajeDeCorrecciones`, que es puro y se prueba entero. Lo que
/// lee vive en esta tarea y se suelta: no se guarda ni se registra.
@MainActor
final class VigiaDeCorrecciones {
  struct Tiempos {
    var cadaCuanto = Duration.milliseconds(500)
    /// 60 vistazos = 30 s. Muesli mira 45 s; BetterWispr, 30.
    var vistazos = 60
    /// Tres vistazos iguales = 1,5 s sin escribir: terminó de corregir.
    var vistazosQuieto = 3
    /// El campo tiene que mostrar lo pegado dentro de los primeros 5 s.
    var vistazosParaEncontrarLoPegado = 10
  }

  private var tarea: Task<Void, Never>?
  private let tiempos: Tiempos
  /// Con entrada segura activa alguien está escribiendo una clave en algún
  /// lado: no se mira nada más.
  private let entradaSegura: @Sendable () -> Bool

  init(
    tiempos: Tiempos = Tiempos(),
    entradaSegura: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
  ) {
    self.tiempos = tiempos
    self.entradaSegura = entradaSegura
  }

  var estaMirando: Bool { tarea != nil }

  /// - Parameters:
  ///   - pegado: el texto exacto que se insertó.
  ///   - leerValor: el valor del campo del dictado, fuera del actor
  ///     principal (`HostCapabilities.fotoDelCampo`).
  ///   - alEditar: se llama una vez, con lo pegado tal como quedó.
  func vigilar(
    pegado: String,
    leerValor: @escaping @Sendable () async -> String?,
    alEditar: @escaping @MainActor (String) -> Void
  ) {
    detener()
    let tiempos = tiempos
    let entradaSegura = entradaSegura
    tarea = Task { [weak self] in
      defer { if !Task.isCancelled { self?.tarea = nil } }
      var base: String?
      var anterior: String?
      var quieto = 0
      for vistazo in 0 ..< tiempos.vistazos {
        try? await Task.sleep(for: tiempos.cadaCuanto)
        guard !Task.isCancelled, !entradaSegura() else { return }
        guard let valor = await leerValor(), !Task.isCancelled else { return }

        guard let laBase = base else {
          if valor.contains(pegado) {
            base = valor
            anterior = valor
          } else if vistazo >= tiempos.vistazosParaEncontrarLoPegado {
            return
          }
          continue
        }
        // Vaciado después de tener texto: lo mandó (Intro en un chat). Se
        // evalúa lo último que se vio antes de que se fuera.
        if valor.isEmpty {
          if let ultimo = anterior, ultimo != laBase {
            Self.entregar(base: laBase, pegado: pegado, actual: ultimo, alEditar)
          }
          return
        }
        quieto = valor == anterior ? quieto + 1 : 0
        anterior = valor
        if quieto >= tiempos.vistazosQuieto, valor != laBase {
          Self.entregar(base: laBase, pegado: pegado, actual: valor, alEditar)
          return
        }
      }
    }
  }

  /// Se llama al empezar otro dictado: nunca dos vigías, y un dictado nuevo
  /// en el mismo campo no es una corrección del anterior.
  func detener() {
    tarea?.cancel()
    tarea = nil
  }

  private static func entregar(
    base: String, pegado: String, actual: String,
    _ alEditar: @MainActor (String) -> Void
  ) {
    guard let editado = CambioEnLoPegado.editado(base: base, pegado: pegado, actual: actual),
      editado != pegado
    else { return }
    alEditar(editado)
  }
}

/// El diccionario de español para el filtro de sentido. `NSSpellChecker`
/// vive en el hilo principal; el filtro lo recibe como función.
@MainActor
func esPalabraEspanola(_ palabra: String) -> Bool {
  let rango = NSSpellChecker.shared.checkSpelling(
    of: palabra, startingAt: 0, language: "es", wrap: false,
    inSpellDocumentWithTag: 0, wordCount: nil
  )
  return rango.location == NSNotFound
}

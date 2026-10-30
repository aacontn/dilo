import AVFoundation
import DiloModes
import Foundation

/// La voz de la **Conversación** por ahora: `AVSpeechSynthesizer`, en el Mac.
///
/// Cumple `VozQueContesta` y nada más. «Leer en voz alta» está pasando a voces
/// neurales locales en otra rama; cuando llegue, esa voz cumple el mismo
/// contrato y reemplaza a esta sin tocar el controlador. Por eso esto no
/// comparte nada con `Dilo/ReadAloud/`.
///
/// Cada oración es un `AVSpeechUtterance` en la cola del sintetizador, que ya
/// encola en orden y no corta la que está sonando: es exactamente el
/// streaming que el contrato pide. El sintetizador se crea al primer uso, no
/// al arrancar la app.
@MainActor
final class VozDelSistema: NSObject, VozQueContesta {
  var alEmpezar: (@MainActor () -> Void)?
  var alTerminar: (@MainActor () -> Void)?

  private var sintetizador: AVSpeechSynthesizer?
  private var ajustes = AjustesDeLaVoz.deFabrica
  /// La voz resuelta para los ajustes de ahora. Se busca una vez por cambio
  /// y no en cada oración: `speechVoices()` tarda cientos de milisegundos.
  private var vozResuelta: AVSpeechSynthesisVoice?
  private var vozBuscada = false

  /// Lo encolado que todavía no termina de sonar, por identidad, y si el
  /// turno ya no trae más texto. Con las dos cosas se sabe cuándo avisar que
  /// terminó; y un aviso del delegado de algo que `detener()` ya calló no
  /// está en el conjunto y no cuenta.
  private var encolados: Set<ObjectIdentifier> = []
  private var turnoCerrado = false
  private var empezoElTurno = false

  func ajustar(_ ajustes: AjustesDeLaVoz) {
    guard ajustes != self.ajustes else { return }
    self.ajustes = ajustes
    vozBuscada = false
    vozResuelta = nil
  }

  func decir(_ oracion: String) {
    let limpia = oracion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpia.isEmpty else { return }
    let sintetizador = sintetizadorListo()
    let enunciado = AVSpeechUtterance(string: limpia)
    enunciado.voice = voz()
    enunciado.rate = Self.rate(para: ajustes.velocidad)
    // Un respiro corto entre oraciones: sin él, el sintetizador las pega y
    // suena a lectura de corrido.
    enunciado.postUtteranceDelay = 0.04
    encolados.insert(ObjectIdentifier(enunciado))
    sintetizador.speak(enunciado)
  }

  func cerrarElTurno() {
    turnoCerrado = true
    avisarSiTermino()
  }

  func detener() {
    encolados.removeAll()
    turnoCerrado = false
    empezoElTurno = false
    sintetizador?.stopSpeaking(at: .immediate)
  }

  /// La velocidad del sistema, multiplicada: 1 es la de siempre.
  static func rate(para velocidad: Double) -> Float {
    let base = AVSpeechUtteranceDefaultSpeechRate
    let valor = base * Float(velocidad)
    return min(max(valor, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
  }

  private func sintetizadorListo() -> AVSpeechSynthesizer {
    if let sintetizador { return sintetizador }
    let nuevo = AVSpeechSynthesizer()
    nuevo.delegate = self
    sintetizador = nuevo
    return nuevo
  }

  /// La elegida por identificador o, sin elegir, la de fábrica del español.
  private func voz() -> AVSpeechSynthesisVoice? {
    if vozBuscada { return vozResuelta }
    vozBuscada = true
    if let id = ajustes.voz, let elegida = AVSpeechSynthesisVoice(identifier: id) {
      vozResuelta = elegida
    } else {
      vozResuelta = AVSpeechSynthesisVoice(language: Self.idiomaDeFabrica)
        ?? AVSpeechSynthesisVoice(language: "es-ES")
    }
    return vozResuelta
  }

  /// El español de Latinoamérica primero: es el más cercano al de Chile que
  /// macOS trae instalado.
  static let idiomaDeFabrica = "es-MX"

  private func termino(_ id: ObjectIdentifier) {
    guard encolados.remove(id) != nil else { return }
    avisarSiTermino()
  }

  private func empezo(_ id: ObjectIdentifier) {
    guard encolados.contains(id), !empezoElTurno else { return }
    empezoElTurno = true
    alEmpezar?()
  }

  private func avisarSiTermino() {
    guard turnoCerrado, encolados.isEmpty else { return }
    turnoCerrado = false
    empezoElTurno = false
    alTerminar?()
  }
}

extension VozDelSistema: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.empezo(id) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.termino(id) }
  }
}

/// Las voces en español que el Mac tiene, para el selector de la barra de
/// llamada. Se leen fuera del hilo principal: `speechVoices()` tarda entre
/// 200 y 570 ms (`AGENTS.md`, «La ventana de Ajustes»).
enum VocesEnEspanol {
  struct Voz: Equatable, Sendable {
    let id: String
    let nombre: String
  }

  static func leer() async -> [Voz] {
    await Task.detached(priority: .utility) {
      AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("es") }
        .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
        .map { voz in
          // «Paulina (MX)»: el nombre y la región, que es lo que distingue
          // dos voces con el mismo nombre en la barra.
          let region = voz.language.split(separator: "-").last.map(String.init) ?? voz.language
          return Voz(id: voz.identifier, nombre: "\(voz.name) (\(region))")
        }
    }.value
  }
}

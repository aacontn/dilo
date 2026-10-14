import AVFAudio
import CoreAudio
import DiloCapabilities
import Foundation
import Speech

/// Lo que se lee del sistema al apretar el gatillo, antes de abrir el
/// micrófono (`EstadoParaDictar`).
///
/// Todo es una pregunta a TCC o a Core Audio que contesta al tiro: ninguna
/// abre el micrófono, muestra un diálogo ni carga un plugin de dispositivos.
/// Por eso la entrada de audio se pregunta a Core Audio y no a
/// `AVCaptureDevice`, que la primera vez carga los plugins de captura y le
/// cobraría ese arranque al gatillo.
enum LecturaParaDictar {
  @MainActor
  static func leer() -> PermisosLeidos {
    PermisosLeidos(
      microfono: microfono,
      hayMicrofono: hayMicrofono,
      reconocimientoDeVoz: reconocimientoDeVoz
    )
  }

  static var microfono: EstadoParaDictar.Autorizacion {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: .concedida
    case .undetermined: .sinDecidir
    case .denied: .denegada
    @unknown default: .denegada
    }
  }

  static var reconocimientoDeVoz: EstadoParaDictar.Autorizacion {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: .concedida
    case .notDetermined: .sinDecidir
    case .denied, .restricted: .denegada
    @unknown default: .denegada
    }
  }

  /// Si hay una entrada de audio por defecto. Ante la duda dice que sí: un
  /// error de Core Audio no es razón para no dejar dictar, y el micrófono
  /// muerto de verdad lo ve el watchdog de la muesca.
  static var hayMicrofono: Bool {
    #if DEBUG
      // La medición de soltar→texto escucha un WAV y no el micrófono
      // (`EntradaWAVDeMetricas`): un Mac sin micrófono la tiene que poder
      // correr igual.
      if ProcessInfo.processInfo.environment[EntradaWAVDeMetricas.variable] != nil {
        return true
      }
    #endif
    var dispositivo = AudioObjectID(kAudioObjectUnknown)
    var tamano = UInt32(MemoryLayout<AudioObjectID>.size)
    var direccion = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let estado = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &direccion, 0, nil, &tamano, &dispositivo
    )
    guard estado == noErr else { return true }
    return dispositivo != AudioObjectID(kAudioObjectUnknown)
  }
}

extension BloqueoDelDictado {
  /// Lo que la muesca dice. Una línea de unos treinta caracteres, que es lo
  /// que cabe en la muesca de dictado: qué falta, y —si se arregla con un
  /// clic— que el clic lo arregla. Dónde está la casilla lo resuelve el clic,
  /// que abre el panel exacto.
  var texto: String {
    switch self {
    case .microfonoDenegado:
      String(localized: "Sin micrófono: clic para darlo")
    case .microfonoSinDecidir:
      String(localized: "Contesta el aviso del micrófono")
    case .sinMicrofono:
      String(localized: "No hay micrófono conectado")
    case .reconocimientoDeVozDenegado:
      String(localized: "Sin reconocimiento de voz: clic")
    case .sinAccesibilidad:
      String(localized: "Sin Accesibilidad: clic para darla")
    case let .bajandoModelo(idioma, porcentaje?):
      String(localized: "Bajando \(idioma)… \(porcentaje)%")
    case let .bajandoModelo(idioma, nil):
      String(localized: "Bajando \(idioma)…")
    case .preparandoMotor:
      String(localized: "Preparando el reconocimiento…")
    // El porqué tal como lo dijo el sistema, como antes: es lo único que
    // sirve para buscar el problema.
    case let .motorFallo(porque):
      porque
    case .campoProtegido:
      String(localized: "Campo protegido")
    case .traduccionSinIdioma:
      String(localized: "Elige un idioma para traducir")
    case .traduccionNoLista:
      String(localized: "La traducción no está lista")
    }
  }

  /// El aviso con su clic, cuando el arreglo es una casilla de Ajustes del
  /// Sistema. Sin decidir no lleva clic: el aviso de macOS ya está en
  /// pantalla, y abrir Ajustes encima lo taparía.
  var avisoConAccion: AvisoConAccion? {
    switch self {
    case .microfonoDenegado, .reconocimientoDeVozDenegado, .sinAccesibilidad:
      guard let permiso else { return nil }
      return AvisoConAccion(texto: texto, accion: .abrirAjustes(permiso.panelDeAjustes))
    default:
      return nil
    }
  }
}

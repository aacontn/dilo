import AVFAudio
import AppKit
import CoreGraphics
import DiloCapabilities
import Speech

/// Cómo está cada permiso **ahora mismo**, y cómo pedirlo.
///
/// En vivo y no una foto al abrir: la persona sale a Ajustes del Sistema,
/// marca la casilla y vuelve, y la pantalla tiene que haberse enterado sola.
/// Un onboarding que sigue diciendo "falta" después de que lo diste es un
/// onboarding que no se cree ni él.
///
/// Accesibilidad e Input Monitoring se leen preguntando cada vez, nunca
/// guardando: TCC los cambia por fuera del proceso y cualquier copia
/// envejece en segundos.
@MainActor
@Observable
final class EstadoDePermisos {
  /// Lo único que la pantalla necesita saber de cada permiso.
  enum Estado {
    case concedido
    case falta
  }

  private(set) var estados: [Permiso: Estado] = [:]

  /// Cuál motor está elegido, porque el Reconocimiento de voz cuelga de eso y
  /// la elección se puede cambiar sin cerrar esta ventana.
  var motorEsApple: Bool

  @ObservationIgnored
  private let anfitrion: any HostCapabilities

  init(motorEsApple: Bool, anfitrion: any HostCapabilities = Anfitrion.actual) {
    self.motorEsApple = motorEsApple
    self.anfitrion = anfitrion
    refrescar()
  }

  /// Los permisos que esta copia pide, en orden: lo que el anfitrión esconde
  /// no se pide, y el del motor de Apple sólo si ese motor está elegido.
  var pasos: [Permiso] {
    Permiso.pasos(anfitrion: anfitrion, motorEsApple: motorEsApple)
  }

  var todosConcedidos: Bool {
    pasos.allSatisfy { estado(de: $0) == .concedido }
  }

  func estado(de permiso: Permiso) -> Estado {
    estados[permiso] ?? .falta
  }

  func refrescar() {
    for permiso in Permiso.allCases {
      estados[permiso] = Self.leer(permiso) ? .concedido : .falta
    }
  }

  /// El botón de cada fila: primero el diálogo del sistema cuando todavía se
  /// puede mostrar, y si no, el panel exacto de Ajustes.
  ///
  /// Micrófono y Reconocimiento de voz tienen API para pedirlos, y macOS sólo
  /// muestra ese diálogo una vez en la vida del bundle; después la única
  /// manera es la casilla. Accesibilidad e Input Monitoring no se conceden
  /// nunca desde el diálogo: éste sólo deja a Dilo en la lista para que se
  /// pueda marcar.
  func pedir(_ permiso: Permiso) {
    switch permiso {
    case .microfono:
      Task {
        let concedido = await PermissionService.requestMicrophoneAccess()
        if !concedido { abrirAjustes(de: permiso) }
        refrescar()
      }
    case .reconocimientoDeVoz:
      Task {
        let concedido = await PermissionService.requestSpeechAccess()
        if !concedido { abrirAjustes(de: permiso) }
        refrescar()
      }
    case .accesibilidad:
      PermissionService.requestAccessibilityAccess()
      abrirAjustes(de: permiso)
    case .monitoreoDeEntrada:
      _ = CGRequestListenEventAccess()
      abrirAjustes(de: permiso)
    }
  }

  func abrirAjustes(de permiso: Permiso) {
    guard let url = URL(string: permiso.panelDeAjustes) else { return }
    NSWorkspace.shared.open(url)
  }

  private static func leer(_ permiso: Permiso) -> Bool {
    switch permiso {
    case .microfono:
      AVAudioApplication.shared.recordPermission == .granted
    case .reconocimientoDeVoz:
      SFSpeechRecognizer.authorizationStatus() == .authorized
    case .accesibilidad:
      PermissionService.hasAccessibilityAccess
    case .monitoreoDeEntrada:
      CGPreflightListenEventAccess()
    }
  }
}

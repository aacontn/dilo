import CoreAudio
import DiloReuniones
import Foundation

/// Lecturas de la HAL que necesitan las reuniones. Sólo leen: Dilo nunca
/// escribe la salida ni la entrada del sistema (AGENTS.md, «El micrófono»).
enum HALDeReuniones {
  static let sistema = AudioObjectID(kAudioObjectSystemObject)

  static func direccion(
    _ selector: AudioObjectPropertySelector, _ ambito: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: ambito, mElement: kAudioObjectPropertyElementMain)
  }

  static func leer<T: BitwiseCopyable>(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector,
    ambito: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, inicial: T) -> T?
  {
    var direccion = direccion(selector, ambito)
    var valor = inicial
    var tamaño = UInt32(MemoryLayout<T>.size)
    let estado = AudioObjectGetPropertyData(objeto, &direccion, 0, nil, &tamaño, &valor)
    return estado == noErr ? valor : nil
  }

  static func texto(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var direccion = direccion(selector)
    var valor: Unmanaged<CFString>?
    var tamaño = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(objeto, &direccion, 0, nil, &tamaño, &valor) == noErr else { return nil }
    return valor?.takeRetainedValue() as String?
  }

  static var salidaDelSistema: AudioDeviceID? {
    let id: AudioDeviceID? = leer(sistema, kAudioHardwarePropertyDefaultOutputDevice, inicial: AudioDeviceID(0))
    return id == kAudioObjectUnknown ? nil : id
  }

  /// Los procesos que Core Audio conoce: los que abrieron audio alguna vez.
  static var procesos: [AudioObjectID] {
    var direccion = direccion(kAudioHardwarePropertyProcessObjectList)
    var tamaño: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sistema, &direccion, 0, nil, &tamaño) == noErr else { return [] }
    var lista = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(tamaño) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sistema, &direccion, 0, nil, &tamaño, &lista) == noErr else { return [] }
    return lista
  }

  static func abreElMicrofono(_ proceso: AudioObjectID) -> Bool {
    leer(proceso, kAudioProcessPropertyIsRunningInput, inicial: UInt32(0)) == 1
  }

  static func paquete(de proceso: AudioObjectID) -> String? {
    texto(proceso, kAudioProcessPropertyBundleID)
  }

  /// El objeto de proceso de Core Audio de este proceso, o nil si todavía no
  /// abrió audio (entonces no hay nada de Dilo que excluir del tap).
  static var procesoPropio: AudioObjectID? {
    var direccion = direccion(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = getpid()
    var objeto = AudioObjectID(kAudioObjectUnknown)
    var tamaño = UInt32(MemoryLayout<AudioObjectID>.size)
    let estado = AudioObjectGetPropertyData(
      sistema, &direccion, UInt32(MemoryLayout<pid_t>.size), &pid, &tamaño, &objeto
    )
    return estado == noErr && objeto != kAudioObjectUnknown ? objeto : nil
  }

  /// Por dónde sale el audio ahora, para saber si hace falta el filtro de
  /// eco.
  static var salidaDeAudio: SalidaDeAudio {
    guard let id = salidaDelSistema else { return .desconocida }
    let tipo: UInt32 = leer(id, kAudioDevicePropertyTransportType, inicial: UInt32(0)) ?? 0
    let fuente: UInt32? = leer(id, kAudioDevicePropertyDataSource, ambito: kAudioObjectPropertyScopeOutput, inicial: UInt32(0))
    return SalidaDeAudio.clasificar(
      transporte: transporte(tipo), fuente: fuente.map(cuatroLetras), nombre: texto(id, kAudioObjectPropertyName) ?? ""
    )
  }

  static func transporte(_ tipo: UInt32) -> String {
    switch tipo {
    case kAudioDeviceTransportTypeBuiltIn: "integrado"
    case kAudioDeviceTransportTypeBluetooth: "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: "bluetoothle"
    case kAudioDeviceTransportTypeUSB: "usb"
    case kAudioDeviceTransportTypeHDMI: "hdmi"
    case kAudioDeviceTransportTypeDisplayPort: "displayport"
    case kAudioDeviceTransportTypeThunderbolt: "thunderbolt"
    case kAudioDeviceTransportTypeAirPlay: "airplay"
    default: "otro"
    }
  }

  static func cuatroLetras(_ codigo: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((codigo >> UInt32($0)) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

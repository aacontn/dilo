import CoreAudio
import Foundation

/// Lectura de la HAL de Core Audio: qué micrófonos hay y cuál es la entrada
/// del sistema. Sólo lee; Dilo **nunca** escribe
/// `kAudioHardwarePropertyDefaultInputDevice` ni ninguna otra propiedad del
/// sistema. API pública; funciona en sandbox con `device.audio-input`.
public enum DispositivosDeAudio {
  public static func entradas() -> [EntradaDeAudio] {
    let ids: [AudioDeviceID] = leerLista(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices
    )
    return ids.compactMap { id in
      guard tieneEntrada(id),
        let uid = leerTexto(id, kAudioDevicePropertyDeviceUID),
        let nombre = leerTexto(id, kAudioObjectPropertyName)
      else { return nil }
      return EntradaDeAudio(id: id, uid: uid, nombre: nombre, transporte: transporte(de: id))
    }
  }

  public static func entradaDelSistema() -> AudioDeviceID? {
    let id: AudioDeviceID? = leerValor(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice
    )
    return id == kAudioObjectUnknown ? nil : id
  }

  public static func salidaDelSistema() -> AudioDeviceID? {
    let id: AudioDeviceID? = leerValor(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice
    )
    return id == kAudioObjectUnknown ? nil : id
  }

  /// Si alguien —cualquier proceso— tiene el dispositivo corriendo. Es lo que
  /// prende el indicador naranja del micrófono; sirve para comprobar que un
  /// motor preparado y sin `start()` no lo prende.
  public static func estaCorriendo(_ id: AudioDeviceID) -> Bool {
    let corriendo: UInt32? = leerValor(id, kAudioDevicePropertyDeviceIsRunningSomewhere)
    return (corriendo ?? 0) != 0
  }

  public static func transporte(de id: AudioDeviceID) -> EntradaDeAudio.Transporte {
    let tipo: UInt32 = leerValor(id, kAudioDevicePropertyTransportType) ?? 0
    return transporte(tipo: tipo)
  }

  /// El tipo de transporte de la HAL en las cuatro clases que le importan a
  /// Dilo. Pura, para probarla sin hardware.
  static func transporte(tipo: UInt32) -> EntradaDeAudio.Transporte {
    switch tipo {
    case kAudioDeviceTransportTypeBuiltIn:
      return .interno
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      return .bluetooth
    case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
      kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
      kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
      return .cableado
    default:
      // Continuity (el iPhone), virtuales, agregados, AirPlay: nunca se
      // eligen solos.
      return .otro
    }
  }

  private static func tieneEntrada(_ id: AudioDeviceID) -> Bool {
    var direccion = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var tamano: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &direccion, 0, nil, &tamano) == noErr && tamano > 0
  }

  static func direccion(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func leerValor<T>(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
    var direccion = direccion(selector)
    var tamano = UInt32(MemoryLayout<T>.size)
    let valor = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { valor.deallocate() }
    guard AudioObjectGetPropertyData(objeto, &direccion, 0, nil, &tamano, valor) == noErr else {
      return nil
    }
    return valor.pointee
  }

  private static func leerLista<T>(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
    var direccion = direccion(selector)
    var tamano: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objeto, &direccion, 0, nil, &tamano) == noErr, tamano > 0 else {
      return []
    }
    let cuantos = Int(tamano) / MemoryLayout<T>.stride
    let lista = UnsafeMutablePointer<T>.allocate(capacity: cuantos)
    defer { lista.deallocate() }
    guard AudioObjectGetPropertyData(objeto, &direccion, 0, nil, &tamano, lista) == noErr else {
      return []
    }
    return Array(UnsafeBufferPointer(start: lista, count: Int(tamano) / MemoryLayout<T>.stride))
  }

  private static func leerTexto(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var direccion = direccion(selector)
    var tamano = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var texto: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &direccion, 0, nil, &tamano, &texto) == noErr,
      let texto
    else { return nil }
    return texto.takeRetainedValue() as String
  }
}

/// Avisa cuando cambian los dispositivos de audio o la entrada del sistema:
/// el selector de Ajustes se refresca y un motor tibio se vence. Un escucha
/// de la HAL no gasta nada mientras nada cambia; se quita al soltarlo.
public final class VigiaDeDispositivos: @unchecked Sendable {
  private let cola: DispatchQueue
  private let bloque: AudioObjectPropertyListenerBlock
  private static let selectores = [
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultInputDevice,
  ]

  public init(cola: DispatchQueue = .main, alCambiar: @escaping @Sendable () -> Void) {
    self.cola = cola
    bloque = { _, _ in alCambiar() }
    for selector in Self.selectores {
      var direccion = DispositivosDeAudio.direccion(selector)
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &direccion, cola, bloque)
    }
  }

  deinit {
    for selector in Self.selectores {
      var direccion = DispositivosDeAudio.direccion(selector)
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &direccion, cola, bloque)
    }
  }
}

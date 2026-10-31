// La secuencia del tap —descripción, tap, agregado privado con
// `TapAutoStart`, IOProc— es la de Apple («Capturing system audio with Core
// Audio taps») y la de `docs/research/system-audio-capture.md`. Adaptado de
// pasrom/meeting-transcriber (MIT, Copyright (c) 2025 pasrom): la forma del
// diccionario del agregado (`AppAudioCapture+AggregateDescription`), que el
// búfer del tap es el último de la lista que recibe el IOProc
// (`AppAudioCapture+TapBuffer`, su issue #803) y el orden en que se devuelven
// los objetos de la HAL (`AppTapSession`).
import AudioToolbox
import CoreAudio
import DiloReuniones
import Foundation
import Synchronization
import os

/// La pista `ellos`: todo el audio del Mac salvo Dilo, por un tap de Core
/// Audio (spec, «Captura»). Ni ScreenCaptureKit ni APIs privadas: un permiso
/// más chico («System Audio Recording Only») y sin reiniciar la app.
///
/// - Tap **global sin Dilo** en la Fase 1: siempre oye la llamada, venga de la
///   app que venga.
/// - Agregado **privado** con `TapAutoStart`: no aparece en Sonido, no cambia
///   la salida del usuario y no corre hasta que algo suena.
/// - El tap no silencia la fuente (`.unmuted`): lo que oyes no cambia.
/// - El IOProc corre en el hilo de tiempo real: baja a mono y copia al búfer
///   anular, nada más. La tasa es la del **agregado**, no la del tap: el tap
///   dice 48 kHz aunque la salida esté en 16 kHz, y lo que entrega el IOProc va
///   al ritmo del agregado. Lo que cambie después lo mide `TasaMedida`.
/// - Si cambia la salida del sistema, se rearma el tap sobre la nueva.
final class CapturaDelSistema: @unchecked Sendable {
  enum Falla: Error, LocalizedError {
    case hal(String, OSStatus)
    case formato(String)

    var errorDescription: String? {
      switch self {
      case let .hal(paso, estado): "No pude \(paso) (Core Audio \(estado))."
      case let .formato(detalle): "El audio del sistema llegó en un formato que no esperaba (\(detalle))."
      }
    }
  }

  private static let logger = Logger(subsystem: "cl.espaciodigital.dilo", category: "reuniones")

  private let bufer: BuferAnular
  private let tasa = TasaCompartida()
  private let cola = DispatchQueue(label: "cl.espaciodigital.dilo.reuniones.tap", qos: .userInitiated)

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var agregadoID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private var oyenteDeSalida: AudioObjectPropertyListenerBlock?
  private var activa = false

  /// Una falla después de empezar (el rearmado tras cambiar la salida). La
  /// otra pista sigue igual.
  var alFallar: (@Sendable (String) -> Void)?
  /// El nombre de la salida sobre la que se armó, para `reunion.json`.
  private(set) var dispositivo: String?

  init(bufer: BuferAnular) {
    self.bufer = bufer
  }

  func empezar() throws {
    // La primera lectura del reloj arma su tabla; que no pase en el hilo de
    // audio.
    _ = RelojDelMac.ahora
    try cola.sync {
      try armar()
      activa = true
    }
    escucharLaSalida()
  }

  /// Vuelve a armar el tap sobre la misma salida: uno armado sin permiso sigue
  /// entregando ceros aunque la persona lo dé después. No espera.
  func rearmar() {
    cola.async { [self] in
      guard activa else { return }
      desarmar()
      do {
        try armar()
      } catch {
        Self.logger.error("No pude rearmar el tap: \(error.localizedDescription, privacy: .public)")
        alFallar?(error.localizedDescription)
      }
    }
  }

  func detener() {
    if let oyenteDeSalida {
      var direccion = HALDeReuniones.direccion(kAudioHardwarePropertyDefaultOutputDevice)
      AudioObjectRemovePropertyListenerBlock(HALDeReuniones.sistema, &direccion, cola, oyenteDeSalida)
      self.oyenteDeSalida = nil
    }
    cola.sync {
      activa = false
      desarmar()
    }
  }

  private func armar() throws {
    guard let salida = HALDeReuniones.salidaDelSistema,
      let uidDeSalida = HALDeReuniones.texto(salida, kAudioDevicePropertyDeviceUID)
    else { throw Falla.hal("leer la salida del sistema", -1) }
    dispositivo = HALDeReuniones.texto(salida, kAudioObjectPropertyName)

    // Todo el Mac menos Dilo: sus sonidos de empezar y terminar no son la
    // llamada. Por objeto de proceso si ya existe, y por bundle id para cuando
    // Dilo abra audio después de armado el tap (macOS 26).
    let descripcion = CATapDescription(stereoGlobalTapButExcludeProcesses: HALDeReuniones.procesoPropio.map { [$0] } ?? [])
    if let bundle = Bundle.main.bundleIdentifier { descripcion.bundleIDs = [bundle] }
    descripcion.isProcessRestoreEnabled = true
    descripcion.uuid = UUID()
    descripcion.name = "Dilo · reunión"
    descripcion.isPrivate = true
    descripcion.muteBehavior = .unmuted

    var nuevoTap = AudioObjectID(kAudioObjectUnknown)
    var estado = AudioHardwareCreateProcessTap(descripcion, &nuevoTap)
    guard estado == noErr else { throw Falla.hal("crear el tap del audio del sistema", estado) }
    tapID = nuevoTap

    guard let formato = HALDeReuniones.leer(tapID, kAudioTapPropertyFormat, inicial: AudioStreamBasicDescription()),
      formato.mSampleRate > 0
    else {
      desarmar()
      throw Falla.formato("sin formato")
    }
    guard formato.mFormatFlags & kAudioFormatFlagIsFloat != 0, formato.mBitsPerChannel == 32,
      formato.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    else {
      desarmar()
      throw Falla.formato("\(formato.mBitsPerChannel) bits, banderas \(formato.mFormatFlags)")
    }

    let agregado: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Dilo · reunión",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: uidDeSalida,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uidDeSalida]],
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: descripcion.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
      ],
    ]
    var nuevoAgregado = AudioObjectID(kAudioObjectUnknown)
    estado = AudioHardwareCreateAggregateDevice(agregado as CFDictionary, &nuevoAgregado)
    guard estado == noErr else {
      desarmar()
      throw Falla.hal("crear el dispositivo privado del tap", estado)
    }
    agregadoID = nuevoAgregado
    let nominal = HALDeReuniones.leer(agregadoID, kAudioDevicePropertyNominalSampleRate, inicial: Float64(0)) ?? 0
    tasa.fijar(nominal > 0 ? nominal : formato.mSampleRate)

    let bufer = self.bufer
    let tasa = self.tasa
    var nuevoProc: AudioDeviceIOProcID?
    estado = AudioDeviceCreateIOProcIDWithBlock(&nuevoProc, agregadoID, nil) { _, entrada, hora, _, _ in
      // Hilo de tiempo real: nada de memoria nueva, locks ni disco.
      let listas = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: entrada))
      // El tap es el último búfer: si la salida también tiene entradas (una
      // interfaz, unos audífonos USB), las suyas vienen antes.
      guard let delTap = listas.last, let datos = delTap.mData, delTap.mNumberChannels > 0 else { return }
      let canales = Int(delTap.mNumberChannels)
      let cuadros = Int(delTap.mDataByteSize) / (MemoryLayout<Float>.size * canales)
      let flotantes = datos.assumingMemoryBound(to: Float.self)
      let host = hora.pointee.mFlags.contains(.hostTimeValid)
        ? RelojDelMac.segundos(ticks: hora.pointee.mHostTime) : RelojDelMac.ahora
      bufer.escribir(cuadros: cuadros, canales: canales, tasa: tasa.valor, host: host) { cuadro, canal in
        flotantes[cuadro * canales + canal]
      }
    }
    guard estado == noErr, let nuevoProc else {
      desarmar()
      throw Falla.hal("registrar el IOProc del tap", estado)
    }
    procID = nuevoProc

    estado = AudioDeviceStart(agregadoID, nuevoProc)
    guard estado == noErr else {
      desarmar()
      throw Falla.hal("arrancar el tap", estado)
    }
    Self.logger.notice(
      "Tap del sistema armado: tap a \(formato.mSampleRate, privacy: .public) Hz, agregado a \(nominal, privacy: .public) Hz, \(formato.mChannelsPerFrame, privacy: .public) canales"
    )
  }

  /// Devuelve los objetos en el orden que pide la HAL: parar, soltar el
  /// IOProc, el agregado y al final el tap. Lo que no se alcanzó a crear se
  /// salta.
  private func desarmar() {
    if let procID, agregadoID != kAudioObjectUnknown {
      AudioDeviceStop(agregadoID, procID)
      AudioDeviceDestroyIOProcID(agregadoID, procID)
    }
    procID = nil
    if agregadoID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agregadoID) }
    agregadoID = AudioObjectID(kAudioObjectUnknown)
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    tapID = AudioObjectID(kAudioObjectUnknown)
  }

  /// Si la persona cambia la salida (enchufa audífonos), el agregado sigue
  /// colgado de la vieja: se rearma sobre la nueva. La pista sigue en el mismo
  /// archivo; el hueco del rearmado son milisegundos.
  private func escucharLaSalida() {
    let oyente: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.activa else { return }
      self.desarmar()
      do {
        try self.armar()
      } catch {
        Self.logger.error("No pude rearmar el tap tras cambiar la salida: \(error.localizedDescription, privacy: .public)")
        self.alFallar?(error.localizedDescription)
      }
    }
    var direccion = HALDeReuniones.direccion(kAudioHardwarePropertyDefaultOutputDevice)
    AudioObjectAddPropertyListenerBlock(HALDeReuniones.sistema, &direccion, cola, oyente)
    oyenteDeSalida = oyente
  }
}

/// La tasa del agregado, compartida entre la cola que la fija y el hilo de
/// audio que la lee, sin locks.
final class TasaCompartida: Sendable {
  private let bits = Atomic<UInt64>(48_000.0.bitPattern)

  var valor: Double { Double(bitPattern: bits.load(ordering: .relaxed)) }

  func fijar(_ tasa: Double) { bits.store(tasa.bitPattern, ordering: .relaxed) }
}

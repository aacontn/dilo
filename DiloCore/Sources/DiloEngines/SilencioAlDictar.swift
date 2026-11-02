import Foundation

/// Qué se calla mientras dictas.
///
/// Alfonso, 2026-11-02: «ahora tengo que hablar por sobre lo que está
/// sonando». Dilo silencia **por app** con un tap de Core Audio que no deja
/// llegar su audio al parlante, y lo suelta al terminar: nunca toca el volumen
/// del sistema (se vería el cartel de volumen y, si Dilo se cae, quedaría
/// bajo) ni pausa con la tecla de reproducir, que es un interruptor a ciegas
/// y puede echar a andar lo que estaba en pausa. Si Dilo muere, el tap muere
/// con el proceso y el audio vuelve solo.
public enum SilencioAlDictar {
  /// Lo que la HAL dice de un proceso de audio, lo justo para decidir.
  public struct Proceso: Equatable, Sendable {
    public let objeto: UInt32
    public let pid: Int32
    public let paquete: String?
    public let suena: Bool
    public let abreElMicrofono: Bool

    public init(objeto: UInt32, pid: Int32, paquete: String?, suena: Bool, abreElMicrofono: Bool) {
      self.objeto = objeto
      self.pid = pid
      self.paquete = paquete
      self.suena = suena
      self.abreElMicrofono = abreElMicrofono
    }
  }

  /// Los objetos de proceso que hay que callar, en orden.
  ///
  /// - Sólo lo que está sonando: callar lo que no suena no sirve y un tap
  ///   más es trabajo para el `coreaudiod`.
  /// - Nunca Dilo: sus sonidos de empezar y terminar dicen qué pasa.
  /// - Nunca una app con el micrófono abierto: es una llamada, y callarla es
  ///   perderte lo que te dicen mientras escribes en el chat.
  public static func aCallar(_ procesos: [Proceso], pidPropio: Int32, paquetePropio: String?) -> [UInt32] {
    procesos.filter { proceso in
      guard proceso.suena, !proceso.abreElMicrofono, proceso.pid > 0, proceso.pid != pidPropio else {
        return false
      }
      if let paquetePropio, let paquete = proceso.paquete, paquete == paquetePropio { return false }
      return true
    }.map(\.objeto)
  }
}

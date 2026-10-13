import Accelerate
import Foundation

// Origen: imnotpayingforwisprflow, Native/audio-activity.h:10-51 (MIT, © 2026
// Yosef Shammout). Portado de C++ a Swift; las constantes y la regla son las
// suyas, el cálculo por ventana con vDSP es de Dilo.
/// Dónde empieza y dónde termina la voz de una toma.
///
/// Recorta **sólo los bordes**: las pausas de adentro quedan intactas, porque
/// una pausa en medio de una frase es parte de lo que se dijo. Existe para que
/// Parakeet no transcriba el silencio de las puntas, que es tiempo perdido al
/// soltar y material para que el motor invente («gracias», «suscríbete»).
public enum RecorteDeBordes {
  static let tasa = 16_000
  /// 20 ms.
  static let ventana = tasa / 50
  /// 250 ms de colchón a cada lado, para no comerse la primera consonante ni
  /// la cola de la última vocal, que son lo más bajo de una palabra.
  static let colchon = tasa / 4
  /// Una toma califica como voz con tres ventanas activas seguidas (60 ms): un
  /// clic del teclado dura menos.
  static let ventanasSeguidasMinimas = 3
  /// RMS de una ventana activa: 0,0015 son −56,5 dBFS. Está por **debajo** del
  /// umbral con que `MedidaDeToma` cuenta voz (−50 dBFS como mínimo), así que
  /// lo que el recorte bota nunca es algo que la medida habría contado como
  /// voz.
  static let rmsDeActividad: Float = 0.001_5
  /// Menos que esto no vale una pasada por el motor (imnot: 4 000 muestras,
  /// un cuarto de segundo).
  public static let muestrasMinimas = 4_000

  /// El tramo con voz, o nil si no hubo voz (ni tres ventanas activas
  /// seguidas). Sanea de paso, como el original: NaN e infinitos a 0 y todo
  /// acotado a [-1, 1].
  ///
  /// Corre al soltar, entre la última palabra y el texto, así que va con vDSP
  /// y no muestra por muestra: cinco minutos de audio son 4,8 millones de
  /// muestras y el spec da 300 ms para todo el camino.
  public static func preparar(_ audio: inout [Float]) -> Range<Int>? {
    guard !audio.isEmpty else { return nil }
    let umbral = Double(rmsDeActividad) * Double(rmsDeActividad)
    var primera = audio.count
    var ultima = 0
    var seguidas = 0
    var califica = false

    audio.withUnsafeMutableBufferPointer { todo in
      // Acotar de una pasada, antes de medir: un infinito queda en ±1 y un
      // NaN sigue siendo NaN, que es lo que la ventana revisa abajo.
      vDSP.clip(todo, to: -1...1, result: &todo)
      var inicio = 0
      while inicio < todo.count {
        let fin = min(inicio + ventana, todo.count)
        let tramo = UnsafeMutableBufferPointer(rebasing: todo[inicio..<fin])
        var energia = vDSP.sumOfSquares(tramo)
        // Un NaN envenena la suma entera: sólo esa ventana se recorre a mano.
        // Con un micrófono sano no pasa nunca.
        if !energia.isFinite {
          for i in tramo.indices where !tramo[i].isFinite { tramo[i] = 0 }
          energia = vDSP.sumOfSquares(tramo)
        }
        let activa = Double(energia) / Double(fin - inicio) > umbral
        if activa {
          primera = min(primera, inicio)
          ultima = fin
        }
        if activa, fin - inicio == ventana {
          seguidas += 1
          if seguidas >= ventanasSeguidasMinimas { califica = true }
        } else {
          seguidas = 0
        }
        inicio += ventana
      }
    }

    guard califica else { return nil }
    let desde = primera > colchon ? primera - colchon : 0
    let hasta = min(audio.count, ultima + colchon)
    return hasta - desde >= muestrasMinimas ? desde..<hasta : nil
  }
}

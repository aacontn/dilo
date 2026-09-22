import Foundation
import Testing

/// El juego de sonidos Marimba se genera con
/// `scripts/generar-sonidos-marimba.py` y se commitea ya renderizado, así que
/// nada verifica en tiempo de compilación que los WAV sigan siendo los que el
/// script produce. Este test abre los archivos del repo, lee el header RIFF a
/// mano y mide el pico: si alguien los reemplaza por un archivo bajado de
/// internet, con otro formato o con un nivel de alarma, falla acá.
///
/// Vive en `DiloTextTests` porque `swift test` corre sin abrir Xcode y porque
/// es el módulo donde ya viven las guardias de repo (`InstruccionesDeAgente`).
struct SonidosDeMarimbaTests {
  /// `DiloCore/Tests/DiloTextTests/<archivo>` → la raíz del repo.
  static let raiz = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  static let carpeta = raiz.appending(path: "Dilo/Resources/Sounds")
  static let archivos = ["MarimbaBegin.wav", "MarimbaEnd.wav", "MarimbaPaste.wav"]

  /// Lo mínimo de un WAV PCM que hace falta para juzgarlo: el formato y las
  /// muestras. Parsear el header a mano —y no con AVFoundation— es a
  /// propósito: el test tiene que fallar ante un archivo malformado, no
  /// dejar que un framework lo repare en silencio.
  struct WAV {
    let canales: Int
    let frecuencia: Int
    let bitsPorMuestra: Int
    let muestras: [Int16]

    var duracion: Double { Double(muestras.count / canales) / Double(frecuencia) }
    var pico: Int { muestras.map { abs(Int($0)) }.max() ?? 0 }
    var picoEnDBFS: Double { 20 * log10(Double(pico) / 32768) }
  }

  static func leer(_ nombre: String) throws -> WAV {
    let datos = try Data(contentsOf: carpeta.appending(path: nombre))

    func entero(_ offset: Int, _ bytes: Int) -> Int {
      var valor = 0
      for i in stride(from: bytes - 1, through: 0, by: -1) {
        valor = valor << 8 | Int(datos[offset + i])
      }
      return valor
    }

    func texto(_ offset: Int) -> String {
      String(decoding: datos[offset..<(offset + 4)], as: UTF8.self)
    }

    #expect(texto(0) == "RIFF", "\(nombre) no empieza con RIFF")
    #expect(texto(8) == "WAVE", "\(nombre) no es un WAVE")

    var canales = 0
    var frecuencia = 0
    var bits = 0
    var muestras: [Int16] = []

    var cursor = 12
    while cursor + 8 <= datos.count {
      let id = texto(cursor)
      let largo = entero(cursor + 4, 4)
      let cuerpo = cursor + 8

      if id == "fmt " {
        #expect(entero(cuerpo, 2) == 1, "\(nombre) no es PCM sin comprimir")
        canales = entero(cuerpo + 2, 2)
        frecuencia = entero(cuerpo + 4, 4)
        bits = entero(cuerpo + 14, 2)
      } else if id == "data" {
        for offset in stride(from: cuerpo, to: min(cuerpo + largo, datos.count), by: 2) {
          muestras.append(Int16(truncatingIfNeeded: entero(offset, 2)))
        }
      }

      cursor = cuerpo + largo + (largo % 2)
    }

    return WAV(canales: canales, frecuencia: frecuencia, bitsPorMuestra: bits, muestras: muestras)
  }

  @Test func elJuegoTieneSusTresArchivos() {
    for nombre in Self.archivos {
      #expect(
        FileManager.default.fileExists(atPath: Self.carpeta.appending(path: nombre).path),
        "falta \(nombre): regenéralo con scripts/generar-sonidos-marimba.py"
      )
    }
  }

  @Test func elGeneradorEstaVersionado() {
    let script = Self.raiz.appending(path: "scripts/generar-sonidos-marimba.py")
    #expect(
      FileManager.default.fileExists(atPath: script.path),
      "sin el generador los WAV dejan de ser reproducibles"
    )
  }

  @Test(arguments: SonidosDeMarimbaTests.archivos)
  func cadaWAVEsMono48kDe16Bits(_ nombre: String) throws {
    let wav = try Self.leer(nombre)
    #expect(wav.canales == 1)
    #expect(wav.frecuencia == 48_000)
    #expect(wav.bitsPorMuestra == 16)
    #expect(!wav.muestras.isEmpty)
  }

  /// El generador normaliza a −6 dBFS y nada debe moverlo. La tolerancia es
  /// la del redondeo a entero.
  ///
  /// Eran −14, y ese fue medio veredicto del 2026-09-21: «¿antes teníamos
  /// sonido cuando se activaba?». A −14 el juego de fábrica quedaba diez
  /// decibeles por debajo de todos los demás del bundle, y al 50 % de volumen
  /// —también de fábrica— el aviso de empezar aterrizaba en −20 dBFS. Sonaba y
  /// no se notaba, que para un aviso es lo mismo que no sonar. Sigue sin ser
  /// una alarma: −6 deja seis decibeles de aire y no recorta en ninguna punta.
  @Test(arguments: SonidosDeMarimbaTests.archivos)
  func cadaWAVLlegaAlPicoEsperado(_ nombre: String) throws {
    let wav = try Self.leer(nombre)
    #expect(
      abs(wav.picoEnDBFS - (-6.0)) < 0.1,
      "\(nombre) mide \(wav.picoEnDBFS) dBFS y debería medir -6"
    )
  }

  /// Una cola larga convierte el aviso en música de espera, y una muestra
  /// distinta de cero en cualquiera de las dos puntas es un clic.
  @Test(arguments: SonidosDeMarimbaTests.archivos)
  func cadaWAVEsCortoYSinClics(_ nombre: String) throws {
    let wav = try Self.leer(nombre)
    #expect(wav.duracion <= 0.5, "\(nombre) dura \(wav.duracion) s")
    #expect(wav.muestras.first == 0, "\(nombre) arranca con un escalón")
    #expect(wav.muestras.last == 0, "\(nombre) termina con un escalón")
  }
}

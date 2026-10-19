import Foundation

/// El driver de `probar-traduccion.sh`: lee la clave de la entrada estándar,
/// traduce cada dictado del archivo con `TraductorConClaude` —el mismo de la
/// app— y muestra el original, la traducción y cuánto tardó. Sin la clave en
/// ninguna salida.
@main
enum ProbarTraduccion {
  static func main() async {
    let argumentos = CommandLine.arguments
    guard argumentos.count == 3,
      let destino = DestinoDeTraduccion(identificador: argumentos[1])
    else {
      FileHandle.standardError.write(Data("Uso: probar-traduccion <en|zh> <archivo>\n".utf8))
      exit(64)
    }
    guard let clave = readLine(strippingNewline: true), !clave.isEmpty else {
      FileHandle.standardError.write(Data("Sin clave en la entrada estándar.\n".utf8))
      exit(1)
    }
    guard let contenido = try? String(contentsOfFile: argumentos[2], encoding: .utf8) else {
      FileHandle.standardError.write(Data("No pude leer \(argumentos[2]).\n".utf8))
      exit(66)
    }

    let dictados = contenido
      .components(separatedBy: "\n---\n")
      .map { bloque in
        bloque.split(separator: "\n", omittingEmptySubsequences: false)
          .filter { !$0.hasPrefix("#") }
          .joined(separator: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }

    print("Modelo \(TraductorConClaude.modelo), esfuerzo \(TraductorConClaude.esfuerzo), prompt \(PromptDeTraduccion.version), destino \(destino.identificador)")
    print("\(dictados.count) dictados\n")

    let traductor = TraductorConClaude(clave: clave)
    var fallas = 0
    for (numero, dictado) in dictados.enumerated() {
      let inicio = ContinuousClock.now
      print("[\(numero + 1)] \(dictado)")
      do {
        let traduccion = try await traductor.traducir(dictado, a: destino)
        let segundos = (ContinuousClock.now - inicio).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
        print("  → \(traduccion.replacingOccurrences(of: "\n", with: "\n    "))")
        print("  (\(segundos))\n")
      } catch let falla as FallaDeTraduccion {
        fallas += 1
        print("  ✗ \(falla.nombreEnElLog)\n")
      } catch {
        fallas += 1
        print("  ✗ \(error)\n")
      }
    }
    if fallas > 0 { exit(1) }
  }
}

import Foundation

/// El driver de `probar-conversacion.sh`: el router con frases chilenas de
/// ejemplo y, con `llamar`, dos turnos en streaming con Haiku 5.5. La clave
/// llega por la entrada estándar y no sale en ninguna parte.
@main
enum ProbarConversacion {
  /// Una conversación inventada que pasa por cada regla del router.
  static let conversacion = [
    "Hola, Dilo",
    "¿Qué me recomiendas para el fin de semana en Valparaíso?",
    "Ya, gracias",
    "Quiero planificar un viaje de una semana al sur con mi familia",
    "Compara ir en auto hasta Puerto Varas con volar a Puerto Montt y arrendar",
    "Dale",
    "¿Y cuánto sale la bencina?",
    "¿Y los peajes?",
    "¿Paramos en Temuco?",
    "Otra cosa: ¿cómo se hace el pebre?",
    "Rápido, ¿cuánto es el quince por ciento de cuarenta lucas?",
    "Piénsalo bien: ¿me conviene comprar o arrendar departamento en Ñuñoa?",
  ]

  static func main() async {
    switch CommandLine.arguments.dropFirst().first {
    case "router":
      router()
    case "llamar":
      router()
      guard let clave = readLine(strippingNewline: true), !clave.isEmpty else {
        FileHandle.standardError.write(Data("Sin clave en la entrada estándar.\n".utf8))
        exit(1)
      }
      await llamar(clave: clave)
    default:
      FileHandle.standardError.write(Data("Uso: probar-conversacion <router|llamar>\n".utf8))
      exit(64)
    }
  }

  static func router() {
    print("Router de modelos (reglas, sin red)\n")
    var router = RouterDeModelos()
    for (i, dicho) in conversacion.enumerated() {
      let decision = router.decidir(dicho)
      let nivel = decision.nivel.nombreCorto.padding(toLength: 7, withPad: " ", startingAt: 0)
      let motivo = decision.motivo.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
      print("[\(i + 1)] \(nivel) \(motivo) «\(dicho)»")
    }
    print("")
  }

  /// Dos turnos con Haiku forzado, contando lo que tarda cada cosa.
  static func llamar(clave: String) async {
    let cliente = ClienteDeConversacion(clave: clave)
    var historial: [MensajeDeLaConversacion] = []
    var total = 0.0
    for dicho in ["Hola, ¿qué tal? Cuéntame en dos frases qué es el pebre.", "¿Y con qué se come?"] {
      historial.append(MensajeDeLaConversacion(.persona, dicho))
      let inicio = ContinuousClock.now
      var primerPedazo: Duration?
      var primeraOracion: Duration?
      var trozos = TrozosParaDecir()
      var respuesta = ""
      print("Tú: \(dicho)")
      do {
        for try await evento in cliente.responder(PedidoDeConversacion(nivel: .haiku, historial: historial)) {
          switch evento {
          case let .texto(pedazo):
            if primerPedazo == nil { primerPedazo = .now - inicio }
            respuesta += pedazo
            if !trozos.agregar(pedazo).isEmpty, primeraOracion == nil { primeraOracion = .now - inicio }
          case let .fin(uso, cortada):
            let costo = CostosDeClaude.costo(de: uso, modelo: NivelDeModelo.haiku.modelo.id) ?? 0
            total += costo
            print("Dilo: \(respuesta)")
            print(
              "  primer pedazo \(ms(primerPedazo)) · primera oración \(ms(primeraOracion)) · total \(ms(.now - inicio))"
            )
            print(
              "  tokens: entrada \(uso.entrada), caché \(uso.escritosEnCache)/\(uso.leidosDeCache), salida \(uso.salida)"
                + (cortada ? " (cortada)" : "")
                + String(format: " · US$%.5f\n", costo)
            )
          }
        }
        historial.append(MensajeDeLaConversacion(.dilo, respuesta))
      } catch let falla as FallaDeTraduccion {
        print("  ✗ \(falla.nombreEnElLog)")
        exit(1)
      } catch {
        print("  ✗ \(error)")
        exit(1)
      }
    }
    print(String(format: "Total: US$%.5f", total))
  }

  static func ms(_ duracion: Duration?) -> String {
    guard let duracion else { return "—" }
    let c = duracion.components
    return "\(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000) ms"
  }
}

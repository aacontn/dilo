import Foundation

/// El driver de `probar-aprendizaje.sh`: lee la clave de la entrada estándar
/// y pasa las correcciones de ejemplo por el revisor, o el diccionario de
/// ejemplo por el orden, con cada modelo. Arma los pedidos con las mismas
/// constantes que la app (`AprendizajeConClaude`): prompt, esquema, esfuerzo,
/// techo y plazo. Sin la clave en ninguna salida.
@main
enum ProbarAprendizaje {
  static func main() async {
    let argumentos = CommandLine.arguments
    guard argumentos.count >= 3, ["revisar", "ordenar"].contains(argumentos[1]) else {
      FileHandle.standardError.write(Data("Uso: probar-aprendizaje <revisar|ordenar> <correcciones> [modelo…]\n".utf8))
      exit(64)
    }
    guard let clave = readLine(strippingNewline: true), !clave.isEmpty else {
      FileHandle.standardError.write(Data("Sin clave en la entrada estándar.\n".utf8))
      exit(1)
    }
    let modelos = argumentos.count > 3
      ? Array(argumentos[3...])
      : [ModelosDeAnthropic.deFabricaParaRevisar.id, ModelosDeAnthropic.deFabricaParaOrdenar.id]
    let consulta = ConsultaAClaude(clave: clave)

    if argumentos[1] == "ordenar" {
      await ordenar(consulta, modelos: modelos)
    } else {
      await revisar(consulta, archivo: argumentos[2], modelos: modelos)
    }
  }

  // MARK: Revisar

  static func revisar(_ consulta: ConsultaAClaude, archivo: String, modelos: [String]) async {
    guard let contenido = try? String(contentsOfFile: archivo, encoding: .utf8) else {
      FileHandle.standardError.write(Data("No pude leer \(archivo).\n".utf8))
      exit(66)
    }
    let lineas = contenido.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    print("Revisar · prompt \(RevisionDeCorrecciones.version) · esfuerzo \(ModelosDeAnthropic.esfuerzoParaRevisar) · \(lineas.count) correcciones")
    print("Modelos: \(modelos.joined(separator: ", "))\n")

    var aciertos = [String: Int]()
    var fallas = 0
    for (numero, linea) in lineas.enumerated() {
      let partes = linea.components(separatedBy: " | ")
      guard partes.count == 3 else {
        print("[\(numero + 1)] línea mal formada, se salta\n")
        continue
      }
      let (esperado, pegado, editado) = (partes[0], partes[1], partes[2])
      print("[\(numero + 1)] esperado: \(esperado)")
      print("  pegado:  \(pegado)")
      print("  editado: \(editado)")

      // El filtro de la app, sin el diccionario de español (eso vive en
      // AppKit): lo que pasa acá es un poco más de lo que pasaría allá.
      var pares = AprendizajeDeCorrecciones.pares(pegado: pegado, editado: editado)
      if pares.isEmpty {
        pares = Array(AprendizajeDeCorrecciones.sustituciones(
          AprendizajeDeCorrecciones.tokens(pegado), AprendizajeDeCorrecciones.tokens(editado)
        ).prefix(AprendizajeDeCorrecciones.maximoPorDictado))
        guard !pares.isEmpty else {
          print("  (sin diferencias por palabras: nada que revisar)\n")
          continue
        }
        print("  (el filtro determinista ya lo descarta; se manda igual)")
      }
      let candidatos = RevisionDeCorrecciones.candidatos(pares, pegado: pegado, editado: editado)

      for modelo in modelos {
        let pedido = ConsultaAClaude.Pedido(
          modelo: modelo,
          esfuerzo: ModelosDeAnthropic.esfuerzoParaRevisar,
          maximoDeTokens: RevisionDeCorrecciones.maximoDeTokens,
          sistema: RevisionDeCorrecciones.instrucciones,
          peticion: RevisionDeCorrecciones.peticion(candidatos),
          esquema: RevisionDeCorrecciones.esquema,
          plazo: RevisionDeCorrecciones.plazo
        )
        let inicio = ContinuousClock.now
        do {
          let texto = try await consulta.pedir(pedido)
          let segundos = segundos(desde: inicio)
          guard let leido = RevisionDeCorrecciones.leer(texto, candidatos: candidatos) else {
            fallas += 1
            print("  \(modelo): ✗ respuesta ilegible (\(segundos))")
            continue
          }
          var primero = true
          for candidato in candidatos {
            let veredicto = leido[candidato.par]
            let tipo = veredicto?.tipo.rawValue ?? "nada"
            if primero, tipo == esperado { aciertos[modelo, default: 0] += 1 }
            let marca = primero ? (tipo == esperado ? "✓" : "✗") : " "
            primero = false
            print("  \(modelo) \(marca) «\(candidato.par.oido)» → «\(candidato.par.correcto)»: \(tipo) — \(veredicto?.motivo ?? "") (\(segundos))")
          }
        } catch let falla as FallaDeTraduccion {
          fallas += 1
          print("  \(modelo): ✗ \(falla.nombreEnElLog)")
        } catch {
          fallas += 1
          print("  \(modelo): ✗ \(error)")
        }
      }
      print("")
    }
    for modelo in modelos {
      print("\(modelo): \(aciertos[modelo, default: 0]) de \(lineas.count) como se esperaba")
    }
    if fallas > 0 { exit(1) }
  }

  // MARK: Ordenar

  /// Un diccionario con todo lo que el orden tiene que ver: la misma palabra
  /// dos veces, grafías malas de marcas conocidas, palabras comunes que
  /// entraron por error, un nombre chileno que no se toca, reglas que se
  /// pisan y una regla corta que calza en todo.
  static let diccionarioDeEjemplo = Diccionario(
    palabras: [
      "Kubernetes", "kubernetes", "Posthog", "Github", "Whatsapp", "reunión", "entonces",
      "Decameron", "Espacio Digital", "Ñancupil", "Next.js", "Andes Flags", "cachái",
      "Supabase", "supa base",
    ],
    reemplazos: [
      Reemplazo(dice: "cuba netes", escribe: "kubernetes", aprendido: true),
      Reemplazo(dice: "chat ge pe te", escribe: "ChatGPT"),
      Reemplazo(dice: "ge pe te", escribe: "GPT"),
      Reemplazo(dice: "de", escribe: "De", aprendido: true),
      Reemplazo(dice: "yi tab", escribe: "Gitlab", aprendido: true),
      Reemplazo(dice: "ese cu ele", escribe: "SQL"),
    ],
    aprendidas: ["kubernetes", "reunión", "entonces", "supa base"]
  )

  static func ordenar(_ consulta: ConsultaAClaude, modelos: [String]) async {
    let original = diccionarioDeEjemplo
    print("Ordenar · prompt \(OrdenDelDiccionario.version) · esfuerzo \(ModelosDeAnthropic.esfuerzoParaOrdenar) · \(original.entradas) entradas")
    print("Modelos: \(modelos.joined(separator: ", "))\n")
    var fallas = 0
    for modelo in modelos {
      let pedido = ConsultaAClaude.Pedido(
        modelo: modelo,
        esfuerzo: ModelosDeAnthropic.esfuerzoParaOrdenar,
        maximoDeTokens: OrdenDelDiccionario.maximoDeTokens,
        sistema: OrdenDelDiccionario.instrucciones,
        peticion: OrdenDelDiccionario.peticion(original),
        esquema: OrdenDelDiccionario.esquema,
        plazo: OrdenDelDiccionario.plazo
      )
      let inicio = ContinuousClock.now
      do {
        let texto = try await consulta.pedir(pedido)
        var diccionario = original
        guard let pasada = OrdenDelDiccionario.ordenar(
          &diccionario, respuesta: texto, modelo: modelo, fecha: Date()
        ) else {
          fallas += 1
          print("\(modelo): ✗ respuesta ilegible (\(segundos(desde: inicio)))\n")
          continue
        }
        print("\(modelo) (\(segundos(desde: inicio))): \(pasada.cambios.count) cambios, \(pasada.descartados) descartados")
        for cambio in pasada.cambios {
          let estado = cambio.estado == .aplicado ? "aplica solo" : "propone"
          print("  [\(estado)] \(cambio.accion.rawValue): \(describir(cambio.cambio)) — \(cambio.motivo)")
        }
        print("  Tus palabras quedan: \(diccionario.palabras.joined(separator: ", "))")
        print("  Cuando digo quedan: \(diccionario.reemplazos.map { "\($0.dice) → \($0.escribe)" }.joined(separator: "; "))\n")
      } catch let falla as FallaDeTraduccion {
        fallas += 1
        print("\(modelo): ✗ \(falla.nombreEnElLog)\n")
      } catch {
        fallas += 1
        print("\(modelo): ✗ \(error)\n")
      }
    }
    if fallas > 0 { exit(1) }
  }

  static func describir(_ c: CambioDelDiccionario) -> String {
    var partes: [String] = []
    if !c.palabrasQuitadas.isEmpty { partes.append("saca \(c.palabrasQuitadas.joined(separator: ", "))") }
    if !c.palabrasAgregadas.isEmpty { partes.append("pone \(c.palabrasAgregadas.joined(separator: ", "))") }
    if !c.reemplazosQuitados.isEmpty {
      partes.append("saca regla \(c.reemplazosQuitados.map { "\($0.dice) → \($0.escribe)" }.joined(separator: ", "))")
    }
    if !c.reemplazosAgregados.isEmpty {
      partes.append("pone regla \(c.reemplazosAgregados.map { "\($0.dice) → \($0.escribe)" }.joined(separator: ", "))")
    }
    return partes.joined(separator: "; ")
  }

  static func segundos(desde inicio: ContinuousClock.Instant) -> String {
    (ContinuousClock.now - inicio).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
  }
}

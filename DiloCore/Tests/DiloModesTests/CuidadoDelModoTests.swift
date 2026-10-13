import Foundation
import Testing

@testable import DiloModes

/// El cuidado de cada modo, y que una lista guardada antes de que existiera
/// se siga leyendo.
struct CuidadoDelModoTests {
  @Test func losDeFabricaTraenElSuyo() {
    let cuidados = Dictionary(uniqueKeysWithValues: Modo.deFabrica.map { ($0.id, $0.cuidado) })
    #expect(cuidados == [
      "limpio": .limpieza, "mensaje": .ligera, "correo": .reescritura,
      "prompt": .reescritura, "codigo": .reescritura,
    ])
  }

  /// Un `diloModos` escrito por la versión anterior no trae el campo: se
  /// lee igual y el cuidado sale del id.
  @Test func unaListaViejaSeLeeIgual() throws {
    let vieja = #"""
      [{"id":"limpio","nombre":"Limpio","prompt":"x"},
       {"id":"mensaje","nombre":"Mensaje","prompt":"x"},
       {"id":"3F2A","nombre":"Inglés","prompt":"tradúcelo"}]
      """#
    let modos = try JSONDecoder().decode([Modo].self, from: Data(vieja.utf8))
    #expect(modos.map(\.cuidado) == [.limpieza, .ligera, .reescritura])
  }

  /// Un valor que esta versión no conoce —lo escribió una más nueva— no
  /// puede costar la lista entera.
  @Test func unCuidadoDesconocidoNoBorraLaLista() throws {
    let futura = #"[{"id":"limpio","nombre":"Limpio","prompt":"x","cuidado":"otro"}]"#
    let modos = try JSONDecoder().decode([Modo].self, from: Data(futura.utf8))
    #expect(modos.first?.cuidado == .limpieza)
  }

  @Test func elCuidadoElegidoSobreviveAGuardar() throws {
    var modo = Modo(id: "3F2A", nombre: "Inglés", prompt: "tradúcelo")
    #expect(modo.cuidado == .reescritura)
    modo.cuidado = .libre
    let datos = try JSONEncoder().encode(modo)
    #expect(try JSONDecoder().decode(Modo.self, from: datos).cuidado == .libre)
  }

  /// El `rawValue` se guarda: renombrarlo borra la elección en silencio.
  @Test func losRawValuesNoCambian() {
    #expect(Cuidado.allCases.map(\.rawValue) == ["limpieza", "ligera", "reescritura", "libre"])
  }
}

/// La propuesta que el validador rechazó, recuperable como las otras dos.
struct PropuestaRechazadaTests {
  @Test func sinRechazoNoHayPropuesta() {
    let dictado = UltimoDictado(original: "hola", limpio: "Hola.")
    #expect(!dictado.tienePropuesta)
    #expect(dictado.texto(.propuesta).isEmpty)
  }

  @Test func conRechazoLaPropuestaQuedaYLoEntregadoEsLoLimpio() {
    let dictado = UltimoDictado(
      original: "eh transfiere quince mil",
      limpio: "transfiere quince mil",
      propuestaRechazada: "Transfiere 50.000."
    )
    #expect(dictado.tienePropuesta)
    #expect(dictado.texto(.propuesta) == "Transfiere 50.000.")
    #expect(dictado.texto(.entregado) == "transfiere quince mil")
    #expect(dictado.vistazo(.propuesta) == "Transfiere 50.000.")
  }
}

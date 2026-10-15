import Foundation

@testable import DiloAgentes

/// Una fuente sin disco: dos dictados y dos palabras, o el historial
/// apagado, o una carpeta que no se deja leer.
struct FuenteFalsa: FuenteDeDilo {
  struct NoSePuedeLeer: Error {}

  var historialEncendido = true
  var falla = false
  var lista: [DictadoParaAgentes] = [
    DictadoParaAgentes(
      id: "2026-10-12T09:41:07", app: "Mail", modo: "Correo", motor: "Parakeet",
      texto: "Estimada Marta, adjunto la cotización."
    ),
    DictadoParaAgentes(id: "2026-10-11T18:02:55", app: "Notas", texto: "Revisa el informe del lunes antes de mandarlo."),
  ]
  var palabras = ["Alfonso", "Espacio Digital"]

  func dictados() async throws -> [DictadoParaAgentes] {
    if falla { throw NoSePuedeLeer() }
    return lista
  }

  func tusPalabras() -> [String] { palabras }
}

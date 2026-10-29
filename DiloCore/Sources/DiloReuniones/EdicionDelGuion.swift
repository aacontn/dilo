import Foundation

/// Lo que se arregla a mano en un guion: juntar a alguien que el modelo partió
/// en dos y reasignar una línea de alguien que juntó con otro (spec, «El
/// guion»). Hay que asumir que pasa, y que se arregla en un clic.
public enum EdicionDelGuion {
  /// Todas las palabras de `origen` pasan a `destino`, y `origen` deja de
  /// existir. Yo no se junta con nadie: sale de la pista, no de un modelo.
  public static func juntar(
    _ origen: String, en destino: String, palabras: inout [PalabraDelGuion], reunion: inout Reunion
  ) {
    guard origen != destino, origen != Hablante.yo.id, destino != Hablante.yo.id,
      reunion.hablante(destino) != nil
    else { return }
    for i in palabras.indices where palabras[i].hablante == origen {
      palabras[i].hablante = destino
    }
    reunion.hablantes.removeAll { $0.id == origen }
  }

  /// Las palabras de una línea pasan a otro hablante; si es uno nuevo, se crea
  /// con el número que sigue. Devuelve el id que quedó.
  @discardableResult
  public static func reasignar(
    _ linea: LineaDelGuion, a id: String?, palabras: inout [PalabraDelGuion], reunion: inout Reunion
  ) -> String {
    let destino: String
    if let id, reunion.hablante(id) != nil {
      destino = id
    } else {
      let siguiente = (reunion.hablantes.compactMap(\.numero).max() ?? 1) + 1
      destino = Hablante.id(numero: siguiente)
      reunion.hablantes.append(Hablante(id: destino, pista: .ellos))
    }
    // La línea son las palabras desde la primera hasta la última de su mismo
    // hablante que caen en su tramo: eso es lo que `LineasDelGuion` juntó.
    var i = linea.primeraPalabra
    while i < palabras.count, palabras[i].desde <= linea.hasta {
      if palabras[i].hablante == linea.hablante, palabras[i].vaAlGuion, palabras[i].pista == .ellos {
        palabras[i].hablante = destino
      }
      i += 1
    }
    return destino
  }
}

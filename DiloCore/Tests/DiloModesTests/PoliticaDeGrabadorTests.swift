import Testing

@testable import DiloModes

/// Modos y Atajos asignan la misma clase de tecla —una que se sostiene para
/// hablar—, así que tienen que ofrecer exactamente las mismas posibilidades.
///
/// El bug: el grabador de Modos apagaba a mano los modificadores solos, así
/// que `fn` sola —el gatillo de fábrica de Dilo, que el validador bendice y
/// que la pantalla de Atajos sí acepta— no se le podía dar a un modo. La
/// pantalla tenía su propia copia de las reglas; se borró.
struct PoliticaDeGrabadorTests {
  /// Un candidato de cada familia: modificadores solos, teclas que no
  /// escriben, combinaciones, teclas que escriben, botones del mouse y lo que
  /// el validador rechaza.
  private let candidatos: [Gatillo] = [
    .fn,
    .controlOpcionEspacio,
    .controlComandoL,
    Gatillo(
      keyCode: Gatillo.Tecla.comandoDerecho, esModificador: true, etiqueta: "⌘ derecha"
    ),
    Gatillo(keyCode: Gatillo.Tecla.f13, etiqueta: "F13"),
    Gatillo(keyCode: Gatillo.Tecla.escape, etiqueta: "esc"),
    Gatillo(
      keyCode: Gatillo.Tecla.opcionDerecha, esModificador: true, etiqueta: "⌥ derecha"
    ),
    Gatillo(keyCode: 2, etiqueta: "D"),
    Gatillo(keyCode: 2, modifierFlags: Gatillo.Modificador.opcion, etiqueta: "⌥ D"),
    Gatillo(keyCode: 2, modifierFlags: Gatillo.Modificador.control, etiqueta: "⌃ D"),
    Gatillo(keyCode: 72, etiqueta: "volumen"),
    Gatillo(botonDelMouse: 3),
    Gatillo(modifierFlags: Gatillo.Modificador.comando, botonDelMouse: 4),
  ]

  private func admitidos(_ politica: PoliticaDeGrabador) -> [Gatillo] {
    candidatos.filter(politica.admite)
  }

  @Test func modosOfreceExactamenteLoMismoQueAtajos() {
    #expect(admitidos(.deUnModo) == admitidos(.deDictado))
  }

  /// Y lo que ofrecen no es la lista vacía: `fn` sola, ⌘ derecha y un botón
  /// del mouse entran en las dos.
  @Test func unModoAdmiteElGatilloDeFabricaYLosModificadoresSolos() {
    #expect(PoliticaDeGrabador.deUnModo.admite(.fn))
    #expect(
      PoliticaDeGrabador.deUnModo.admite(
        Gatillo(
          keyCode: Gatillo.Tecla.comandoDerecho, esModificador: true,
          etiqueta: "⌘ derecha"
        )
      )
    )
    #expect(PoliticaDeGrabador.deUnModo.admite(Gatillo(botonDelMouse: 3)))
  }

  /// La política no reemplaza al validador: lo llama. Lo que el validador
  /// rechaza sigue rechazado en las dos pantallas.
  @Test func loQueElValidadorRechazaNoLoSalvaNingunaPolitica() {
    let altGr = Gatillo(
      keyCode: Gatillo.Tecla.opcionDerecha, esModificador: true, etiqueta: "⌥ derecha"
    )
    #expect(!PoliticaDeGrabador.deUnModo.admite(altGr))
    #expect(!PoliticaDeGrabador.deDictado.admite(altGr))
    #expect(!PoliticaDeGrabador.deUnModo.admite(Gatillo(keyCode: 2, etiqueta: "D")))
    #expect(!PoliticaDeGrabador.deUnModo.admite(Gatillo(keyCode: 72, etiqueta: "volumen")))
  }

  /// Leer en voz alta sí ofrece menos, y a propósito: dispara en `keyDown`,
  /// donde un modificador suelto o un botón del mouse no llegan nunca.
  @Test func apretarYSoltarOfreceMenosYEsElUnicoQuePuede() {
    #expect(!PoliticaDeGrabador.apretarYSoltar.admite(.fn))
    #expect(!PoliticaDeGrabador.apretarYSoltar.admite(Gatillo(botonDelMouse: 3)))
    #expect(PoliticaDeGrabador.apretarYSoltar.admite(.controlOpcionEspacio))
  }
}

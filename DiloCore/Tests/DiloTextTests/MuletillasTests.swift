import Testing

@testable import DiloText

/// Los seis primeros son los casos del Tauri, portados tal cual: son las
/// mismas reglas y tienen que dar lo mismo. El resto son dictados chilenos de
/// estilo — cómo habla Alfonso cuando dicta, no cómo se escribe un manual.
struct MuletillasTests {
  private func limpiar(_ texto: String) -> String { Muletillas.limpiar(texto) }

  @Test func sacaLosSonidosDeDuda() {
    #expect(limpiar("eh, necesito que revises esto") == "necesito que revises esto")
    #expect(limpiar("em el deploy falló") == "el deploy falló")
    #expect(limpiar("dale ehm ahora") == "dale ahora")
  }

  @Test func noBorraLasPalabrasQueParecenMuletilla() {
    #expect(limpiar("abre este archivo") == "abre este archivo")
    #expect(limpiar("es un tipo de dato") == "es un tipo de dato")
    #expect(limpiar("pues bien, seguimos") == "pues bien, seguimos")
    // "ha" es el verbo haber, no una duda.
    #expect(limpiar("ha sido un buen día") == "ha sido un buen día")
  }

  @Test func laMismaPalabraSaleSoloCuandoEsPausa() {
    #expect(limpiar("este, abre el archivo") == "abre el archivo")
    #expect(limpiar("abre este archivo") == "abre este archivo")
    #expect(limpiar("o sea, el build quedó listo") == "el build quedó listo")
    #expect(limpiar("a ver, dale") == "dale")
    #expect(limpiar("a ver el archivo") == "a ver el archivo")
  }

  @Test func cachaiSaleDeColetillaYSeQuedaDeVerbo() {
    #expect(limpiar("dale, cachái, ahora") == "dale, ahora")
    #expect(limpiar("el deploy quedó listo, cachái.") == "el deploy quedó listo.")
    #expect(limpiar("hazlo ¿cachái?") == "hazlo")
    // De verbo se queda entero: es una pregunta, no ruido.
    #expect(limpiar("¿cachái lo que te digo?") == "¿cachái lo que te digo?")
  }

  @Test func elVoseoYLosModismosQuedanIntactos() {
    let dictados = [
      "¿tenís el commit listo o no?",
      "ya po, dale altiro",
      "querís que lo suba ahora",
      "quedó bacán el diseño",
      "hagámoslo al tiro, si igual no cuesta nada",
    ]
    for dictado in dictados {
      #expect(limpiar(dictado) == dictado)
    }
  }

  @Test func elSpanglishTecnicoQuedaIntacto() {
    let dictados = [
      "hay que deployar el build después del commit",
      "haz el merge del branch y después el deploy",
      "el endpoint devuelve un JSON con el token",
      "súbelo al bucket y avísame",
    ]
    for dictado in dictados {
      #expect(limpiar(dictado) == dictado)
    }
  }

  @Test func colapsaElTartamudeoDelMotor() {
    #expect(limpiar("el el el deploy falló") == "el deploy falló")
    #expect(limpiar("No NO no NO no") == "No")
    // Dos no es tartamudeo: es una frase.
    #expect(limpiar("no no es por ahí") == "no no es por ahí")
  }

  @Test func unaMedidaNoEsUnaDuda() {
    #expect(limpiar("el perfil tiene 5 mm de ancho") == "el perfil tiene 5 mm de ancho")
  }

  @Test func unDictadoChilenoCompleto() {
    let dictado = "eh, o sea, hay que hacer el deploy altiro, cachái, "
      + "porque el el el build de ayer quedó malo po"
    #expect(
      limpiar(dictado)
        == "hay que hacer el deploy altiro, porque el build de ayer quedó malo po"
    )
  }

  @Test func laListaPropiaManda() {
    // Una lista propia reemplaza a las de fábrica…
    #expect(Muletillas.limpiar("ya, dale, ya", propias: ["ya"]) == "dale")
    // …y una lista vacía apaga la limpieza entera.
    #expect(Muletillas.limpiar("eh, dale", propias: []) == "eh, dale")
  }

  @Test func losSaltosDeLineaSonContenido() {
    #expect(limpiar("eh, uno\ndos") == "uno\ndos")
  }
}

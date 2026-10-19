import Testing

@testable import DiloText

/// La búsqueda de Ajustes (⌘F) se busca como se recuerda.
struct BusquedaDeAjustesTests {
  let indice: [BusquedaDeAjustes.Buscable] = [
    .init(id: "clave", titulo: "Clave de Anthropic", detalle: "Se guarda en el Llavero de macOS.", palabras: ["api key", "token"]),
    .init(id: "microfono", titulo: "Con cuál te escucho", detalle: "Automático usa el del sistema.", palabras: ["micrófono", "audífonos"]),
    .init(id: "idioma", titulo: "Idioma de dictado", detalle: "En qué idioma transcribe tu tecla principal."),
    .init(id: "traducir", titulo: "Traducir con", detalle: "Claude o Apple, en el Mac.", palabras: ["idioma", "inglés"]),
    .init(id: "muletillas", titulo: "Sacar las muletillas", detalle: "Los «eh» y los «o sea» salen solos."),
  ]

  @Test func sinTildesNiMayusculas() {
    #expect(BusquedaDeAjustes.buscar("MICROFONO", en: indice) == ["microfono"])
    #expect(BusquedaDeAjustes.buscar("audifonos", en: indice) == ["microfono"])
    #expect(BusquedaDeAjustes.buscar("ingles", en: indice) == ["traducir"])
  }

  @Test func porPedazosYEnCualquierOrden() {
    #expect(BusquedaDeAjustes.buscar("anth cla", en: indice) == ["clave"])
    #expect(BusquedaDeAjustes.buscar("api key", en: indice) == ["clave"])
  }

  @Test func todasLasPalabrasTienenQueEstar() {
    #expect(BusquedaDeAjustes.buscar("clave muletillas", en: indice).isEmpty)
  }

  @Test func elTituloPesaMasQueLasPalabrasClave() {
    // «idioma» está en el título de uno y en las palabras clave del otro.
    #expect(BusquedaDeAjustes.buscar("idioma", en: indice) == ["idioma", "traducir"])
  }

  @Test func laDescripcionTambienCuentaPeroAlFinal() {
    #expect(BusquedaDeAjustes.buscar("llavero", en: indice) == ["clave"])
    #expect(BusquedaDeAjustes.buscar("sea", en: indice) == ["muletillas"])
  }

  @Test func unaLetraSoloCalzaAlPrincipioDeUnaPalabra() {
    let resultado = BusquedaDeAjustes.buscar("x", en: indice)
    #expect(resultado.isEmpty)
  }

  @Test func vaciaNoCalzaConNada() {
    #expect(BusquedaDeAjustes.buscar("", en: indice).isEmpty)
    #expect(BusquedaDeAjustes.buscar("   ", en: indice).isEmpty)
  }

  @Test func laEnieSeBuscaComoN() {
    let conEnie = [BusquedaDeAjustes.Buscable(id: "tamano", titulo: "Tamaño del notch")]
    #expect(BusquedaDeAjustes.buscar("tamano", en: conEnie) == ["tamano"])
    #expect(BusquedaDeAjustes.buscar("tamaño", en: conEnie) == ["tamano"])
  }
}

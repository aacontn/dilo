import Testing

@testable import DiloText

/// Las frases que trajo Alfonso del dictado con 0.4.0, tal como llegaron al
/// documento. Son el caso de prueba y la razón de que `Union` exista.
enum DictadoPegado {
  /// Cada trozo como lo entregó el motor: recortado, con su puntuación y con
  /// mayúscula al empezar porque para el motor era el comienzo de un trozo.
  static let trozos = [
    "Igual se ve que es rápido",
    "Ahora habría que ver qué tan.",
    "Qué tan poderoso es",
    "Ahora te estoy escribiendo",
  ]

  static let pegadoSinArreglo = "Igual se ve que es rápidoAhora habría que ver qué tan."
    + "Qué tan poderoso esAhora te estoy escribiendo"

  static let esperado = "Igual se ve que es rápido Ahora habría que ver qué tan. "
    + "Qué tan poderoso es Ahora te estoy escribiendo"
}

struct UnionTests {
  @Test func elDictadoDeAlfonsoDejaDeSalirPegado() {
    #expect(DictadoPegado.trozos.joined() == DictadoPegado.pegadoSinArreglo)
    #expect(Union.unir(DictadoPegado.trozos) == DictadoPegado.esperado)
  }

  @Test func elNotchDeLaOtraFrase() {
    #expect(
      Union.unir(["no se ve como un notch", "Tiene una línea"])
        == "no se ve como un notch Tiene una línea"
    )
  }

  @Test func unSoloEspacioAunqueLosTrozosTraiganElSuyo() {
    #expect(Union.unir(["hola ", "  mundo"]) == "hola mundo")
    #expect(Union.unir(["hola", " mundo"]) == "hola mundo")
  }

  @Test func unTrozoVacioNoDejaEspacioDeMas() {
    #expect(Union.unir(["hola", "", "   ", "mundo"]) == "hola mundo")
    #expect(Union.unir([]) == "")
    #expect(Union.unir(["", " "]) == "")
  }

  @Test func laAperturaSeQuedaPegadaALoQueAbre() {
    #expect(Union.unir(["¿", "cómo estás?"]) == "¿cómo estás?")
    #expect(Union.unir(["¡", "qué frío!"]) == "¡qué frío!")
    #expect(Union.unir(["dijo («", "altiro»)"]) == "dijo («altiro»)")
  }

  @Test func laPuntuacionSeQuedaPegadaALoQueCierra() {
    #expect(Union.unir(["hola", ", dale"]) == "hola, dale")
    #expect(Union.unir(["listo", "."]) == "listo.")
    #expect(Union.unir(["¿quedó", "?"]) == "¿quedó?")
    #expect(Union.unir(["(el deploy", ")"]) == "(el deploy)")
    #expect(Union.unir(["dijo «altiro", "»"]) == "dijo «altiro»")
  }

  @Test func losNumerosSonPalabrasComoCualquierOtra() {
    #expect(Union.unir(["son las", "15:30 de la tarde"]) == "son las 15:30 de la tarde")
    #expect(Union.unir(["costó 3", "%"]) == "costó 3%")
    #expect(Union.unir(["van 20", "clientes"]) == "van 20 clientes")
  }

  @Test func unTrozoQueYaTerminaEnPuntoNoRecibeOtro() {
    // `Union` pone espacios, no puntos: lo que el motor no puntuó se queda
    // sin puntuar.
    #expect(Union.unir(["Listo.", "Ahora sigo"]) == "Listo. Ahora sigo")
    #expect(Union.unir(["Listo", "Ahora sigo"]) == "Listo Ahora sigo")
  }

  @Test func laColaTraeSuPropioEspacio() {
    #expect(Union.colaDe("hola", "mundo") == " mundo")
    #expect(Union.colaDe("hola", " mundo ") == " mundo")
    #expect(Union.colaDe("", "mundo") == "mundo")
    #expect(Union.colaDe("hola", "   ") == "")
    #expect(Union.colaDe("hola", ", dale") == ", dale")
    #expect(Union.colaDe("¿", "cómo") == "cómo")
    // Lo que promete: pegar la cola es lo mismo que unir.
    #expect("hola" + Union.colaDe("hola", "mundo") == Union.unir("hola", "mundo"))
  }
}

/// Lo que pasa después de unir: la costura de español no se puede comer el
/// espacio ni la puntuación de los bordes.
struct UnionYLimpiezaTests {
  @Test func laLimpiezaRespetaLosBordesDeLaCostura() {
    #expect(DiloText.limpiar(Union.unir(DictadoPegado.trozos)) == DictadoPegado.esperado)
  }

  @Test func unaMuletillaAlFinalDeUnTrozoNoPegaLasPalabras() {
    // "eh" cierra un trozo y el siguiente empieza con palabra: borrarla no
    // puede dejar "rápidoAhora".
    let texto = Union.unir(["Igual se ve que es rápido eh", "Ahora habría que ver"])
    #expect(DiloText.limpiar(texto) == "Igual se ve que es rápido Ahora habría que ver")
  }

  @Test func unaMuletillaQueAbreElTrozoSiguienteTampoco() {
    let texto = Union.unir(["mandé la cotización", "o sea, hay que revisarla"])
    #expect(DiloText.limpiar(texto) == "mandé la cotización hay que revisarla")
  }

  @Test func laPuntuacionDeLaCosturaSobreviveALaLimpieza() {
    let texto = Union.unir(["¿quedó claro", "?", "Dale, seguimos"])
    #expect(DiloText.limpiar(texto) == "¿quedó claro? Dale, seguimos")
  }
}

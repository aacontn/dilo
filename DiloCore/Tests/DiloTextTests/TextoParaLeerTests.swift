import Testing

@testable import DiloText

struct NumerosEnPalabrasTests {
  @Test func cardinalesComunes() {
    #expect(NumerosEnPalabras.cardinal(0) == "cero")
    #expect(NumerosEnPalabras.cardinal(16) == "dieciséis")
    #expect(NumerosEnPalabras.cardinal(22) == "veintidós")
    #expect(NumerosEnPalabras.cardinal(47) == "cuarenta y siete")
    #expect(NumerosEnPalabras.cardinal(100) == "cien")
    #expect(NumerosEnPalabras.cardinal(101) == "ciento uno")
    #expect(NumerosEnPalabras.cardinal(1208) == "mil doscientos ocho")
    #expect(NumerosEnPalabras.cardinal(2026) == "dos mil veintiséis")
    #expect(NumerosEnPalabras.cardinal(2348) == "dos mil trescientos cuarenta y ocho")
  }

  @Test func millones() {
    #expect(NumerosEnPalabras.cardinal(1_250_000) == "un millón doscientos cincuenta mil")
    #expect(NumerosEnPalabras.cardinal(21_000_000) == "veintiún millones")
    #expect(NumerosEnPalabras.cardinal(1_000_000_000) == "mil millones")
    #expect(NumerosEnPalabras.cardinal(12_345_678)
      == "doce millones trescientos cuarenta y cinco mil seiscientos setenta y ocho")
    #expect(NumerosEnPalabras.llevaDe(3_000_000))
    #expect(!NumerosEnPalabras.llevaDe(1_250_000))
  }

  @Test func generoYApocope() {
    #expect(NumerosEnPalabras.cardinal(21) == "veintiuno")
    #expect(NumerosEnPalabras.cardinal(21, apocopado: true) == "veintiún")
    #expect(NumerosEnPalabras.cardinal(21, femenino: true) == "veintiuna")
    #expect(NumerosEnPalabras.cardinal(31, apocopado: true) == "treinta y un")
    #expect(NumerosEnPalabras.cardinal(200, femenino: true) == "doscientas")
    #expect(NumerosEnPalabras.cardinal(500_000, femenino: true) == "quinientas mil")
    #expect(NumerosEnPalabras.cardinal(21_000) == "veintiún mil")
  }

  @Test func ordinalesYDigitos() {
    #expect(NumerosEnPalabras.ordinal(1) == "primero")
    #expect(NumerosEnPalabras.ordinal(3, femenino: true) == "tercera")
    #expect(NumerosEnPalabras.ordinal(32) == "treinta y dos")
    #expect(NumerosEnPalabras.digitos("0912") == "cero nueve uno dos")
    #expect(NumerosEnPalabras.decimales("05") == "cero cinco")
    #expect(NumerosEnPalabras.decimales("25") == "veinticinco")
  }
}

struct TextoParaLeerTests {
  private func leer(_ t: String) -> String { TextoParaLeer.preparar(t) }

  @Test func montosEnPesosDolaresYUF() {
    #expect(leer("El pago de $1.250.000 vence mañana.")
      == "El pago de un millón doscientos cincuenta mil pesos vence mañana.")
    #expect(leer("Cuesta $15.990") == "Cuesta quince mil novecientos noventa pesos")
    #expect(leer("Son $3 millones") == "Son tres millones de pesos")
    #expect(leer("Son $500 mil") == "Son quinientos mil pesos")
    #expect(leer("Un bono de $2.000.000") == "Un bono de dos millones de pesos")
    #expect(leer("US$ 300") == "trescientos dólares")
    #expect(leer("$1") == "un peso")
    #expect(leer("un saldo de 3,5 UF") == "un saldo de tres coma cinco u efe")
    #expect(leer("1 UF") == "una u efe")
  }

  @Test func fechas() {
    #expect(leer("vence el 15/03/2026") == "vence el quince de marzo de dos mil veintiséis")
    #expect(leer("el 1/10") == "el primero de octubre")
    #expect(leer("2026-10-29") == "veintinueve de octubre de dos mil veintiséis")
    #expect(leer("15-3-26") == "quince de marzo de dos mil veintiséis")
    // Un mes imposible no es fecha.
    #expect(leer("ganaron 3/15") != "ganaron quince de marzo")
  }

  @Test func horas() {
    #expect(leer("a las 14:30") == "a las catorce treinta")
    #expect(leer("a las 9:05") == "a las nueve y cinco")
    #expect(leer("a las 14:00 hrs.") == "a las catorce horas")
    #expect(leer("a la 1:00") == "a la una hora")
  }

  @Test func porcentajesOrdinalesYGrados() {
    #expect(leer("un 12% más") == "un doce por ciento más")
    #expect(leer("subió 3,5 %") == "subió tres coma cinco por ciento")
    #expect(leer("el 1° de octubre") == "el primero de octubre")
    #expect(leer("la 3ª cuota") == "la tercera cuota")
    #expect(leer("el 5to piso") == "el quinto piso")
    #expect(leer("hace 25° afuera") == "hace veinticinco grados afuera")
    #expect(leer("15 °C") == "quince grados Celsius")
  }

  @Test func numerosQueConcuerdan() {
    #expect(leer("Tengo 21 años") == "Tengo veintiún años")
    #expect(leer("vinieron 21 personas") == "vinieron veintiuna personas")
    #expect(leer("son 200 cuotas") == "son doscientas cuotas")
    #expect(leer("vendimos 2.348 unidades") == "vendimos dos mil trescientas cuarenta y ocho unidades")
    #expect(leer("el capítulo 1") == "el capítulo uno")
    #expect(leer("21 y 22") == "veintiuno y veintidós")
    #expect(leer("un millón: 1.000.000 habitantes") == "un millón: un millón de habitantes")
    #expect(leer("la versión 2.5") == "la versión dos punto cinco")
  }

  @Test func rutTelefonosYUnidades() {
    #expect(leer("RUT 12.345.678-K")
      == "RUT doce millones trescientos cuarenta y cinco mil seiscientos setenta y ocho guion ka")
    #expect(leer("llama al +56 9 1234 5678")
      == "llama al más cinco seis nueve mil doscientos treinta y cuatro cinco mil seiscientos setenta y ocho")
    #expect(leer("o al 912345678") == "o al nueve uno dos tres cuatro cinco seis siete ocho")
    #expect(leer("a 120 km/h") == "a ciento veinte kilómetros por hora")
    #expect(leer("pesa 1 kg") == "pesa un kilo")
  }

  @Test func abreviaturas() {
    #expect(leer("El Sr. Pérez y la Dra. Soto") == "El señor Pérez y la doctora Soto")
    #expect(leer("Av. Providencia N° 1208") == "avenida Providencia número mil doscientos ocho")
    #expect(leer("viajó a EE.UU. ayer") == "viajó a Estados Unidos ayer")
  }

  @Test func siglas() {
    #expect(leer("la CMF y la PDI") == "la ce eme efe y la pe de i")
    #expect(leer("el SII") == "el ese i i")
    #expect(leer("la AFP Habitat") == "la a efe pe Habitat")
    #expect(leer("el BCI") == "el be ce i")
    // Las que se leen como palabra, se dejan.
    #expect(leer("el RUT y el IVA") == "el RUT y el IVA")
    #expect(leer("CORFO, FONASA y la PYME") == "CORFO, FONASA y la PYME")
    #expect(leer("la NASA") == "la NASA")
    // Un grito no es una sigla.
    #expect(leer("NO ME DIGAS ESO AHORA") == "NO ME DIGAS ESO AHORA")
  }

  @Test func loQueNoReconoceSeQuedaIgual() {
    let texto = "Hola, ¿cómo estás? Todo bien por acá."
    #expect(leer(texto) == texto)
    #expect(leer("escríbeme a ana@dilo.cl") == "escríbeme a ana arroba dilo.cl")
  }
}

struct TrozosParaLeerTests {
  @Test func porOracion() {
    let trozos = TrozosParaLeer.partir("Hola. ¿Cómo estás? ¡Qué bueno!\nNos vemos")
    #expect(trozos == ["Hola.", "¿Cómo estás?", "¡Qué bueno!", "Nos vemos"])
  }

  @Test func elPuntoDeUnDominioNoCorta() {
    #expect(TrozosParaLeer.partir("Entra a dilo.cl y mira.") == ["Entra a dilo.cl y mira."])
    #expect(TrozosParaLeer.partir("Bueno... ya veremos.") == ["Bueno...", "ya veremos."])
  }

  @Test func unaOracionLargaSeCortaEnLasComas() {
    let larga = (1...20).map { "palabra\($0)" }.joined(separator: " ")
      + ", y después " + (1...20).map { "otra\($0)" }.joined(separator: " ") + "."
    let trozos = TrozosParaLeer.partir(larga, maximo: 30, primero: 30)
    #expect(trozos.count == 2)
    #expect(trozos[0].hasSuffix(","))
    for trozo in trozos {
      #expect(trozo.split(separator: " ").count <= 30)
    }
  }

  @Test func sinPausasSeCortaAlTope() {
    let larga = (1...70).map { "p\($0)" }.joined(separator: " ")
    let trozos = TrozosParaLeer.partir(larga, maximo: 30, primero: 30)
    #expect(trozos.map { $0.split(separator: " ").count } == [30, 30, 10])
  }

  /// El caso del banco de voces: sin comas, la oración se cortaba entre
  /// «tres coma cinco» y «u efe». Ahora se corta antes del «y que».
  @Test func sinPausasSeCortaAntesDeUnaConjuncion() {
    let dicha = TextoParaLeer.preparar(
      "Le informamos que el pago de $1.250.000 vence el 15/03/2026 y que el saldo pendiente de 3,5 UF se cobrará en la cuota de abril."
    )
    let trozos = TrozosParaLeer.partir(dicha, maximo: 30, primero: 30)
    #expect(trozos.count == 2)
    #expect(trozos[1].hasPrefix("y que el saldo"))
    #expect(trozos.allSatisfy { !$0.hasPrefix("u efe") })
  }

  /// El primer trozo es corto para que el primer audio llegue antes; lo de
  /// después vuelve al tope de siempre.
  @Test func elPrimerTrozoEsCorto() {
    let texto = "Ayer en la tarde nos juntamos con el equipo para revisar cómo vamos con el proyecto y lo que falta. Después seguimos."
    let trozos = TrozosParaLeer.partir(texto)
    #expect(trozos[0].split(separator: " ").count <= TrozosParaLeer.palabrasDelPrimerTrozo)
    #expect(trozos.last == "Después seguimos.")
    #expect(trozos.joined(separator: " ") == texto)
  }

  @Test func nadaQueLeer() {
    #expect(TrozosParaLeer.partir("  \n ... \n").isEmpty)
  }
}

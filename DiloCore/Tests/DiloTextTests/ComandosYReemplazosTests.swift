import Testing

@testable import DiloText

/// Lo que se dice para puntuar o editar. Los casos que no deben cambiar
/// importan tanto como los que sí: «punto» y «coma» también son palabras, y
/// un comando que se dispara solo ensucia cada dictado normal.
struct ComandosDeFormatoTests {
  @Test(arguments: [
    ("hola coma cómo estás", "hola, cómo estás"),
    ("nos vemos mañana punto", "nos vemos mañana."),
    ("lista de compras nueva línea pan", "lista de compras\nPan"),
    ("primer párrafo punto aparte segundo párrafo", "primer párrafo.\n\nSegundo párrafo"),
    ("uno nuevo párrafo dos", "uno\n\nDos"),
    ("vienes mañana signo de interrogación", "¿vienes mañana?"),
    ("qué bueno signo de exclamación", "¡qué bueno!"),
    ("Hola Pedro. Te mando el informe borra eso", "Hola Pedro."),
    ("Listo. Te aviso mañana, bórralo.", "Listo."),
    ("esto no sirve, borra todo", ""),
    ("escribe literal nueva línea en el botón", "escribe nueva línea en el botón"),
    ("escríbele a ana arroba dilo punto cl", "escríbele a ana@dilo.cl"),
    ("hola, coma, cómo estás", "hola, cómo estás"),
    ("dijo abre comillas hola cierra comillas", "dijo “hola”"),
    ("y entonces puntos suspensivos", "y entonces…"),
    ("compra esto dos puntos nueva línea pan", "compra esto:\nPan"),
    ("abre paréntesis ojo cierra paréntesis", "(ojo)"),
    ("primero punto y coma segundo", "primero; segundo"),
    ("eso es todo punto y aparte", "eso es todo.\n\n"),
    ("son 2 coma 5 kilos", "son 2,5 kilos"),
    ("la versión 1 punto 2", "la versión 1.2"),
  ])
  func convierteLoQueSeDijo(dictado: String, esperado: String) {
    #expect(ComandosDeFormato.aplicar(dictado) == esperado)
  }

  @Test(arguments: [
    "llego a las cinco en punto con el informe",
    "desde mi punto de vista está bien",
    "llegamos al punto",
    "mi punto es que no",
    "dile que coma algo",
    "estuvo en coma",
    "borra eso del servidor",
    "ganamos por dos puntos",
    "dos coma cinco",
    "es literal lo que te digo",
    "hola  mundo",
    "¿tenís el commit listo?",
  ])
  func dejaLasPalabrasQueNoSonComandos(dictado: String) {
    #expect(ComandosDeFormato.aplicar(dictado) == dictado)
  }
}

struct ReemplazosTests {
  private let lista = [
    Reemplazo(dice: "chat ge pe te", escribe: "ChatGPT"),
    Reemplazo(dice: "chat", escribe: "CHAT"),
    Reemplazo(dice: "decameron", escribe: "Decameron"),
    Reemplazo(dice: "sap", escribe: "SAP"),
    Reemplazo(dice: "año", escribe: "AÑO"),
    Reemplazo(dice: "github", escribe: "github"),
    Reemplazo(dice: "uno", escribe: "dos"),
    Reemplazo(dice: "dos", escribe: "tres"),
    Reemplazo(dice: "   ", escribe: "nada"),
  ]

  @Test(arguments: [
    ("pregúntale a chat ge pe te", "pregúntale a ChatGPT"),
    ("pregúntale a chat  ge pe te", "pregúntale a ChatGPT"),
    ("abre el chat", "abre el CHAT"),
    ("el hotel decamerón de Cartagena", "el hotel Decameron de Cartagena"),
    ("sapé y sapo, pero sap sí", "sapé y sapo, pero SAP sí"),
    ("el ano y el año", "el ano y el AÑO"),
    ("Github es. Uso Github", "Github es. Uso github"),
    ("uno dos", "dos tres"),
    ("nada que cambiar", "nada que cambiar"),
  ])
  func reemplaza(dictado: String, esperado: String) {
    #expect(Reemplazos.aplicar(lista, a: dictado) == esperado)
  }

  @Test func sinListaNoTocaNada() {
    #expect(Reemplazos.aplicar([], a: "hola chat") == "hola chat")
  }
}

/// La capa de reglas entera, con los pasos nuevos en su orden.
struct CapaDeReglasTests {
  private let preferencias = DiloText.Preferencias(
    palabrasPropias: ["Decameron"],
    reemplazos: [Reemplazo(dice: "chat ge pe te", escribe: "ChatGPT")]
  )

  /// El comando va antes que la muletilla: «o sea coma» tiene que quedar
  /// «o sea,» para que la regla de la pausa lo saque.
  @Test func elComandoVaAntesQueLaMuletilla() {
    #expect(
      DiloText.limpiar("o sea coma pregúntale a chat ge pe te punto", con: preferencias)
        == "pregúntale a ChatGPT."
    )
  }

  @Test func tusPalabrasCorrigenEnLasDosLineas() {
    #expect(
      DiloText.limpiar("nos vemos en el decamerón nueva línea saludos desde el decamerón", con: preferencias)
        == "nos vemos en el Decameron\nSaludos desde el Decameron"
    )
  }

  @Test func sinComandosLosSignosNoCambian() {
    var sin = preferencias
    sin.comandosDeFormato = false
    #expect(DiloText.limpiar("hola coma cómo estás", con: sin) == "hola coma cómo estás")
  }

  @Test func deFabricaLosComandosVienenPrendidos() {
    #expect(DiloText.Preferencias.deFabrica.comandosDeFormato)
    #expect(DiloText.limpiar("hola nueva línea chao") == "hola\nChao")
  }
}

import Foundation
import Testing

@testable import DiloText

/// Aprender de lo que la persona corrigió: qué pares salen, cuáles se
/// descartan por cambiar el sentido, y que deshacer quite exactamente lo
/// agregado.
struct AprendizajeDeCorreccionesTests {
  /// El diccionario de prueba: lo que `NSSpellChecker` conocería.
  private let conocidas: Set<String> = ["lunes", "martes", "cuba", "José", "esta", "está", "dos", "tres"]
  private func conocida(_ palabra: String) -> Bool { conocidas.contains(palabra) }

  private func pares(_ pegado: String, _ editado: String) -> [ParDeCorreccion] {
    AprendizajeDeCorrecciones.pares(pegado: pegado, editado: editado, esPalabraConocida: conocida)
  }

  @Test func unNombreMalOidoSeAprende() {
    #expect(pares("revisa el deploy de cuba netes mañana", "revisa el deploy de Kubernetes mañana")
      == [ParDeCorreccion(oido: "cuba netes", correcto: "Kubernetes")])
  }

  @Test func unCambioDeIdeaNoSeAprende() {
    #expect(pares("nos vemos el lunes", "nos vemos el martes").isEmpty)
  }

  /// La tilde de José no se aprende; la marca con mayúscula adentro sí.
  @Test func laTildeNoYLaMarcaSi() {
    #expect(pares("habla con Jose de charge bee", "habla con José de ChargeBee")
      == [ParDeCorreccion(oido: "charge bee", correcto: "ChargeBee")])
  }

  @Test func unNombrePropioQueElDiccionarioNoConoce() {
    #expect(pares("mándale la cotización a decamerón", "mándale la cotización a Decameron")
      == [ParDeCorreccion(oido: "decamerón", correcto: "Decameron")])
  }

  @Test func soloOrtografiaNoSeAprende() {
    #expect(pares("esta listo", "está listo").isEmpty)
  }

  @Test func losNumerosYLasNegacionesNoSeTocan() {
    #expect(pares("son dos mil pesos", "son tres mil pesos").isEmpty)
    #expect(pares("son 2 mil pesos", "son 3 mil pesos").isEmpty)
    #expect(pares("no lo mandes", "si lo mandes").isEmpty)
    #expect(pares("nunca lo dije", "siempre lo dije").isEmpty)
  }

  @Test func unaReescrituraNoEsUnaCorreccion() {
    #expect(pares("mañana no puedo ir a la reunión", "te escribo después con más calma").isEmpty)
  }

  @Test func unTramoDeCuatroPalabrasNoCuenta() {
    #expect(pares(
      "dile a uno dos tres cuatro que venga",
      "dile a Kubernetes que venga"
    ).isEmpty)
  }

  @Test func unaMarcaPegadaSeAprende() {
    #expect(pares("usa post hog para eso", "usa PostHog para eso")
      == [ParDeCorreccion(oido: "post hog", correcto: "PostHog")])
  }

  @Test func losRepetidosSeColapsan() {
    #expect(pares("cuba netes y cuba netes", "Kubernetes y Kubernetes").count == 1)
  }

  /// Lo oído tiene que estar en lo que escribió el motor; si lo puso un modo
  /// o un reemplazo, no es un error de oído.
  @Test func soloLoQueOyoElMotor() {
    let candidatos = [
      ParDeCorreccion(oido: "cuba netes", correcto: "Kubernetes"),
      ParDeCorreccion(oido: "Estimado", correcto: "Querido"),
    ]
    let delMotor = AprendizajeDeCorrecciones.soloDelMotor(candidatos, crudo: "eh el deploy de Cuba netes, mañana")
    #expect(delMotor == [candidatos[0]])
    // Por palabras enteras: «net» no está en «planeta».
    #expect(AprendizajeDeCorrecciones.soloDelMotor(
      [ParDeCorreccion(oido: "net", correcto: "Net")], crudo: "el planeta"
    ).isEmpty)
  }

  @Test func laClaveFoneticaEsDeOidoEspanol() {
    #expect(AprendizajeDeCorrecciones.claveFonetica("cuba netes") == "kubanetes")
    #expect(AprendizajeDeCorrecciones.claveFonetica("Kubernetes") == "kubernetes")
    #expect(AprendizajeDeCorrecciones.claveFonetica("llave") == "yabe")
    #expect(AprendizajeDeCorrecciones.claveFonetica("queso") == "keso")
    #expect(AprendizajeDeCorrecciones.jaroWinkler("abc", "abc") == 1)
    #expect(AprendizajeDeCorrecciones.jaroWinkler("", "abc") == 0)
  }
}

struct CambioEnLoPegadoTests {
  @Test func unaEdicionDentroDeLoPegado() {
    #expect(CambioEnLoPegado.editado(
      base: "Hola. Revisa cuba netes hoy.",
      pegado: "Revisa cuba netes hoy.",
      actual: "Hola. Revisa Kubernetes hoy."
    ) == "Revisa Kubernetes hoy.")
  }

  @Test func unaEdicionFueraNoCuenta() {
    #expect(CambioEnLoPegado.editado(
      base: "Hola. Revisa algo.", pegado: "Revisa algo.", actual: "Chao. Revisa algo."
    ) == nil)
  }

  @Test func unaEdicionAcaballoDelBordeNoCuenta() {
    #expect(CambioEnLoPegado.editado(
      base: "Hola. Revisa algo.", pegado: "Revisa algo.", actual: "Hola, revisa algo."
    ) == nil)
  }

  /// Las apps devuelven el texto con otros finales de línea y espacios.
  @Test func losEspaciosRarosNoSonEdiciones() {
    #expect(CambioEnLoPegado.editado(
      base: "A\r\nRevisa cuba\u{00A0}netes.", pegado: "Revisa cuba netes.",
      actual: "A\nRevisa cuba netes."
    ) == nil)
    #expect(CambioEnLoPegado.editado(
      base: "A\r\nRevisa cuba\u{00A0}netes.", pegado: "Revisa cuba netes.",
      actual: "A\nRevisa Kubernetes.\u{200B}"
    ) == "Revisa Kubernetes.")
  }

  /// Pegado dos veces: cuenta la última, que es la de este dictado.
  @Test func pegadoDosVecesGanaLaUltima() {
    #expect(CambioEnLoPegado.editado(
      base: "di hola. di hola.", pegado: "di hola.", actual: "di hola. di Holanda."
    ) == "di Holanda.")
  }

  @Test func sinCambioNoHayNada() {
    #expect(CambioEnLoPegado.editado(base: "x hola", pegado: "hola", actual: "x hola") == nil)
  }
}

struct TusPalabrasAprendidasTests {
  private let par = ParDeCorreccion(oido: "cuba netes", correcto: "Kubernetes")

  @Test func aprenderVaATusPalabrasYACuandoDigo() {
    var palabras = ["Decameron"]
    var reemplazos: [Reemplazo] = []
    let hecho = TusPalabrasAprendidas.aprender([par], palabras: &palabras, reemplazos: &reemplazos)
    #expect(palabras == ["Decameron", "Kubernetes"])
    #expect(reemplazos == [Reemplazo(dice: "cuba netes", escribe: "Kubernetes", aprendido: true)])
    #expect(hecho.palabrasNuevas == ["Kubernetes"])
    // Y lo aprendido corrige el próximo dictado.
    #expect(Reemplazos.aplicar(reemplazos, a: "el deploy de cuba netes") == "el deploy de Kubernetes")
  }

  @Test func deshacerQuitaExactamenteLoAgregado() {
    var palabras = ["kubernetes"]
    var reemplazos = [Reemplazo(dice: "cuba netes", escribe: "Kuberneti")]
    let antes = (palabras, reemplazos)
    let hecho = TusPalabrasAprendidas.aprender([par], palabras: &palabras, reemplazos: &reemplazos)
    // La palabra ya estaba (sin importar mayúsculas): no se duplica.
    #expect(palabras == ["kubernetes"])
    #expect(hecho.reemplazosPisados == [Reemplazo(dice: "cuba netes", escribe: "Kuberneti")])
    TusPalabrasAprendidas.deshacer(hecho, palabras: &palabras, reemplazos: &reemplazos)
    #expect(palabras == antes.0)
    #expect(reemplazos == antes.1)
  }

  /// Un nombre que sólo cambió de mayúsculas va a Tus palabras y basta.
  @Test func soloMayusculasNoNecesitaReemplazo() {
    var palabras: [String] = []
    var reemplazos: [Reemplazo] = []
    _ = TusPalabrasAprendidas.aprender(
      [ParDeCorreccion(oido: "Decameron", correcto: "Decameron")], palabras: &palabras, reemplazos: &reemplazos
    )
    #expect(palabras == ["Decameron"])
    #expect(reemplazos.isEmpty)
  }

  @Test func elTopeDeLoAprendido() {
    var palabras: [String] = []
    var reemplazos = (0 ..< TusPalabrasAprendidas.tope).map {
      Reemplazo(dice: "dicho \($0)", escribe: "Escrito\($0)", aprendido: true)
    }
    let hecho = TusPalabrasAprendidas.aprender([par], palabras: &palabras, reemplazos: &reemplazos)
    #expect(hecho.reemplazosNuevos.isEmpty)
    #expect(reemplazos.count == TusPalabrasAprendidas.tope)
  }

  @Test func loQueYaSeSabeNoSeVuelveAOfrecer() {
    let reemplazos = [Reemplazo(dice: "Cuba Netes", escribe: "Kubernetes")]
    #expect(TusPalabrasAprendidas.yaSeSabe(par, palabras: [], reemplazos: reemplazos))
    #expect(!TusPalabrasAprendidas.yaSeSabe(
      ParDeCorreccion(oido: "cuba netes", correcto: "Kuberneti"), palabras: [], reemplazos: reemplazos
    ))
    let soloNombre = ParDeCorreccion(oido: "Decameron", correcto: "Decameron")
    #expect(TusPalabrasAprendidas.yaSeSabe(soloNombre, palabras: ["decameron"], reemplazos: []))
    #expect(!TusPalabrasAprendidas.yaSeSabe(soloNombre, palabras: [], reemplazos: []))
  }

  /// Un `diloReemplazos` de antes, sin la marca, se lee entero.
  @Test func unReemplazoViejoSeLeeSinMarca() throws {
    let viejo = Data(#"[{"dice":"chat ge pe te","escribe":"ChatGPT"}]"#.utf8)
    let leidos = try JSONDecoder().decode([Reemplazo].self, from: viejo)
    #expect(leidos == [Reemplazo(dice: "chat ge pe te", escribe: "ChatGPT")])
    #expect(leidos.first?.aprendido == false)
  }
}

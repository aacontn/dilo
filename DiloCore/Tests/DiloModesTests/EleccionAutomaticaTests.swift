import Foundation
import Testing

@testable import DiloModes

struct CalceDeSitioTests {
  @Test(arguments: [
    ("mail.google.com/mail/u/0", "mail.google.com/mail", true),
    ("mail.google.com/mailbox", "mail.google.com/mail", false),
    ("dropbox.com", "x.com", false),
    ("gist.github.com/a", "github.com", true),
    ("github.com/aacontn/dilo", "https://www.github.com", true),
    ("github.com", "*.github.com", true),
    ("GitHub.com/Aacontn", "github.com/aacontn", true),
    ("github.com/aacontn", "github.com/aacontn/dilo", false),
    ("github.com", "", false),
    ("", "github.com", false),
    ("github.com/a?tab=x", "github.com/a", true),
  ])
  func calza(sitio: String, patron: String, esperado: Bool) {
    #expect(CalceDeSitio.calza(sitio, con: patron) == esperado, "\(sitio) con \(patron)")
  }
}

struct PalabraDisparadoraTests {
  private let modos = Modo.deFabrica + [
    Modo(id: "formal", nombre: "Formal", prompt: "", disparadoras: ["como correo formal"]),
  ]

  @Test func alPrincipioSeVaYLaFraseArrancaConMayuscula() {
    let hallazgo = PalabraDisparadora.buscar(en: "Como correo: mañana no llego a la reunión", modos: modos)
    #expect(hallazgo?.modoID == "correo")
    #expect(hallazgo?.textoSinElla == "Mañana no llego a la reunión")
  }

  @Test func alFinalConservaElPunto() {
    let hallazgo = PalabraDisparadora.buscar(en: "Mañana no llego a la reunión, como mensaje.", modos: modos)
    #expect(hallazgo?.modoID == "mensaje")
    #expect(hallazgo?.textoSinElla == "Mañana no llego a la reunión.")
  }

  @Test func laMasLargaGana() {
    let hallazgo = PalabraDisparadora.buscar(en: "Mañana no llego, como correo formal.", modos: modos)
    #expect(hallazgo?.modoID == "formal")
    #expect(hallazgo?.textoSinElla == "Mañana no llego.")
  }

  @Test func enMedioNoCuenta() {
    #expect(PalabraDisparadora.buscar(en: "mándale como correo a Pedro mañana", modos: modos) == nil)
    #expect(PalabraDisparadora.buscar(en: "mándale un correo a Pedro", modos: modos) == nil)
  }

  /// Sin tildes ni mayúsculas: el motor escribe «Código» o «codigo».
  @Test func lasTildesNoImportan() {
    let hallazgo = PalabraDisparadora.buscar(en: "git status y push, como codigo", modos: modos)
    #expect(hallazgo?.modoID == "codigo")
    #expect(hallazgo?.textoSinElla == "git status y push")
  }

  /// Un dictado que es sólo la frase no elige nada: no queda qué pegar.
  @Test func soloLaFraseNoEsUnHallazgo() {
    #expect(PalabraDisparadora.buscar(en: "como correo", modos: modos) == nil)
  }

  /// La frase al final después de un punto: lo de antes ya cerraba.
  @Test func trasUnPuntoNoSeDuplicaElCierre() {
    let hallazgo = PalabraDisparadora.buscar(en: "Nos vemos mañana. Como correo.", modos: modos)
    #expect(hallazgo?.textoSinElla == "Nos vemos mañana.")
  }
}

struct EleccionAlTerminarTests {
  private let modos = Modo.deFabrica

  private func elegir(
    _ texto: String,
    aLaMano: ResolucionDeModo.ALaMano = .nadie,
    hover: String? = nil,
    app: String? = nil,
    bundle: String? = nil,
    sitio: String? = nil,
    diloDecide: Bool = true
  ) async -> (ResolucionDeModo.Eleccion, String) {
    await ResolucionDeModo.alTerminar(
      texto: texto,
      aLaMano: aLaMano,
      delAtajoGeneral: modos.modo(hover),
      contexto: ContextoDeDecision(appAlFrente: app, bundleID: bundle, sitio: sitio),
      modos: modos,
      unAtajoDiloDecide: diloDecide,
      decider: DeciderPorReglas(modos: modos)
    )
  }

  @Test func laTeclaLeGanaATodo() async {
    let (eleccion, texto) = await elegir("hola, como correo", aLaMano: .eligio(modos.modo("mensaje")))
    #expect(eleccion.modo?.id == "mensaje")
    #expect(eleccion.razon == .atajo)
    #expect(texto == "hola, como correo")
  }

  /// «Sin modo» elegido con las flechas también es elegir.
  @Test func sinModoAProposito() async {
    let (eleccion, _) = await elegir("hola, como correo", aLaMano: .eligio(nil), app: "Ghostty")
    #expect(eleccion.modo == nil)
  }

  @Test func laFraseLeGanaAlHoverAlSitioYALaApp() async {
    let (eleccion, texto) = await elegir(
      "mañana no llego, como correo", hover: "mensaje", app: "Ghostty", sitio: "github.com"
    )
    #expect(eleccion.modo?.id == "correo")
    #expect(eleccion.senal == .palabra("como correo"))
    #expect(eleccion.enLaMuesca == "Correo · lo dijiste")
    #expect(eleccion.razon.explicacion == "Dilo lo eligió: dijiste «como correo»")
    #expect(texto == "mañana no llego")
  }

  /// La frase funciona aunque «Dilo decide» esté apagado: es explícita.
  @Test func laFraseNoNecesitaADiloDecide() async {
    let (eleccion, _) = await elegir("arregla el build, como código", diloDecide: false)
    #expect(eleccion.modo?.id == "codigo")
  }

  @Test func elHoverLeGanaAlSitio() async {
    let (eleccion, _) = await elegir("hola", hover: "mensaje", sitio: "github.com/aacontn/dilo")
    #expect(eleccion.modo?.id == "mensaje")
    #expect(eleccion.razon == .atajo)
  }

  @Test func elSitioLeGanaALaApp() async {
    let (eleccion, _) = await elegir("hola", app: "Google Chrome", bundle: "com.google.Chrome", sitio: "github.com/aacontn/dilo")
    #expect(eleccion.modo?.id == "codigo")
    #expect(eleccion.senal == .sitio("github.com/aacontn/dilo"))
    #expect(eleccion.enLaMuesca == "Código · por el sitio")
    #expect(eleccion.razon.explicacion == "Dilo lo eligió: estabas en github.com/aacontn/dilo")
  }

  @Test func sinDiloDecideNiSitioNiApp() async {
    let (eleccion, _) = await elegir("hola", app: "Ghostty", sitio: "github.com", diloDecide: false)
    #expect(eleccion.modo == nil)
  }

  @Test func laAppSigueEligiendoPorNombre() async {
    let (eleccion, _) = await elegir("hola", app: "WhatsApp")
    #expect(eleccion.modo?.id == "mensaje")
    #expect(eleccion.senal == .app("WhatsApp"))
  }

  /// Un modo que nombra la app por bundle id calza exacto.
  @Test func unBundleIDCalzaExacto() async {
    var conBundle = modos
    conBundle.append(Modo(id: "notas", nombre: "Notas", prompt: "", apps: ["com.apple.Notes"]))
    let decider = DeciderPorReglas(modos: conBundle)
    let respuesta = decider.decidirAhora(
      "hola", .eleccion(conBundle.map(\.id)),
      en: ContextoDeDecision(appAlFrente: "Notas", bundleID: "com.apple.notes")
    )
    #expect(respuesta.valor == "notas")
    #expect(respuesta.probabilidad == 0.95)
    let otra = decider.decidirAhora(
      "hola", .eleccion(conBundle.map(\.id)),
      en: ContextoDeDecision(appAlFrente: "Notas", bundleID: "com.apple.notesx")
    )
    #expect(otra.valor != "notas" || otra.probabilidad < 0.95)
  }

  /// Dos modos con el mismo sitio no deciden: pasa a la app.
  @Test func dosModosConElMismoSitioNoDeciden() {
    let dos = [
      Modo(id: "a", nombre: "A", prompt: "", sitios: ["github.com"]),
      Modo(id: "b", nombre: "B", prompt: "", sitios: ["github.com/aacontn"]),
    ]
    #expect(EleccionAutomatica.porSitio("github.com/aacontn/dilo", modos: dos) == nil)
    #expect(EleccionAutomatica.porSitio("github.com/otro", modos: dos)?.id == "a")
  }
}

struct SenalesDeLosModosTests {
  /// Un `diloModos` guardado antes de que existieran sitios y frases se lee
  /// entero, con las listas vacías.
  @Test func unModoViejoSeLeeSinSitiosNiFrases() throws {
    let viejo = Data(#"[{"id":"correo","nombre":"Correo","prompt":"x","esDeFabrica":true}]"#.utf8)
    let leidos = try JSONDecoder().decode([Modo].self, from: viejo)
    #expect(leidos.first?.sitios == [])
    #expect(leidos.first?.disparadoras == [])
  }

  @Test func losDeFabricaTraenFrasesAlFinal() {
    for id in ["correo", "mensaje", "prompt", "codigo"] {
      #expect(Modo.deFabrica.modo(id)?.disparadoras.first?.hasPrefix("como ") == true, "\(id)")
    }
  }

  /// La pasada única: a los de fábrica sin señales se les suman las de
  /// fábrica; a uno editado o propio no se le toca nada.
  @Test func sumarSenalesSoloAlDeFabricaQueNoLasTiene() {
    var viejoCorreo = Modo.deFabrica.modo("correo")!
    viejoCorreo.sitios = []
    viejoCorreo.disparadoras = []
    var editado = Modo.deFabrica.modo("mensaje")!
    editado.sitios = []
    editado.disparadoras = ["por chat"]
    let propio = Modo(id: "x", nombre: "X", prompt: "")
    let resultado = MigracionDeModos.sumarSenalesDeFabrica([viejoCorreo, editado, propio])
    #expect(resultado[0].disparadoras == ["como correo"])
    #expect(resultado[0].sitios.contains("mail.google.com"))
    #expect(resultado[1].disparadoras == ["por chat"])
    #expect(resultado[1].sitios.isEmpty)
    #expect(resultado[2] == propio)
  }
}

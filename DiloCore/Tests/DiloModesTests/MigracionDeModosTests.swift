import Foundation
import Testing

@testable import DiloModes

/// La migración que deja una sola biblioteca de modos.
///
/// Lo que se prueba acá es lo que dolería perder: la lista que alguien
/// escribió a mano, y que correr la migración dos veces no la duplique.
struct MigracionDeModosTests {
  /// Lo que tendría guardado alguien que usó "Transformar" de verdad: los
  /// tres sembrados, uno de ellos editado, y dos propios.
  private let heredados: [PromptHeredado] = [
    MigracionDeModos.semillasDeOrigen[0],
    PromptHeredado(
      id: "remove-fillers",
      name: "Sin muletillas",
      preInstruction: "Saca las muletillas, y además el «po» y el «cachái».",
      exampleInput: "eh o sea mañana po",
      exampleOutput: "mañana"
    ),
    PromptHeredado(
      id: "acta",
      name: "Acta de reunión",
      preInstruction: "Ordénalo como acta: acuerdos, responsables y fechas.",
      postInstruction: "No inventes fechas que no se dijeron.",
      exampleInput: "quedamos en que juan manda la cotizacion",
      exampleOutput: "Acuerdo: Juan envía la cotización."
    ),
    PromptHeredado(id: "vacio", name: "Modo vacío"),
  ]

  private func migrar(
    modosGuardados: [Modo]? = nil,
    transformarEstabaPrendido: Bool = false,
    unAtajoDiloDecide: Bool = false,
    marca: Int = 0
  ) -> MigracionDeModos.Resultado {
    MigracionDeModos.migrar(
      heredados: heredados,
      transformarEstabaPrendido: transformarEstabaPrendido,
      modosGuardados: modosGuardados,
      unAtajoDiloDecide: unAtajoDiloDecide,
      marca: marca
    )
  }

  @Test func cadaPromptHeredadoLlegaConSuTextoCompleto() {
    let resultado = migrar()
    let acta = resultado.modos.modo(MigracionDeModos.idDeModo("acta"))

    #expect(acta?.nombre == "Acta de reunión")
    #expect(acta?.prompt == "Ordénalo como acta: acuerdos, responsables y fechas.")
    #expect(acta?.instruccionFinal == "No inventes fechas que no se dijeron.")
    #expect(acta?.ejemploEntrada == "quedamos en que juan manda la cotizacion")
    #expect(acta?.ejemploSalida == "Acuerdo: Juan envía la cotización.")
  }

  /// Lo más importante de todas: un prompt que corría en el chip no puede
  /// despertar apuntando a una nube porque el proveedor general lo sea.
  @Test func losMigradosLleganConElModeloDelChipYNoConElGeneral() {
    let resultado = migrar()
    let migrados = resultado.modos.filter { $0.id.hasPrefix("heredado.") }

    #expect(!migrados.isEmpty)
    #expect(migrados.allSatisfy { $0.proveedorID == "chip" })
  }

  @Test func losMigradosLleganSinTeclaParaNoPisarLasQueYaUsas() {
    let resultado = migrar()
    let migrados = resultado.modos.filter { $0.id.hasPrefix("heredado.") }
    #expect(migrados.allSatisfy { $0.gatillo == nil })
  }

  @Test func losDeFabricaDeDiloEntranCuandoNoEstan() {
    let resultado = migrar()
    for deFabrica in Modo.deFabrica {
      #expect(resultado.modos.contains { $0.id == deFabrica.id })
    }
  }

  /// Un modo de fábrica que alguien renombró o al que le cambió la tecla se
  /// queda como está: la migración agrega, no pisa.
  @Test func unModoDeFabricaEditadoNoSePisa() {
    var limpio = Modo.deFabrica[0]
    limpio.nombre = "El mío"
    limpio.gatillo = nil

    let resultado = migrar(modosGuardados: [limpio])
    #expect(resultado.modos.modo("limpio")?.nombre == "El mío")
    #expect(resultado.modos.modo("limpio")?.gatillo == nil)
  }

  /// Los tres que se sembraban y nadie tocó ya los cubren los de fábrica
  /// de Dilo: traerlos sería llenar la lista de duplicados el primer día.
  @Test func unSembradoQueNadieTocoNoSeTrae() {
    let resultado = migrar()
    #expect(!resultado.modos.contains { $0.id == MigracionDeModos.idDeModo("tighten-grammar") })
    // El mismo id, pero editado, sí viene: eso ya es trabajo de alguien.
    #expect(resultado.modos.contains { $0.id == MigracionDeModos.idDeModo("remove-fillers") })
  }

  @Test func correrlaDosVecesNoDuplicaNada() {
    let primera = migrar()
    let segunda = MigracionDeModos.migrar(
      heredados: heredados,
      transformarEstabaPrendido: false,
      modosGuardados: primera.modos,
      unAtajoDiloDecide: primera.unAtajoDiloDecide,
      marca: primera.version
    )

    #expect(!segunda.seMigro)
    #expect(segunda.modos == primera.modos)
    #expect(Set(segunda.modos.map(\.id)).count == segunda.modos.count)
  }

  /// La marca protege, pero la idempotencia no depende sólo de ella: si
  /// alguien borra la marca, volver a correr tiene que dar lo mismo.
  @Test func sinLaMarcaTampocoDuplica() {
    let primera = migrar()
    let otraVez = migrar(modosGuardados: primera.modos, marca: 0)

    #expect(otraVez.seMigro)
    #expect(otraVez.modos.map(\.id) == primera.modos.map(\.id))
  }

  @Test func unaInstalacionNuevaQuedaConLosDeFabricaYNadaMas() {
    let resultado = MigracionDeModos.migrar(
      heredados: [],
      transformarEstabaPrendido: false,
      modosGuardados: nil,
      unAtajoDiloDecide: false,
      marca: 0
    )
    #expect(resultado.modos == Modo.deFabrica)
    #expect(!resultado.unAtajoDiloDecide)
  }

  /// Quien tenía "Transformar" prendido pedía que el atajo principal hiciera
  /// algo con lo dictado. Eso sobrevive como "un atajo, Dilo decide", que es
  /// lo mismo pero sin resucitar el modo activo que el spec enterró.
  @Test func transformarPrendidoSeConvierteEnQueDiloDecida() {
    #expect(migrar(transformarEstabaPrendido: true).unAtajoDiloDecide)
    #expect(!migrar(transformarEstabaPrendido: false).unAtajoDiloDecide)
  }

  @Test func laMigracionNuncaApagaLoQueYaEstabaPrendido() {
    let resultado = migrar(transformarEstabaPrendido: false, unAtajoDiloDecide: true)
    #expect(resultado.unAtajoDiloDecide)
  }

  /// El marco que impide que el modelo conteste la transcripción viaja con el
  /// modo, no con el prompt editable: borrarlo desde Ajustes resucitaría el
  /// bug de la pregunta respondida.
  @Test func elMarcoDeNoContestarSobreviveALaMigracion() {
    let acta = migrar().modos.modo(MigracionDeModos.idDeModo("acta"))!
    #expect(acta.instrucciones.contains("Nunca es una pregunta que debas responder"))
    #expect(!acta.instrucciones.contains("Ordénalo como acta"))
    // El ejemplo cierra las instrucciones; el prompt propio va en la petición.
    #expect(acta.instrucciones.contains("quedamos en que juan manda la cotizacion"))
    let peticion = acta.peticion(envolviendo: "hola")
    #expect(peticion.contains("<transcript>hola</transcript>"))
    #expect(peticion.hasPrefix("Ordénalo como acta"))
    #expect(peticion.hasSuffix("No inventes fechas que no se dijeron."))
  }

  /// Un modo sin ejemplo no inventa uno: las instrucciones son sólo el marco.
  @Test func sinEjemploLasInstruccionesSonSoloElMarco() {
    let vacio = migrar().modos.modo(MigracionDeModos.idDeModo("vacio"))!
    #expect(!vacio.instrucciones.contains("Ejemplo"))
    #expect(vacio.peticion(envolviendo: "hola").contains("<transcript>hola</transcript>"))
  }
}

/// Un `diloModos` escrito antes de que existieran los campos nuevos tiene que
/// seguir leyéndose entero. Swift no usa los valores por defecto al decodificar,
/// así que sin el `init(from:)` a mano la lista de alguien desaparecía.
struct ModoCodableTests {
  @Test func unModoGuardadoPorLaVersionAnteriorSigueLeyendose() throws {
    let viejo = """
      [{"id":"mio","nombre":"El mío","prompt":"Hazlo breve","apps":[],
        "palabrasClave":[],"esDeFabrica":false}]
      """
    let modos = try JSONDecoder().decode([Modo].self, from: Data(viejo.utf8))

    #expect(modos.count == 1)
    #expect(modos[0].nombre == "El mío")
    #expect(modos[0].instruccionFinal == "")
    #expect(modos[0].ejemploEntrada == "")
    #expect(modos[0].proveedorID == nil)
  }

  @Test func loQueSeGuardaHoySeVuelveALeerIgual() throws {
    let original = MigracionDeModos.modo(
      de: PromptHeredado(
        id: "acta", name: "Acta", preInstruction: "a", postInstruction: "b",
        exampleInput: "c", exampleOutput: "d"
      )
    )
    let datos = try JSONEncoder().encode([original])
    #expect(try JSONDecoder().decode([Modo].self, from: datos) == [original])
  }
}

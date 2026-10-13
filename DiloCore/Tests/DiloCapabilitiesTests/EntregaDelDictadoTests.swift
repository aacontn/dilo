import Foundation
import Testing

@testable import DiloCapabilities

struct AcuseDeLecturaTests {
  @Test func unaLecturaDespuesDelAtajoCuenta() {
    var acuse = AcuseDeLectura()
    acuse.despachar()
    acuse.anotarLectura(en: .milliseconds(120))
    #expect(acuse.primeraLectura == .milliseconds(120))
    #expect(!acuse.lecturaQueNoCuenta)
  }

  /// Antes del ⌘V lee un gestor de portapapeles, no la app de destino.
  @Test func unaLecturaAntesDelAtajoNoCuenta() {
    var acuse = AcuseDeLectura()
    acuse.anotarLectura(en: .milliseconds(10))
    acuse.despachar()
    #expect(acuse.primeraLectura == nil)
    #expect(acuse.lecturaQueNoCuenta)
  }

  @Test func unaLecturaQueNoPareceUnPegadoNoCuenta() {
    var acuse = AcuseDeLectura()
    acuse.despachar()
    acuse.anotarLectura(en: .milliseconds(10), pareceUnPegado: false)
    #expect(acuse.primeraLectura == nil)
  }

  /// La primera lectura es la del pegado; Electron lee dos veces y la
  /// segunda no corre la gracia.
  @Test func cuentaLaPrimeraLectura() {
    var acuse = AcuseDeLectura()
    acuse.despachar()
    acuse.anotarLectura(en: .milliseconds(100))
    acuse.anotarLectura(en: .milliseconds(400))
    #expect(acuse.primeraLectura == .milliseconds(100))
  }

  @Test func detenidoNoAnotaNada() {
    var acuse = AcuseDeLectura()
    acuse.despachar()
    acuse.detener()
    acuse.anotarLectura(en: .milliseconds(100))
    #expect(acuse.primeraLectura == nil)
    #expect(!acuse.lecturaQueNoCuenta)
  }
}

struct PlanDeDevolucionTests {
  /// Sin señal se espera lo que dura la tarjeta; si la persona pega a mano
  /// en el medio, lo suyo vuelve medio segundo después.
  @Test func unaLecturaAdelantaLaEspera() {
    var plan = PlanDeDevolucion(limite: .seconds(10), motivo: .trasEsperar)
    plan.anotarLectura(en: .seconds(3), gracia: .milliseconds(500))
    #expect(plan.limite == .milliseconds(3_500))
    #expect(plan.motivo == .trasLectura)
  }

  @Test func unaLecturaNuncaHaceEsperarMas() {
    var plan = PlanDeDevolucion(limite: .seconds(2), motivo: .trasEsperar)
    plan.anotarLectura(en: .seconds(3), gracia: .milliseconds(500))
    #expect(plan.limite == .seconds(2))
    #expect(plan.motivo == .trasEsperar)
  }

  @Test func unPlanTrasElCampoNoSeMueve() {
    var plan = PlanDeDevolucion(limite: .seconds(1), motivo: .trasConfirmarElCampo)
    plan.anotarLectura(en: .milliseconds(100), gracia: .milliseconds(100))
    #expect(plan.limite == .seconds(1))
    #expect(plan.motivo == .trasConfirmarElCampo)
  }
}

struct VigiaDelPegadoTests {
  private let tiempos = TiemposDePegado.deFabrica

  /// Corre el vigía con un reloj que avanza lo que pida dormir, y una foto
  /// del campo por instante.
  private func correr(
    verificaElCampo: Bool,
    lecturaEn: Duration? = nil,
    dejaDeSerDeDiloEn: Duration? = nil,
    veredicto: (Duration) -> VeredictoDelCampo = { _ in .noCambio },
    huboEntrada: Bool = false
  ) -> (senal: SenalDeEntrega, fin: Duration, lecturasDelCampo: [Duration]) {
    var vigia = VigiaDelPegado(inicio: .zero, tiempos: tiempos, verificaElCampo: verificaElCampo)
    var ahora = Duration.zero
    var lecturas: [Duration] = []
    for _ in 0..<10_000 {
      let lectura = lecturaEn.flatMap { ahora >= $0 ? $0 : nil }
      let esDeDilo = dejaDeSerDeDiloEn.map { ahora < $0 } ?? true
      switch vigia.siguiente(
        ahora: ahora, esDeDilo: esDeDilo, lectura: lectura,
        huboEntradaDeLaPersona: { huboEntrada }
      ) {
      case let .terminar(senal): return (senal, ahora, lecturas)
      case .leerElCampo:
        lecturas.append(ahora)
        vigia.anotar(veredicto(ahora))
      case let .esperar(duracion):
        #expect(duracion > .zero)
        ahora += duracion
      }
    }
    Issue.record("el vigía no terminó nunca")
    return (.sinSenal, ahora, lecturas)
  }

  @Test func elAcuseTerminaEnCuantoLlega() {
    let resultado = correr(verificaElCampo: false, lecturaEn: .milliseconds(120))
    #expect(resultado.senal == .leido(en: .milliseconds(120)))
    #expect(resultado.fin < .milliseconds(200))
  }

  @Test func sinNadaEsperaLaVentanaEntera() {
    let resultado = correr(verificaElCampo: false)
    #expect(resultado.senal == .sinSenal)
    #expect(resultado.fin == tiempos.ventana)
  }

  @Test func siOtroEscribeEnElPortapapelesNoSeTocaNada() {
    let resultado = correr(verificaElCampo: false, dejaDeSerDeDiloEn: .milliseconds(300))
    #expect(resultado.senal == .ajeno)
  }

  /// Las lecturas del campo caen a los 150, 500 y 1 500 ms, ni antes ni
  /// mucho después: el vigía no duerme de más.
  @Test func elCampoSeLeeALosTiemposDichos() {
    let resultado = correr(verificaElCampo: true)
    #expect(resultado.lecturasDelCampo == tiempos.lecturasDelCampo)
  }

  @Test func siElCampoCambioTerminaAlTiro() {
    let resultado = correr(verificaElCampo: true, veredicto: { $0 >= .milliseconds(500) ? .entro : .noSeSabe })
    #expect(resultado.senal == .campoCambio)
    #expect(resultado.fin == .milliseconds(500))
  }

  /// «No entró» pide las tres lecturas con «no cambió» la última, y que la
  /// persona no haya tocado nada.
  @Test func elCampoIgualPideTodasLasLecturasYQuietud() {
    #expect(correr(verificaElCampo: true).senal == .campoIgual)
    #expect(correr(verificaElCampo: true, huboEntrada: true).senal == .sinSenal)
    #expect(correr(verificaElCampo: true, veredicto: { $0 < .seconds(1) ? .noCambio : .noSeSabe }).senal == .sinSenal)
  }

  /// Un acuse tardío gana aunque el campo diga que no cambió: el campo
  /// puede actualizarse tarde en Accesibilidad, la lectura no miente.
  @Test func elAcuseGanaSobreElCampo() {
    let resultado = correr(verificaElCampo: true, lecturaEn: .milliseconds(700))
    #expect(resultado.senal == .leido(en: .milliseconds(700)))
  }
}

struct DecisionTrasLaSenalTests {
  private let tiempos = TiemposDePegado.deFabrica

  @Test func trasElAcuseSeDevuelveConLaGracia() {
    let decision = DecisionTrasLaSenal.para(
      .leido(en: .milliseconds(100)), ahora: .milliseconds(150), tiempos: tiempos, puedeTeclear: true)
    #expect(decision == .terminar(
      .pegado(.lectura), PlanDeDevolucion(limite: .milliseconds(600), motivo: .trasLectura)))
  }

  @Test func sinSenalElDictadoSeQuedaLoQueDuraLaTarjeta() {
    let decision = DecisionTrasLaSenal.para(
      .sinSenal, ahora: .seconds(2), tiempos: tiempos, puedeTeclear: true)
    #expect(decision == .terminar(
      .pegadoSinConfirmar, PlanDeDevolucion(limite: .seconds(10), motivo: .trasEsperar)))
  }

  @Test func loAjenoNoSeToca() {
    let decision = DecisionTrasLaSenal.para(.ajeno, ahora: .seconds(1), tiempos: tiempos, puedeTeclear: true)
    #expect(decision == .terminar(.pegadoSinConfirmar, nil))
  }

  @Test func elCampoIgualSeTecleaSoloSiSePuede() {
    #expect(DecisionTrasLaSenal.para(.campoIgual, ahora: .seconds(2), tiempos: tiempos, puedeTeclear: true)
      == .reintentarTecleando)
    #expect(DecisionTrasLaSenal.para(.campoIgual, ahora: .seconds(2), tiempos: tiempos, puedeTeclear: false)
      == .terminar(.retenido(.noEntro), PlanDeDevolucion(limite: .seconds(10), motivo: .trasEsperar)))
  }

  @Test func trasTeclearElVeredictoDecide() {
    #expect(DecisionTrasLaSenal.trasTeclear(.entro, ahora: .seconds(3), tiempos: tiempos)
      == .terminar(.pegado(.tecleo), PlanDeDevolucion(limite: .seconds(3), motivo: .trasConfirmarElCampo)))
    #expect(DecisionTrasLaSenal.trasTeclear(.noCambio, ahora: .seconds(3), tiempos: tiempos)
      == .terminar(.retenido(.noEntro), PlanDeDevolucion(limite: .seconds(11), motivo: .trasEsperar)))
    #expect(DecisionTrasLaSenal.trasTeclear(.noSeSabe, ahora: .seconds(3), tiempos: tiempos)
      == .terminar(.pegadoSinConfirmar, PlanDeDevolucion(limite: .seconds(11), motivo: .trasEsperar)))
  }

  @Test func soloLoRetenidoNoLlego() {
    #expect(ResultadoDeEntrega.pegado(.lectura).llego)
    #expect(ResultadoDeEntrega.pegadoSinConfirmar.llego)
    #expect(ResultadoDeEntrega.copiado.llego)
    #expect(ResultadoDeEntrega.nadaQueEntregar.llego)
    for motivo in MotivoParaNoPegar.allCases {
      #expect(!ResultadoDeEntrega.retenido(motivo).llego)
    }
  }
}

struct VeredictoDelCampoTests {
  @Test func entroPorLaSonda() {
    let antes = FotoDelCampo(conteo: 5, valor: "hola ", seleccion: .init(ubicacion: 5, largo: 0))
    let despues = FotoDelCampo(conteo: 15, valor: "hola qué tal", seleccion: nil)
    #expect(VeredictoDelCampo.comparar(antes: antes, despues: despues, texto: "qué tal") == .entro)
  }

  @Test func entroPorElCursor() {
    let antes = FotoDelCampo(seleccion: .init(ubicacion: 10, largo: 0))
    let despues = FotoDelCampo(seleccion: .init(ubicacion: 17, largo: 0))
    #expect(VeredictoDelCampo.comparar(antes: antes, despues: despues, texto: "qué tal") == .entro)
  }

  @Test func entroPorElConteo() {
    #expect(VeredictoDelCampo.comparar(
      antes: FotoDelCampo(conteo: 40_000), despues: FotoDelCampo(conteo: 40_007), texto: "qué tal"
    ) == .entro)
  }

  /// Lo mismo dictado dos veces: cuenta apariciones, no «antes no estaba».
  @Test func loMismoDosVecesSeCuenta() {
    let antes = FotoDelCampo(valor: "listo")
    let despues = FotoDelCampo(valor: "listo listo")
    #expect(VeredictoDelCampo.comparar(antes: antes, despues: despues, texto: "listo") == .entro)
  }

  @Test func nadaSeMovioEsNoCambio() {
    let foto = FotoDelCampo(conteo: 5, valor: "hola ", seleccion: .init(ubicacion: 5, largo: 0))
    #expect(VeredictoDelCampo.comparar(antes: foto, despues: foto, texto: "qué tal") == .noCambio)
    let sinValor = FotoDelCampo(conteo: 30_000, seleccion: .init(ubicacion: 5, largo: 0))
    #expect(VeredictoDelCampo.comparar(antes: sinValor, despues: sinValor, texto: "qué tal") == .noCambio)
  }

  /// El pegado reemplazó una selección más larga: el conteo baja y eso no
  /// prueba nada.
  @Test func elConteoQueBajaNoSeSabe() {
    let antes = FotoDelCampo(conteo: 50, seleccion: .init(ubicacion: 0, largo: 50))
    let despues = FotoDelCampo(conteo: 7, seleccion: .init(ubicacion: 3, largo: 0))
    #expect(VeredictoDelCampo.comparar(antes: antes, despues: despues, texto: "qué tal") == .noSeSabe)
  }

  @Test func sinNadaLegibleNoSeSabe() {
    #expect(VeredictoDelCampo.comparar(antes: FotoDelCampo(), despues: FotoDelCampo(), texto: "hola") == .noSeSabe)
    let foto = FotoDelCampo(valor: "hola")
    #expect(VeredictoDelCampo.comparar(antes: foto, despues: foto, texto: "") == .noSeSabe)
  }
}

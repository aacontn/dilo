import Testing

@testable import Dilo

/// Quién se sienta dónde en la muesca: una forma y hasta dos costados.
///
/// El reductor es puro, así que todo se afirma sin ventana. Las reglas que
/// cargan peso son dos que vienen del contrato del notch —quien habla se
/// lleva la forma, y una grabación nunca se esconde— y una de oficio: dos
/// fuentes iguales no se turnan el costado cada vez que se actualizan.
@Suite("Asientos de la muesca")
struct AsientosDeLaMuescaTests {
  /// Una reunión grabando, la de verdad (`ActividadDeLaMuesca.reunion`):
  /// abre el micrófono pero le cede la forma al dictado.
  private let reunion = ActividadDeLaMuesca.reunion

  private func costado(_ id: String, _ prioridad: PrioridadDeActividad = .normal, lado: LadoDelAsiento? = nil)
    -> ActividadDeLaMuesca
  {
    ActividadDeLaMuesca(id: id, prioridad: prioridad, puedeSerPrincipal: false, ladoPreferido: lado)
  }

  private var dictado: ActividadDeLaMuesca { .sesion(escuchando: true) }

  /// Dictando, la reunión baja a la izquierda: la derecha es de la toma que
  /// quedó para reintentar, y las dos caben sin turnarse.
  @Test func dictandoLaReunionVaALaIzquierdaYLaTomaALaDerecha() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(reunion))
    a.recibir(.publicar(.tomaGuardada))
    #expect(a.principal?.id == "reunion")
    a.recibir(.publicar(dictado))
    #expect(a.principal?.id == "sesion")
    #expect(a.asiento(de: "reunion") == .costado(.izquierda))
    #expect(a.asiento(de: "toma") == .costado(.derecha))
    // Terminado el dictado, la reunión vuelve a la forma.
    a.recibir(.retirar(id: "sesion"))
    #expect(a.principal?.id == "reunion")
  }

  @Test func sinNadiePublicadoLaMuescaDescansa() {
    let asientos = AsientosDeLaMuesca()
    #expect(asientos.principal == nil)
    #expect(asientos.costado(.derecha) == nil)
    #expect(asientos.costado(.izquierda) == nil)
  }

  /// Lo que sólo puede ser costado nunca toma la forma, aunque esté sola.
  @Test func unCostadoSoloNoTomaLaForma() {
    var asientos = AsientosDeLaMuesca()
    asientos.recibir(.publicar(.tomaGuardada))
    #expect(asientos.principal == nil)
    #expect(asientos.asiento(de: "toma") == .costado(.derecha))
  }

  /// El recorrido del ejecutable de prueba del plan: datos → reunión →
  /// dictado → sin lugar → pantalla completa → fin del dictado.
  @Test func elDictadoSeLlevaLaFormaYLaReunionNuncaSeEsconde() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(costado("dato.claude", .baja, lado: .izquierda)))
    a.recibir(.publicar(costado("dato.cpu", .baja, lado: .derecha)))
    #expect(a.costado(.izquierda)?.id == "dato.claude")
    #expect(a.costado(.derecha)?.id == "dato.cpu")

    a.recibir(.publicar(reunion))
    #expect(a.principal?.id == "reunion")

    // Empieza un dictado: se lleva la forma, y la reunión baja a un costado
    // desplazando a un dato, que se entera de por qué.
    let cambios = a.recibir(.publicar(dictado))
    #expect(a.principal?.id == "sesion")
    #expect(Self.esCostado(a.asiento(de: "reunion")))
    #expect(cambios.contains { $0.ahora == .ninguno && $0.motivo == .superada })

    // Sin lugar para costados, la reunión sigue a la vista.
    a.recibir(.lugaresAlCostado(0))
    #expect(Self.esCostado(a.asiento(de: "reunion")))
    #expect(a.asiento(de: "dato.cpu") == .ninguno)
    #expect(a.motivos["dato.cpu"] == .pantallaSinLugar)

    // Pantalla completa: sólo lo que nunca se esconde.
    a.recibir(.lugaresAlCostado(2))
    a.recibir(.suprimir(true))
    #expect(a.asiento(de: "dato.claude") == .ninguno)
    #expect(a.motivos["dato.claude"] == .suprimida)
    #expect(a.principal?.id == "sesion")
    #expect(Self.esCostado(a.asiento(de: "reunion")))
    a.recibir(.suprimir(false))

    // Termina el dictado: la reunión vuelve a la forma.
    a.recibir(.retirar(id: "sesion"))
    #expect(a.principal?.id == "reunion")
  }

  /// Histéresis: tres iguales, dos lugares. El que se actualiza no pierde su
  /// costado ni salta de costado, y el tercero espera.
  @Test func dosIgualesNoSeTurnanElCostado() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(costado("x")))
    a.recibir(.publicar(costado("y")))
    a.recibir(.publicar(costado("z")))
    // Los dos primeros se sentaron; el más reciente sin lugar.
    let ladoDeX = a.asiento(de: "x")
    #expect(Self.esCostado(ladoDeX))
    #expect(a.asiento(de: "z") == .ninguno)
    #expect(a.motivos["z"] == .sinLugar)

    a.recibir(.publicar(costado("x")))
    a.recibir(.publicar(costado("y")))
    #expect(a.asiento(de: "x") == ladoDeX)
    #expect(a.asiento(de: "z") == .ninguno)
  }

  /// Lo más importante desplaza a lo menos importante, y lo dice.
  @Test func laPrioridadDesplazaConMotivo() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(costado("dato.a", .baja)))
    a.recibir(.publicar(costado("dato.b", .baja)))
    let cambios = a.recibir(.publicar(.retenido))
    // Prefiere la izquierda, pero el dato que se queda no salta de costado:
    // el retenido se sienta donde se fue el desplazado.
    #expect(a.asiento(de: "retenido") == .costado(.derecha))
    #expect(a.asiento(de: "dato.b") == .costado(.izquierda))
    let desplazado = cambios.first { $0.ahora == .ninguno }
    #expect(desplazado?.motivo == .superada)
  }

  /// Un lado preferido ocupado cae al otro; quien ya estaba no se mueve.
  @Test func unLadoOcupadoCaeAlOtro() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(costado("primero", lado: .derecha)))
    a.recibir(.publicar(costado("segundo", lado: .derecha)))
    #expect(a.asiento(de: "primero") == .costado(.derecha))
    #expect(a.asiento(de: "segundo") == .costado(.izquierda))
  }

  /// La toma y el retenido, las ocupantes de hoy, cada una en su lado y las
  /// dos a la vez con la sesión en la forma.
  @Test func lasOcupantesDeHoyConviven() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(.tomaGuardada))
    a.recibir(.publicar(.retenido))
    a.recibir(.publicar(dictado))
    #expect(a.principal?.id == "sesion")
    #expect(a.costado(.derecha)?.id == "toma")
    #expect(a.costado(.izquierda)?.id == "retenido")
  }

  /// Con un solo lugar gana lo más importante.
  @Test func conUnLugarGanaElRetenido() {
    var a = AsientosDeLaMuesca()
    a.recibir(.lugaresAlCostado(1))
    a.recibir(.publicar(.tomaGuardada))
    a.recibir(.publicar(.retenido))
    #expect(a.asiento(de: "retenido") != .ninguno)
    #expect(a.asiento(de: "toma") == .ninguno)
    #expect(a.motivos["toma"] == .pantallaSinLugar)
  }

  /// Apagar algo que graba no lo saca: esconder una grabación está prohibido.
  @Test func apagarUnaGrabacionNoLaEsconde() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(reunion))
    a.recibir(.apagar(id: "reunion", true))
    #expect(a.principal?.id == "reunion")

    a.recibir(.publicar(costado("dato")))
    a.recibir(.apagar(id: "dato", true))
    #expect(a.asiento(de: "dato") == .ninguno)
    #expect(a.motivos["dato"] == .apagada)
    a.recibir(.apagar(id: "dato", false))
    #expect(Self.esCostado(a.asiento(de: "dato")))
  }

  /// La sesión tampoco se esconde en pantalla completa: hoy los estados
  /// activos aparecen igual ahí (`HUDNotchGeometry.reposoSeEsconde`).
  @Test func laSesionNoSeSuprime() {
    var a = AsientosDeLaMuesca()
    a.recibir(.suprimir(true))
    a.recibir(.publicar(.sesion(escuchando: false)))
    #expect(a.principal?.id == "sesion")
  }

  @Test func unaActividadInactivaEspera() {
    var a = AsientosDeLaMuesca()
    var toma = ActividadDeLaMuesca.tomaGuardada
    toma.activa = false
    a.recibir(.publicar(toma))
    #expect(a.asiento(de: "toma") == .ninguno)
    #expect(a.motivos["toma"] == .inactiva)
  }

  /// Los cambios salen ordenados por id: quien los recorre ve siempre el
  /// mismo orden para el mismo evento.
  @Test func losCambiosSalenOrdenados() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(costado("b")))
    let cambios = a.recibir(.publicar(dictado))
    #expect(cambios.map(\.id) == cambios.map(\.id).sorted())
    let otros = a.recibir(.retirar(id: "sesion"))
    #expect(otros.map(\.id) == ["sesion"])
    #expect(otros.first?.ahora == .ninguno)
  }

  /// Llevar al centro: un costado gana la forma, cede ante el dictado y
  /// vuelve cuando el dictado termina. Un id desconocido no hace nada, y
  /// retirar lo que estaba al centro lo suelta.
  @Test func llevarAlCentro() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(costado("agente")))
    a.recibir(.llevarAlCentro(id: "agente"))
    #expect(a.principal?.id == "agente")

    a.recibir(.llevarAlCentro(id: "nadie"))
    #expect(a.alCentro == "agente")

    a.recibir(.publicar(dictado))
    #expect(a.principal?.id == "sesion")
    a.recibir(.retirar(id: "sesion"))
    #expect(a.principal?.id == "agente")

    a.recibir(.retirar(id: "agente"))
    #expect(a.alCentro == nil)
    #expect(a.principal == nil)
  }

  @Test func soltarDelCentroDevuelveElCostado() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(costado("agente", lado: .izquierda)))
    a.recibir(.llevarAlCentro(id: "agente"))
    a.recibir(.soltarDelCentro)
    #expect(a.principal == nil)
    #expect(a.asiento(de: "agente") == .costado(.izquierda))
  }

  /// Retirar algo que no estaba no mueve nada.
  @Test func retirarLoQueNoEstabaNoMueveNada() {
    var a = AsientosDeLaMuesca()
    a.recibir(.publicar(.tomaGuardada))
    #expect(a.recibir(.retirar(id: "retenido")).isEmpty)
  }

  private static func esCostado(_ asiento: AsientoDeLaMuesca) -> Bool {
    if case .costado = asiento { return true }
    return false
  }
}

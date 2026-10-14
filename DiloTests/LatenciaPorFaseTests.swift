import DiloCapabilities
import Foundation
import Testing
@testable import Dilo

/// Las fases de un dictado con instantes inyectados: nada de esto mira un
/// reloj de verdad.
struct LatenciaPorFaseTests {
  private let cero = ContinuousClock.now

  private func en(_ ms: Int) -> ContinuousClock.Instant { cero + .milliseconds(ms) }

  /// Un dictado completo con modo, sin traducción, pegado con acuse.
  private func dictadoCompleto() -> RelojDeFases {
    var reloj = RelojDeFases()
    reloj.marcar(.gatillo, en: en(0))
    reloj.marcar(.microfonoAbierto, en: en(42))
    reloj.marcar(.primerAudio, en: en(60))
    reloj.marcar(.primerParcial, en: en(900))
    reloj.marcar(.soltar, en: en(4_000))
    reloj.marcar(.textoDelMotor, en: en(4_180))
    reloj.marcar(.revisado, en: en(4_190))
    reloj.marcar(.limpio, en: en(4_193))
    reloj.marcar(.modo, en: en(4_700))
    reloj.marcar(.atajoEnviado, en: en(4_740))
    reloj.marcar(.entregado, en: en(4_790))
    return reloj
  }

  @Test func cadaFaseEsElTramoEntreSusHitos() {
    let ms = dictadoCompleto().milisegundos()
    #expect(ms[.activacion] == 42)
    #expect(ms[.primerAudio] == 18)
    #expect(ms[.primerParcial] == 840)
    #expect(ms[.habla] == 3_958)
    #expect(ms[.motor] == 180)
    #expect(ms[.revision] == 10)
    #expect(ms[.limpieza] == 3)
    #expect(ms[.modo] == 507)
    // Sin traducción mide cero: se rellena con el modo.
    #expect(ms[.traduccion] == 0)
    #expect(ms[.pegado] == 40)
    #expect(ms[.acuse] == 50)
    #expect(ms[.total] == 790)
  }

  /// La suma de lo que pasa después de soltar cuadra con el total: los
  /// rellenos miden cero y no se comen a nadie.
  @Test func lasFasesDespuesDeSoltarSumanElTotal() {
    let ms = dictadoCompleto().milisegundos()
    let pasos: [Fase] = [.motor, .revision, .limpieza, .modo, .traduccion, .pegado, .acuse]
    #expect(pasos.compactMap { ms[$0] }.reduce(0, +) == ms[.total])
  }

  /// Un hito marcado dos veces conserva el primero: el primer búfer es el
  /// primero aunque lleguen cuarenta por segundo.
  @Test func unHitoMarcadoDosVecesConservaElPrimero() {
    var reloj = RelojDeFases()
    reloj.marcar(.microfonoAbierto, en: en(0))
    reloj.marcar(.primerAudio, en: en(20))
    reloj.marcar(.primerAudio, en: en(500))
    #expect(reloj.milisegundos()[.primerAudio] == 20)
  }

  /// Sin la revisión medida, la pasada del motor se queda con todo: es
  /// mejor que regalarle la pasada entera a la revisión.
  @Test func sinRevisionMedidaElMotorSeQuedaConTodo() {
    var reloj = RelojDeFases()
    reloj.marcar(.soltar, en: en(0))
    reloj.marcar(.revisado, en: en(200))
    let ms = reloj.milisegundos()
    #expect(ms[.motor] == 200)
    #expect(ms[.revision] == 0)
  }

  /// Copiar al portapapeles no manda ⌘V: no hay acuse que reportar, y
  /// preparar el pegado va hasta el final.
  @Test func sinAtajoNoHayAcuse() {
    var reloj = RelojDeFases()
    reloj.marcar(.soltar, en: en(0))
    reloj.marcar(.revisado, en: en(100))
    reloj.marcar(.entregado, en: en(130))
    let ms = reloj.milisegundos()
    #expect(ms[.acuse] == nil)
    #expect(ms[.pegado] == 30)
    #expect(ms[.total] == 130)
  }

  /// Una sesión que no llegó a abrir el micrófono no se guarda; una
  /// cancelada después sí, como cancelada.
  @Test func queSeGuardaYComoTermino() {
    var soloGatillo = RelojDeFases()
    soloGatillo.marcar(.gatillo, en: en(0))
    #expect(!soloGatillo.valeLaPena)

    var cancelada = soloGatillo
    cancelada.marcar(.microfonoAbierto, en: en(40))
    #expect(cancelada.valeLaPena)
    #expect(cancelada.medicion(motor: "Apple").resultado == .cancelado)

    var completa = dictadoCompleto()
    completa.resultado = ResultadoMedido(.pegado(.lectura))
    #expect(completa.medicion(motor: "Apple").resultado == .pegado)
  }

  @Test func elResultadoDeLaEntregaEsUnConjuntoCerrado() {
    #expect(ResultadoMedido(.pegado(.campo)) == .pegado)
    #expect(ResultadoMedido(.pegadoSinConfirmar) == .sinConfirmar)
    #expect(ResultadoMedido(.copiado) == .copiado)
    #expect(ResultadoMedido(.retenido(.focoCambio)) == .retenido)
    #expect(ResultadoMedido(.nadaQueEntregar) == .sinTexto)
  }

  private func medicion(total: Int, motor: String = "Parakeet v3") -> MedicionDeSesion {
    MedicionDeSesion(
      fecha: Date(timeIntervalSince1970: 0), motor: motor, conModo: false, traducido: false,
      resultado: .pegado, milisegundos: [Fase.total.rawValue: total]
    )
  }

  @Test func elRegistroTieneTope() {
    var registro = RegistroDeLatencias()
    for i in 0..<(RegistroDeLatencias.tope + 20) { registro.agregar(medicion(total: i)) }
    #expect(registro.sesiones.count == RegistroDeLatencias.tope)
    // Se van las más viejas.
    #expect(registro.sesiones.first?.ms(.total) == 20)
  }

  @Test func conMenosDeCincoNoHayPercentiles() {
    var registro = RegistroDeLatencias()
    for i in 0..<4 { registro.agregar(medicion(total: i)) }
    #expect(registro.percentiles(.total) == nil)
  }

  @Test func percentilesPorFaseYPorMotor() {
    var registro = RegistroDeLatencias()
    for i in 1...100 { registro.agregar(medicion(total: i)) }
    for _ in 1...5 { registro.agregar(medicion(total: 9_999, motor: "Apple")) }
    let parakeet = registro.percentiles(.total, motor: "Parakeet v3")
    #expect(parakeet?.p50 == 51)
    #expect(parakeet?.p95 == 96)
    #expect(registro.percentiles(.total, motor: "Apple")?.p50 == 9_999)
    // Una fase que nadie midió no tiene percentiles.
    #expect(registro.percentiles(.acuse) == nil)
  }

  /// Lo que tarda un modo se mide en las sesiones con modo: en las otras la
  /// fase vale cero y bajaría la mediana a nada.
  @Test func elModoSeMideSoloDondeCorrio() {
    var registro = RegistroDeLatencias()
    for i in 0..<20 {
      registro.agregar(MedicionDeSesion(
        fecha: .now, motor: "Apple", conModo: i < 5, traducido: false, resultado: .pegado,
        milisegundos: [Fase.modo.rawValue: i < 5 ? 600 : 0]
      ))
    }
    #expect(registro.percentiles(.modo)?.p50 == 600)
    #expect(registro.percentiles(.traduccion) == nil)
  }

  /// La cabecera del CSV es un contrato con quien lo abre en Numbers: no se
  /// mueve sin querer. Y nada del texto dictado viaja en él.
  @Test func elCSVTieneCabeceraEstableYNingunTexto() {
    var registro = RegistroDeLatencias()
    registro.agregar(medicion(total: 260))
    let lineas = registro.csv().split(separator: "\n")
    #expect(lineas.first == "fecha,motor_de_voz,con_modo,con_traduccion,resultado,activacion_ms,primerAudio_ms,primerParcial_ms,habla_ms,motor_ms,revision_ms,limpieza_ms,modo_ms,traduccion_ms,pegado_ms,acuse_ms,total_ms")
    #expect(lineas.count == 2)
    #expect(lineas[1].hasPrefix("1970-01-01T00:00:00Z,Parakeet v3,no,no,pegado,"))
    #expect(lineas[1].hasSuffix(",260"))
  }

  /// Ida y vuelta por el disco, en un archivo de prueba.
  @Test func elAlmacenGuardaYVuelveALeer() async {
    let archivo = FileManager.default.temporaryDirectory
      .appending(path: "LatenciaPorFaseTests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: archivo) }
    await AlmacenDeLatencias(archivo: archivo).agregar(medicion(total: 260))
    let leido = await AlmacenDeLatencias(archivo: archivo).registro()
    #expect(leido.sesiones == [medicion(total: 260)])
  }
}

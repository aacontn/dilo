import CoreGraphics
import DiloCapabilities
import Foundation
import Testing

@testable import Dilo

/// Las píldoras al costado de la muesca y sus dos primeras ocupantes: la toma
/// guardada para reintentar y el dictado que no se pegó cuando otra sesión le
/// tapa la tarjeta.
///
/// Sin GUI: pantalla inyectada, reloj dirigido y el portapapeles cambiado por
/// una costura. La forma misma se revisa en PNG (`scripts/render-muesca.sh`).
@MainActor
@Suite("Píldoras de la muesca")
struct PildorasDeLaMuescaTests {
  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  private var conPildoras: HUDScreenSnapshot {
    var copia = simulado
    copia.llevaPildoras = true
    return copia
  }

  private func escenario(_ reloj: DrivenClock, en pantalla: HUDScreenSnapshot? = nil) -> HUDStage {
    let stage = HUDStage(
      settings: AppSettings.previewStore(),
      reloj: reloj.deadlineClock,
      sonidos: Silencio(),
      punteroEn: { .zero }
    )
    stage.colocar(en: pantalla ?? simulado)
    return stage
  }

  private final class Silencio: ReproductorDeSonidos {
    func playBegin(using settings: DictationSoundSettings) {}
    func playEnd(using settings: DictationSoundSettings) {}
    func playPaste(using settings: DictationSoundSettings) {}
  }

  /// El centro de la píldora de este lado, en coordenadas de pantalla.
  private func centroDeLaPildora(_ lado: LadoDePildora, en stage: HUDStage) -> CGPoint {
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: conPildoras, tamaño: HUDNotchGeometry.reposoSize(for: simulado), encuadre: .reposo
    )
    let desde = HUDNotchGeometry.filletSize(for: simulado) + HUDNotchGeometry.separacionDePildora
      + HUDNotchGeometry.anchoDePildora / 2
    let x = lado == .izquierda ? silueta.minX - desde : silueta.maxX + desde
    return CGPoint(x: x, y: silueta.midY)
  }

  // La geometría

  /// Dos lugares en el notch simulado; ninguno contra una carcasa real, que
  /// tiene menús y status items al lado, ni en la píldora bajo la barra.
  @Test func soloElNotchSimuladoTieneLugarParaPildoras() {
    var pildora = simulado
    pildora.estiloSinNotch = .pildora
    #expect(HUDNotchGeometry.lugaresParaPildoras(for: simulado) == 2)
    #expect(HUDNotchGeometry.lugaresParaPildoras(for: pildora) == 0)
    #expect(HUDNotchGeometry.lugaresParaPildoras(for: HUDPreviewScreen.notched) == 0)
  }

  /// En reposo la ventana sigue siendo la muesca: con píldoras, la muesca
  /// más lo que ellas ocupan a cada lado, y ni un punto de alto de más.
  @Test func laVentanaEnReposoEsLaMuescaMasSusPildoras() {
    #expect(HUDNotchGeometry.windowSize(for: simulado, encuadre: .reposo) == CGSize(width: 178, height: 24))
    let alcance = HUDNotchGeometry.alcanceDePildoras(for: simulado)
    #expect(alcance == CGFloat(9 + 4 + 88))
    #expect(HUDNotchGeometry.windowSize(for: conPildoras, encuadre: .reposo)
      == CGSize(width: 160 + alcance * 2, height: 24))
    // Y la píldora cabe en el alto de la barra, sin tocar el borde.
    #expect(HUDNotchGeometry.altoDePildora(for: simulado) + 2 * HUDNotchGeometry.margenDePildora == 24)
  }

  /// Abierta, la ventana alcanza para la muesca dictando con sus píldoras,
  /// también con datos a los costados.
  @Test func laVentanaAbiertaAlcanzaParaLasPildorasDictando() {
    var conDatos = conPildoras
    conDatos.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    for pantalla in [conPildoras, conDatos] {
      let necesario = HUDNotchGeometry.tamañoDictando(for: pantalla).width
        + HUDNotchGeometry.alcanceDePildoras(for: pantalla) * 2
      #expect(HUDNotchGeometry.windowSize(for: pantalla).width >= necesario)
    }
    // Sin píldoras, la de siempre.
    #expect(HUDNotchGeometry.windowSize(for: simulado).width == 488)
  }

  /// La zona del mouse se estira hasta la píldora de su lado y no más.
  @Test func laZonaLlegaHastaLaPildoraDeSuLado() {
    let reposo = HUDNotchGeometry.reposoSize(for: simulado)
    let sola = HUDNotchGeometry.zonaInteractiva(for: conPildoras, tamaño: reposo, encuadre: .reposo)
    let conDerecha = HUDNotchGeometry.zonaInteractiva(
      for: conPildoras, tamaño: reposo, encuadre: .reposo, pildoras: [.derecha]
    )
    #expect(conDerecha.minX == sola.minX)
    #expect(conDerecha.maxX == sola.maxX + HUDNotchGeometry.alcanceDePildoras(for: simulado))
    #expect(conDerecha.height == sola.height)
  }

  // La toma guardada

  /// La toma que quedó en RAM aparece a la derecha; un clic la reintenta, y
  /// cuando se va la ventana vuelve a medir la muesca.
  @Test func laTomaGuardadaVaALaDerechaYUnClicLaReintenta() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    var reintentos = 0
    stage.alPedirReintento = { reintentos += 1 }

    stage.mostrarTomaGuardada(12)
    #expect(stage.dictationContent.pildoraDerecha == .toma)
    #expect(stage.dictationContent.pildoraIzquierda == nil)
    #expect(stage.marcoDeLaVentana.width == 160 + 2 * HUDNotchGeometry.alcanceDePildoras(for: simulado))
    // La píldora toma el clic; la barra del otro lado no.
    #expect(!stage.dejaPasarElMouse(en: centroDeLaPildora(.derecha, en: stage)))
    #expect(stage.dejaPasarElMouse(en: centroDeLaPildora(.izquierda, en: stage)))

    stage.dictationContent.alTocarPildora?(ContenidoDePildora.toma.id)
    #expect(reintentos == 1)

    stage.mostrarTomaGuardada(nil)
    #expect(stage.dictationContent.pildoraDerecha == nil)
    // La ventana espera a que la píldora termine de irse.
    #expect(stage.marcoDeLaVentana.width > 178)
    await reloj.waitForSleeper()
    while stage.marcoDeLaVentana.width != 178 {
      reloj.advance(by: HUDStage.dismissDuration)
      await Task.yield()
    }
    #expect(stage.marcoDeLaVentana.size == CGSize(width: 178, height: 24))
  }

  /// Mientras se dicta la principal es el dictado; la toma sigue a la vista
  /// en su píldora, pero la ventana no toma ningún clic.
  @Test func dictandoLaTomaSeQuedaAlCostado() {
    let stage = escenario(DrivenClock())
    stage.mostrarTomaGuardada(12)
    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    #expect(stage.asientos.principal?.id == "sesion")
    #expect(stage.dictationContent.pildoraDerecha == .toma)
    #expect(!stage.laFormaRecibeElMouse)
  }

  /// Contra una carcasa real no hay píldoras: la toma sigue en el menú de la
  /// barra, y la ventana no crece.
  @Test func contraUnaCarcasaRealNoHayPildoras() {
    let stage = escenario(DrivenClock(), en: HUDPreviewScreen.notched)
    stage.mostrarTomaGuardada(12)
    #expect(stage.dictationContent.pildoraDerecha == nil)
    #expect(stage.asientos.motivos["toma"] == .pantallaSinLugar)
  }

  // El retenido

  /// La regla pura: qué cambio de estado deja una tarjeta tapada.
  @Test func queCuentaComoTapar() {
    let tarjeta = TarjetaDeRespaldo(texto: "hola", porque: .sinConfirmar)
    let conTarjeta = EstadoDelNotch.resultado(.retenido(tarjeta))
    #expect(TarjetaDeRespaldo.tapada(de: conTarjeta, a: .dictando) == tarjeta)
    #expect(TarjetaDeRespaldo.tapada(de: conTarjeta, a: .preparando(.cargandoModelo)) == tarjeta)
    #expect(TarjetaDeRespaldo.tapada(de: conTarjeta, a: .resultado(.aviso("x"))) == tarjeta)
    // Venció, se copió con su clic u otra la reemplazó: nada pendiente.
    #expect(TarjetaDeRespaldo.tapada(de: conTarjeta, a: .reposo) == nil)
    #expect(TarjetaDeRespaldo.tapada(de: conTarjeta, a: .resultado(.copiado)) == nil)
    #expect(TarjetaDeRespaldo.tapada(de: conTarjeta, a: conTarjeta) == nil)
    #expect(TarjetaDeRespaldo.tapada(de: .dictando, a: .procesando) == nil)
  }

  /// El recorrido entero: la tarjeta de un dictado que no se pegó, otro
  /// dictado que la tapa, la píldora que se queda mientras dura, el minuto
  /// que corre recién al volver a reposo, y el clic que la copia.
  @Test func unaTarjetaTapadaSeCorreAUnaPildoraYSeCopiaConUnClic() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    var copiado: String?
    stage.copiarAlPortapapeles = { copiado = $0 }
    let tarjeta = TarjetaDeRespaldo(texto: "quedamos el martes", porque: .noSePego(.focoCambio))

    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    stage.recibir(.procesar)
    stage.recibir(.entregar(.retenido(tarjeta)))
    #expect(stage.dictationContent.pildoraIzquierda == nil, "la tarjeta está en la forma")

    // Otro dictado la tapa: se corre a la izquierda.
    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    #expect(stage.retenidoEnPildora == tarjeta)
    #expect(stage.dictationContent.pildoraIzquierda == .retenido)
    #expect(stage.asientos.principal?.id == "sesion")

    // Mientras dura la sesión no vence, por mucho que pase.
    reloj.advance(by: .seconds(120))
    await Task.yield()
    #expect(stage.retenidoEnPildora == tarjeta)

    // Termina bien: vuelve a reposo y la píldora sigue ahí.
    stage.recibir(.procesar)
    stage.recibir(.entregar(.listo))
    while stage.estado != .reposo {
      reloj.advance(by: MaquinaDelNotch.duracionDelAcuse)
      await Task.yield()
    }
    #expect(stage.dictationContent.pildoraIzquierda == .retenido)

    // Un clic la copia, la saca y lo dice la forma.
    stage.dictationContent.alTocarPildora?(ContenidoDePildora.retenido.id)
    #expect(copiado == "quedamos el martes")
    #expect(stage.dictationContent.pildoraIzquierda == nil)
    #expect(stage.estado == .resultado(.copiado))
  }

  /// Sin clic, se va sola un minuto después de volver a reposo.
  @Test func laPildoraDelRetenidoVenceUnMinutoDespuesDelReposo() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    stage.ponerRetenidoEnPildora(TarjetaDeRespaldo(texto: "hola", porque: .sinConfirmar))
    #expect(stage.dictationContent.pildoraIzquierda == .retenido)
    await reloj.waitForSleeper()
    reloj.advance(by: TarjetaDeRespaldo.duracionEnPildora)
    while stage.retenidoEnPildora != nil { await Task.yield() }
    #expect(stage.dictationContent.pildoraIzquierda == nil)
  }

  /// Las dos a la vez: el retenido a la izquierda, la toma a la derecha,
  /// las dos tomando su clic y la barra de al lado de ellas no.
  @Test func lasDosConviven() {
    let stage = escenario(DrivenClock())
    stage.mostrarTomaGuardada(12)
    stage.ponerRetenidoEnPildora(TarjetaDeRespaldo(texto: "hola", porque: .sinConfirmar))
    #expect(stage.dictationContent.pildoraIzquierda == .retenido)
    #expect(stage.dictationContent.pildoraDerecha == .toma)
    #expect(!stage.dejaPasarElMouse(en: centroDeLaPildora(.izquierda, en: stage)))
    #expect(!stage.dejaPasarElMouse(en: centroDeLaPildora(.derecha, en: stage)))
    let masAlla = CGPoint(x: centroDeLaPildora(.derecha, en: stage).x + 60, y: simulado.frame.maxY - 8)
    #expect(stage.dejaPasarElMouse(en: masAlla))
  }

  /// El arnés pone y saca las píldoras de sus escenas, y al soltar devuelve
  /// las de verdad.
  @Test func elArnesDevuelveLasPildorasDeVerdad() {
    let stage = escenario(DrivenClock())
    stage.mostrarTomaGuardada(30)
    stage.mostrarMuestra(.dosPildoras, texto: nil)
    #expect(stage.dictationContent.pildoraIzquierda == .retenido)
    #expect(stage.dictationContent.pildoraDerecha == .toma)
    stage.mostrarMuestra(.dictando, texto: nil)
    #expect(stage.dictationContent.pildoraDerecha == nil)
    stage.soltarMuestra()
    #expect(stage.tomaGuardada == 30)
    #expect(stage.dictationContent.pildoraDerecha == .toma)
    #expect(stage.dictationContent.pildoraIzquierda == nil)
  }
}

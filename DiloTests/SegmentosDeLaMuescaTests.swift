import CoreGraphics
import DiloCapabilities
import Foundation
import SwiftUI
import Testing

@testable import Dilo

/// Los segmentos al costado de la muesca —la misma silueta estirada hacia un
/// lado— y sus dos primeras ocupantes: la toma guardada para reintentar y el
/// dictado que no se pegó cuando otra sesión le tapa la tarjeta.
///
/// Sin GUI: pantalla inyectada, reloj dirigido y el portapapeles cambiado por
/// una costura. La forma misma se revisa en PNG (`scripts/render-muesca.sh`,
/// carpeta `c2/`).
@MainActor
@Suite("Segmentos de la muesca")
struct SegmentosDeLaMuescaTests {
  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  private var conSegmentos: HUDScreenSnapshot {
    var copia = simulado
    copia.llevaSegmentos = true
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

  /// El centro del segmento de este lado, en coordenadas de pantalla, con el
  /// ancho que tiene ahora en el escenario.
  private func centroDelSegmento(_ lado: LadoDelAsiento, en stage: HUDStage) -> CGPoint {
    let cuerpo = HUDNotchGeometry.siluetaEnPantalla(
      for: conSegmentos, tamaño: HUDNotchGeometry.reposoSize(for: simulado), encuadre: .reposo
    )
    let ancho = stage.dictationContent.anchoDelSegmento(lado) ?? HUDNotchGeometry.anchoDeSegmentoEncogido
    let costados = stage.dictationContent.costados(en: simulado)
    let rect = HUDNotchGeometry.rectDelSegmento(lado, ancho: ancho, costados: costados, cuerpo: cuerpo)
    return CGPoint(x: rect.midX, y: rect.midY)
  }

  /// Avanza el reloj de a poco hasta que se cumpla la condición: cada plazo
  /// se arma en su propia tarea.
  private func avanzar(_ reloj: DrivenClock, hasta condicion: () -> Bool) async {
    var vueltas = 0
    while !condicion(), vueltas < 2_000 {
      reloj.advance(by: .milliseconds(50))
      await Task.yield()
      vueltas += 1
    }
  }

  // La geometría

  /// Dos lugares en el notch simulado; ninguno contra una carcasa real, que
  /// tiene menús y status items al lado, ni en la píldora bajo la barra.
  @Test func soloElNotchSimuladoTieneLugarAlCostado() {
    var pildora = simulado
    pildora.estiloSinNotch = .pildora
    #expect(HUDNotchGeometry.lugaresAlCostado(for: simulado) == 2)
    #expect(HUDNotchGeometry.lugaresAlCostado(for: pildora) == 0)
    #expect(HUDNotchGeometry.lugaresAlCostado(for: HUDPreviewScreen.notched) == 0)
  }

  /// La silueta se estira lo que mide el segmento, salvo lo que el lado ya
  /// tiene por su dato; y no más que el techo.
  @Test func laSiluetaSeEstiraLoQueMideElSegmento() {
    let sinNada = HUDNotchGeometry.estiramientos(for: simulado, izquierdo: nil, derecho: 26, compacta: true)
    #expect(sinNada == CostadosDeLaSilueta(izquierda: 0, derecha: 26))
    var conDatos = simulado
    conDatos.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    let encogido = HUDNotchGeometry.estiramientos(for: conDatos, izquierdo: 26, derecho: 90, compacta: true)
    #expect(encogido == CostadosDeLaSilueta(izquierda: 0, derecha: 90 - 72))
    // Abierta (dictando), el lado del dato no está libre.
    let abierta = HUDNotchGeometry.estiramientos(for: conDatos, izquierdo: 26, derecho: nil, compacta: false)
    #expect(abierta.izquierda == 26)
    let techo = HUDNotchGeometry.estiramientos(for: simulado, izquierdo: 500, derecho: nil, compacta: true)
    #expect(techo.izquierda == HUDNotchGeometry.anchoMaximoDeSegmento)
  }

  /// Encogido, el segmento es el ícono: +26 pt por lado.
  @Test func encogidoMideElIcono() {
    #expect(ContenidoDelSegmento.toma.ancho(conPalabra: false) == 26)
    let conPalabra = ContenidoDelSegmento.toma.ancho(conPalabra: true)
    #expect(conPalabra > 26 && conPalabra <= HUDNotchGeometry.anchoMaximoDeSegmento)
  }

  /// En reposo la ventana sigue siendo la muesca; con segmentos, la muesca
  /// más lo que pueden llegar a estirarse con la palabra, y ni un punto de
  /// alto de más. Sin segmentos, lo de siempre.
  @Test func laVentanaEnReposoEsLaMuescaMasSusSegmentos() {
    #expect(HUDNotchGeometry.windowSize(for: simulado, encuadre: .reposo) == CGSize(width: 178, height: 24))
    let lado = HUDNotchGeometry.filletSize(for: simulado) + HUDNotchGeometry.anchoMaximoDeSegmento
    #expect(HUDNotchGeometry.windowSize(for: conSegmentos, encuadre: .reposo) == CGSize(width: 160 + lado * 2, height: 24))
  }

  /// Abierta, la ventana alcanza para la muesca dictando estirada, también
  /// con datos a los costados.
  @Test func laVentanaAbiertaAlcanzaParaLosSegmentosDictando() {
    var conDatos = conSegmentos
    conDatos.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    for pantalla in [conSegmentos, conDatos] {
      let necesario = HUDNotchGeometry.tamañoDictando(for: pantalla).width
        + (HUDNotchGeometry.anchoMaximoDeSegmento + HUDNotchGeometry.filletSize(for: pantalla)) * 2
      #expect(HUDNotchGeometry.windowSize(for: pantalla).width >= necesario)
    }
    #expect(HUDNotchGeometry.windowSize(for: simulado).width == 488)
  }

  /// La zona del mouse se estira lo que se estira la silueta, por su lado.
  @Test func laZonaSeEstiraConLaSilueta() {
    let reposo = HUDNotchGeometry.reposoSize(for: simulado)
    let sola = HUDNotchGeometry.zonaInteractiva(for: conSegmentos, tamaño: reposo, encuadre: .reposo)
    let estirada = HUDNotchGeometry.zonaInteractiva(
      for: conSegmentos, tamaño: reposo, encuadre: .reposo,
      costados: CostadosDeLaSilueta(izquierda: 0, derecha: 26)
    )
    #expect(estirada.minX == sola.minX)
    #expect(estirada.maxX == sola.maxX + 26)
    #expect(estirada.height == sola.height)
  }

  /// La silueta estirada es una pieza: el cuerpo más los costados, con las
  /// alas en los extremos nuevos.
  @Test func laSiluetaEstiradaEsUnaPieza() {
    let marco = CGRect(x: 0, y: 0, width: 160, height: 24)
    let silueta = SiluetaDeLaMuesca(
      estilo: .muesca, radioDeHombro: 9, radioInferior: 11,
      costados: CostadosDeLaSilueta(izquierda: 26, derecha: 90)
    )
    let camino = silueta.path(in: marco)
    let caja = camino.boundingRect
    #expect(abs(caja.minX - (-26 - 9)) < 0.001)
    #expect(abs(caja.maxX - (160 + 90 + 9)) < 0.001)
    // Sin hueco entre la muesca y el segmento: el borde del marco es negro.
    #expect(camino.contains(CGPoint(x: -0.5, y: 12)))
    #expect(camino.contains(CGPoint(x: 160.5, y: 12)))
  }

  // La regla de los costados

  @Test func unSegmentoEscondeElDatoDeSuLado() {
    #expect(ReglaDeLosCostados.datoVisible("CPU", en: .derecha, segmentos: [.derecha]) == nil)
    #expect(ReglaDeLosCostados.datoVisible("Codex", en: .izquierda, segmentos: [.derecha]) == "Codex")
    #expect(ReglaDeLosCostados.escondidos(conDato: [.izquierda, .derecha], segmentos: [.derecha]) == [.derecha])
    #expect(ReglaDeLosCostados.escondidos(conDato: [.izquierda], segmentos: [.derecha]).isEmpty)
  }

  @Test func loEscondidoSeDiceEnElLog() {
    #expect(RegistroDeLaMuesca.lineaDelDato("cpu", lado: .derecha, segmento: "toma")
      == "dato=cpu lado=derecha escondido por segmento=toma")
    #expect(RegistroDeLaMuesca.lineaDelDato("cpu", lado: .derecha, segmento: nil) == "dato=cpu lado=derecha vuelve")
  }

  /// Con datos encendidos, el segmento ocupa el lugar del dato de su lado y
  /// la silueta casi no crece; cuando se va, el dato vuelve.
  @Test func conDatosElSegmentoOcupaElLugarDelDato() {
    let stage = escenario(DrivenClock())
    stage.mostrarMuestra(.segmentoConDatos, texto: nil)
    #expect(stage.dictationContent.datoDerecho != nil, "el dato sigue leído")
    #expect(stage.dictationContent.costadosConSegmentoVisible == [.derecha])
    stage.encogerLaPalabra()
    var conDatos = simulado
    conDatos.anchoDeLosLados = HUDNotchGeometry.anchoDeUnLado
    #expect(stage.dictationContent.costados(en: conDatos) == CostadosDeLaSilueta())
    stage.soltarMuestra()
  }

  // La palabra

  /// Entra con la palabra, a los tres segundos queda el ícono, y la zona del
  /// mouse lo sigue.
  @Test func entraConLaPalabraYSeEncoge() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    stage.mostrarTomaGuardada(12)
    #expect(stage.dictationContent.segmentosConPalabra == [.derecha])
    let conPalabra = stage.dictationContent.costados(en: simulado).derecha
    #expect(conPalabra > 26)
    await avanzar(reloj) { stage.dictationContent.segmentosConPalabra.isEmpty }
    #expect(stage.dictationContent.segmentosConPalabra.isEmpty)
    #expect(stage.dictationContent.costados(en: simulado).derecha == 26)
    #expect(reloj.deadlineClock.now() >= PalabraDeLosSegmentos.alAparecer)
  }

  /// Con el puntero encima del segmento vuelve la palabra y **no** se abre
  /// el panel del hover; al irse, se encoge otra vez.
  @Test func elPunteroEncimaDevuelveLaPalabraSinAbrirElPanel() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    stage.mostrarTomaGuardada(12)
    stage.encogerLaPalabra()
    #expect(stage.dictationContent.segmentosConPalabra.isEmpty)

    stage.punteroSeMovio(a: centroDelSegmento(.derecha, en: stage))
    #expect(stage.dictationContent.segmentosConPalabra == [.derecha])
    #expect(!stage.punteroSobreLaSilueta, "el segmento no es silueta para la intención")
    await avanzar(reloj) { reloj.deadlineClock.now() >= .seconds(2) }
    #expect(!stage.dictationContent.punteroEncima, "no abre el panel")
    #expect(stage.dictationContent.segmentosConPalabra == [.derecha], "encima no se encoge")

    stage.punteroSeMovio(a: CGPoint(x: 300, y: simulado.frame.maxY - 8))
    await avanzar(reloj) { stage.dictationContent.segmentosConPalabra.isEmpty }
    #expect(stage.dictationContent.segmentosConPalabra.isEmpty)
  }

  /// La regla pura: un plazo viejo no encoge una palabra reabierta, y fijar
  /// la deja en todos los lados.
  @Test func laPalabraEsPuraConTurno() {
    var p = PalabraDeLosSegmentos()
    let efectos = p.recibir(.aparecio(.derecha))
    #expect(efectos == [.encogerEn(.derecha, PalabraDeLosSegmentos.alAparecer, turno: 1)])
    _ = p.recibir(.punteroEncima(.derecha))
    #expect(p.recibir(.vencio(.derecha, turno: 1)).isEmpty)
    #expect(p.conPalabra == [.derecha], "un plazo viejo no la encoge")
    let alIrse = p.recibir(.punteroEncima(nil))
    #expect(alIrse == [.encogerEn(.derecha, PalabraDeLosSegmentos.alIrseElPuntero, turno: 3)])
    _ = p.recibir(.vencio(.derecha, turno: 3))
    #expect(p.conPalabra.isEmpty)
    _ = p.recibir(.aparecio(.izquierda))
    _ = p.recibir(.fijar(true))
    #expect(p.conPalabra == [.izquierda, .derecha])
    #expect(p.recibir(.vencio(.izquierda, turno: p.turno(de: .izquierda))).isEmpty)
    #expect(p.conPalabra == [.izquierda, .derecha])
    _ = p.recibir(.seFue(.izquierda))
    #expect(p.conPalabra == [.derecha])
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
    #expect(stage.dictationContent.segmentoDerecho == .toma)
    #expect(stage.dictationContent.segmentoIzquierdo == nil)
    #expect(stage.marcoDeLaVentana.width
      == 160 + 2 * (HUDNotchGeometry.filletSize(for: simulado) + HUDNotchGeometry.anchoMaximoDeSegmento))
    // El segmento toma el clic; la barra del otro lado no.
    #expect(!stage.dejaPasarElMouse(en: centroDelSegmento(.derecha, en: stage)))
    let delOtroLado = CGPoint(x: simulado.frame.midX - 80 - 40, y: simulado.frame.maxY - 12)
    #expect(stage.dejaPasarElMouse(en: delOtroLado))

    stage.dictationContent.alTocarSegmento?(ContenidoDelSegmento.toma.id)
    #expect(reintentos == 1)

    stage.mostrarTomaGuardada(nil)
    #expect(stage.dictationContent.segmentoDerecho == nil)
    // La ventana espera a que el segmento termine de irse.
    #expect(stage.marcoDeLaVentana.width > 178)
    await reloj.waitForSleeper()
    while stage.marcoDeLaVentana.width != 178 {
      reloj.advance(by: HUDStage.dismissDuration)
      await Task.yield()
    }
    #expect(stage.marcoDeLaVentana.size == CGSize(width: 178, height: 24))
  }

  /// Mientras se dicta la principal es el dictado; la toma sigue a la vista
  /// en su segmento, pero la ventana no toma ningún clic.
  @Test func dictandoLaTomaSeQuedaAlCostado() {
    let stage = escenario(DrivenClock())
    stage.mostrarTomaGuardada(12)
    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    #expect(stage.asientos.principal?.id == "sesion")
    #expect(stage.dictationContent.segmentoDerecho == .toma)
    #expect(!stage.laFormaRecibeElMouse)
  }

  /// Contra una carcasa real no hay segmentos: la toma sigue en el menú de la
  /// barra, y la ventana no crece.
  @Test func contraUnaCarcasaRealNoHaySegmentos() {
    let stage = escenario(DrivenClock(), en: HUDPreviewScreen.notched)
    stage.mostrarTomaGuardada(12)
    #expect(stage.dictationContent.segmentoDerecho == nil)
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
  /// dictado que la tapa, el segmento que se queda mientras dura, el minuto
  /// que corre recién al volver a reposo, y el clic que la copia.
  @Test func unaTarjetaTapadaSeCorreAUnSegmentoYSeCopiaConUnClic() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    var copiado: String?
    stage.copiarAlPortapapeles = { copiado = $0 }
    let tarjeta = TarjetaDeRespaldo(texto: "quedamos el martes", porque: .noSePego(.focoCambio))

    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    stage.recibir(.procesar)
    stage.recibir(.entregar(.retenido(tarjeta)))
    #expect(stage.dictationContent.segmentoIzquierdo == nil, "la tarjeta está en la forma")

    // Otro dictado la tapa: se corre a la izquierda.
    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    #expect(stage.retenidoAlCostado == tarjeta)
    #expect(stage.dictationContent.segmentoIzquierdo == .retenido)
    #expect(stage.asientos.principal?.id == "sesion")

    // Mientras dura la sesión no vence, por mucho que pase.
    reloj.advance(by: .seconds(120))
    await Task.yield()
    #expect(stage.retenidoAlCostado == tarjeta)

    // Termina bien: vuelve a reposo y el segmento sigue ahí.
    stage.recibir(.procesar)
    stage.recibir(.entregar(.listo))
    while stage.estado != .reposo {
      reloj.advance(by: MaquinaDelNotch.duracionDelAcuse)
      await Task.yield()
    }
    #expect(stage.dictationContent.segmentoIzquierdo == .retenido)

    // Un clic la copia, la saca y lo dice la forma.
    stage.dictationContent.alTocarSegmento?(ContenidoDelSegmento.retenido.id)
    #expect(copiado == "quedamos el martes")
    #expect(stage.dictationContent.segmentoIzquierdo == nil)
    #expect(stage.estado == .resultado(.copiado))
  }

  /// Sin clic, se va sola un minuto después de volver a reposo.
  @Test func elSegmentoDelRetenidoVenceUnMinutoDespuesDelReposo() async {
    let reloj = DrivenClock()
    let stage = escenario(reloj)
    stage.ponerRetenidoAlCostado(TarjetaDeRespaldo(texto: "hola", porque: .sinConfirmar))
    #expect(stage.dictationContent.segmentoIzquierdo == .retenido)
    await reloj.waitForSleeper()
    reloj.advance(by: TarjetaDeRespaldo.duracionAlCostado)
    while stage.retenidoAlCostado != nil { await Task.yield() }
    #expect(stage.dictationContent.segmentoIzquierdo == nil)
  }

  /// Las dos a la vez: el retenido a la izquierda, la toma a la derecha,
  /// las dos tomando su clic y la barra de al lado de ellas no.
  @Test func lasDosConviven() {
    let stage = escenario(DrivenClock())
    stage.mostrarTomaGuardada(12)
    stage.ponerRetenidoAlCostado(TarjetaDeRespaldo(texto: "hola", porque: .sinConfirmar))
    #expect(stage.dictationContent.segmentoIzquierdo == .retenido)
    #expect(stage.dictationContent.segmentoDerecho == .toma)
    #expect(!stage.dejaPasarElMouse(en: centroDelSegmento(.izquierda, en: stage)))
    #expect(!stage.dejaPasarElMouse(en: centroDelSegmento(.derecha, en: stage)))
    let masAlla = CGPoint(x: simulado.frame.midX + 80 + 120, y: simulado.frame.maxY - 8)
    #expect(stage.dejaPasarElMouse(en: masAlla))
  }

  /// El arnés pone y saca los segmentos de sus escenas, y al soltar devuelve
  /// las de verdad.
  @Test func elArnesDevuelveLosSegmentosDeVerdad() {
    let stage = escenario(DrivenClock())
    stage.mostrarTomaGuardada(30)
    stage.mostrarMuestra(.dosSegmentos, texto: nil)
    #expect(stage.dictationContent.segmentoIzquierdo == .retenido)
    #expect(stage.dictationContent.segmentoDerecho == .toma)
    stage.mostrarMuestra(.dictando, texto: nil)
    #expect(stage.dictationContent.segmentoDerecho == nil)
    stage.soltarMuestra()
    #expect(stage.tomaGuardada == 30)
    #expect(stage.dictationContent.segmentoDerecho == .toma)
    #expect(stage.dictationContent.segmentoIzquierdo == nil)
  }
}

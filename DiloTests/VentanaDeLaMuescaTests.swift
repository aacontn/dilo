import AppKit
import CoreGraphics
import Testing

@testable import Dilo

/// La ventana anfitriona mide lo que mide el estado.
///
/// Sale del reclamo de Alfonso del 2026-09-22: «la zona inmediatamente debajo
/// del notch queda inutilizada». En reposo la muesca mide 160×24 y la ventana
/// que la hospedaba medía 488×196, pegada al borde de arriba; macOS le entrega
/// a una ventana todos los clics de su rectángulo aunque no dibuje nada ahí, y
/// un `hitTest` que devuelve nil **pierde** el clic en vez de pasarlo a la
/// ventana de abajo. Eran ~190 puntos muertos en el centro de la barra de
/// menús y debajo, todo el tiempo.
///
/// Lo que esta suite cuida son las dos mitades del arreglo: la ventana se
/// ajusta a la silueta en reposo y sólo crece mientras la forma está abierta,
/// y aun dentro de esa ventana chica sólo toma el mouse con el puntero encima
/// de la silueta.
@Suite("La ventana de la muesca")
struct VentanaDeLaMuescaTests {
  /// Uno de los dos 1080p del Mac mini, con lo que trae de fábrica.
  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24,
    nombre: "DELL U2412M"
  )
  private let conNotch = HUDScreenSnapshot(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTop: 32,
    auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
    menuBarHeight: 32
  )
  private var pildora: HUDScreenSnapshot {
    var copia = simulado
    copia.estiloSinNotch = .pildora
    return copia
  }

  // MARK: El tamaño por estado

  /// En reposo la ventana es la silueta más la holgura declarada, y nada más.
  /// El número viejo —488×190 con una muesca de 160×24 adentro— está escrito
  /// acá a propósito: es lo que no puede volver.
  @Test(arguments: [
    HUDNotchGeometry.EncuadreDeLaVentana.reposo,
    HUDNotchGeometry.EncuadreDeLaVentana.abierta,
  ])
  func laVentanaEsLaSiluetaMasSuHolgura(encuadre: HUDNotchGeometry.EncuadreDeLaVentana) {
    for pantalla in [simulado, pildora, conNotch] {
      let ventana = HUDNotchGeometry.windowSize(for: pantalla, encuadre: encuadre)
      switch encuadre {
      case .reposo:
        let silueta = HUDNotchGeometry.reposoSize(for: pantalla)
        let holgura = HUDNotchGeometry.holguraEnReposo(for: pantalla)
        #expect(ventana.width == silueta.width + holgura * 2)
        #expect(ventana.height == silueta.height + holgura)
      case .abierta:
        let holgura = HUDNotchGeometry.holguraDeRevelacion(for: pantalla)
        #expect(ventana.width == HUDMetrics.standard.contentWidth + holgura * 2)
        #expect(
          ventana.height == HUDNotchGeometry.altoDeLaFormaMasAlta(for: pantalla) + holgura
        )
      }
    }
  }

  /// Los números de la pantalla del reclamo, escritos enteros: 190×39 en
  /// reposo contra los 488×190 de la forma abierta.
  @Test func enReposoLaVentanaNoTapaLaBarraDeMenus() {
    let reposo = HUDNotchGeometry.windowSize(for: simulado, encuadre: .reposo)
    #expect(reposo == CGSize(width: 190, height: 39))
    #expect(HUDNotchGeometry.windowSize(for: simulado) == CGSize(width: 488, height: 190))
    // Lo que el reclamo medía: la ventana en reposo ya no llega ni a la
    // cuarta parte de lo que llegaba.
    #expect(reposo.height < 40)
    #expect(reposo.width < 200)
  }

  /// La holgura de reposo es la que la sombra dibujada necesita —el mismo
  /// desenfoque y el mismo desplazamiento con que `HUDSurface` la pinta—, y
  /// alcanza además para las dos alas cóncavas que cuelgan a los lados.
  @Test func laHolguraEnReposoEsLaSombraQueDeVerdadSeDibuja() {
    #expect(
      HUDNotchGeometry.holguraDeSombra()
        == HUDMetrics.standard.shadowRadius + HUDMetrics.standard.shadowOffsetY
    )
    #expect(HUDNotchGeometry.holguraDeSombra() == 15)
    for pantalla in [simulado, pildora, conNotch] {
      let holgura = HUDNotchGeometry.holguraEnReposo(for: pantalla)
      #expect(holgura >= HUDNotchGeometry.holguraDeSombra())
      #expect(holgura >= HUDNotchGeometry.filletSize(for: pantalla), "las alas caben")
    }
  }

  /// La ventana abierta tiene que aguantar el rebote del resorte: un resorte
  /// llega a su destino y se pasa, y una ventana ajustada al tamaño final le
  /// recorta justo los fotogramas que se miran.
  @Test func laVentanaAbiertaAguantaElReboteYLaSombra() {
    // El peor sobrepaso es el del arrastre, y ninguno es una estimación a
    // ojo: salen del `bounce` con que se declara cada animación.
    #expect(HUDRevealStyle.slide.sobrepaso == 0)
    #expect(HUDRevealStyle.drift.sobrepaso == 0)
    #expect(HUDRevealStyle.unfurl.sobrepaso > HUDRevealStyle.bloom.sobrepaso)
    #expect(HUDRevealStyle.sobrepasoMaximo >= HUDRevealStyle.unfurl.sobrepaso)
    #expect(HUDRevealStyle.sobrepasoMaximo < 0.2, "un rebote, no un salto")

    for pantalla in [simulado, pildora, conNotch] {
      let holgura = HUDNotchGeometry.holguraDeRevelacion(for: pantalla)
      let forma = HUDNotchGeometry.altoDeLaFormaMasAlta(for: pantalla)
      #expect(
        holgura
          >= HUDNotchGeometry.holguraDeSombra() + forma * HUDRevealStyle.sobrepasoMaximo,
        "el alto rebota hacia abajo"
      )
      #expect(
        holgura
          >= HUDNotchGeometry.holguraDeSombra()
          + HUDMetrics.standard.contentWidth * HUDRevealStyle.sobrepasoMaximo / 2,
        "el ancho rebota hacia los dos lados"
      )
    }
  }

  /// La ventana se queda donde estaba: cambia de tamaño, no de sitio. El
  /// notch simulado sigue naciendo del borde de arriba y la píldora sigue
  /// colgando debajo de la barra, en los dos encuadres.
  @Test func laVentanaCambiaDeTamanoYNoDeSitio() {
    for encuadre in [HUDNotchGeometry.EncuadreDeLaVentana.reposo, .abierta] {
      let enSimulado = HUDNotchGeometry.windowFrame(for: simulado, encuadre: encuadre)
      #expect(enSimulado.maxY == simulado.frame.maxY)
      #expect(enSimulado.midX == simulado.frame.midX)
      let enPildora = HUDNotchGeometry.windowFrame(for: pildora, encuadre: encuadre)
      #expect(
        enPildora.maxY == pildora.frame.maxY - pildora.menuBarHeight
          - HUDNotchGeometry.pillDetachment
      )
    }
  }

  /// Y la silueta cae en el mismo lugar de la pantalla con la ventana chica
  /// que con la grande: lo que se encoge es la holgura invisible, no la forma.
  @Test func laSiluetaNoSeMueveAlEncogerseLaVentana() {
    let tamaño = HUDNotchGeometry.reposoSize(for: simulado)
    let chica = HUDNotchGeometry.siluetaEnPantalla(
      for: simulado, tamaño: tamaño, encuadre: .reposo
    )
    let grande = HUDNotchGeometry.siluetaEnPantalla(
      for: simulado, tamaño: tamaño, encuadre: .abierta
    )
    #expect(chica == grande)
    #expect(chica.maxY == simulado.frame.maxY)
  }

  // MARK: El mouse

  @MainActor
  private func escenarioEnReposo(_ reloj: DrivenClock) -> HUDStage {
    let stage = HUDStage(settings: AppSettings.previewStore(), reloj: reloj.deadlineClock)
    stage.colocar(en: simulado)
    return stage
  }

  /// El centro de la silueta en reposo, en coordenadas de pantalla.
  private var sobreLaMuesca: CGPoint {
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: simulado,
      tamaño: HUDNotchGeometry.reposoSize(for: simulado),
      encuadre: .reposo
    )
    return CGPoint(x: silueta.midX, y: silueta.midY)
  }

  /// En reposo, con el puntero en cualquier otra parte, la ventana deja pasar
  /// el mouse entero. Es la mitad del arreglo que el tamaño no cubre: aun
  /// dentro de los 190×39, los puntos de la holgura de la sombra son barra de
  /// menús de la app de al lado.
  @MainActor
  @Test func enReposoConElPunteroFueraLaVentanaIgnoraElMouse() {
    let stage = escenarioEnReposo(DrivenClock())
    #expect(stage.encuadre == .reposo)
    #expect(stage.ventanaIgnoraElMouse)

    // Un punto dentro de la ventana pero debajo de la silueta: la holgura de
    // la sombra no toma clics.
    let ventana = stage.marcoDeLaVentana
    stage.punteroSeMovio(a: CGPoint(x: ventana.midX, y: ventana.minY + 2))
    #expect(!stage.punteroSobreLaSilueta)
    #expect(stage.ventanaIgnoraElMouse)

    // Y la barra de menús a la derecha, que es donde viven los status items.
    stage.punteroSeMovio(a: CGPoint(x: 1600, y: simulado.frame.maxY - 8))
    #expect(stage.ventanaIgnoraElMouse)
  }

  /// Con el puntero encima de la silueta la ventana sí toma el mouse, para
  /// que el clic abra el menú de acciones.
  @MainActor
  @Test func conElPunteroSobreLaSiluetaLaVentanaTomaElMouse() {
    let stage = escenarioEnReposo(DrivenClock())
    stage.punteroSeMovio(a: sobreLaMuesca)
    #expect(stage.punteroSobreLaSilueta)
    #expect(!stage.ventanaIgnoraElMouse)

    // Y al irse vuelve a dejar pasar todo.
    stage.punteroSeMovio(a: CGPoint(x: 400, y: simulado.frame.maxY - 8))
    #expect(!stage.punteroSobreLaSilueta)
    #expect(stage.ventanaIgnoraElMouse)
  }

  /// Mientras se dicta, el clic es del documento en el que estás escribiendo:
  /// ni con el puntero encima la ventana lo toma (`EstadoDelNotch.tomaElMouse`).
  @MainActor
  @Test func dictandoLaVentanaNoTomaElMouseNiConElPunteroEncima() {
    let stage = escenarioEnReposo(DrivenClock())
    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    stage.punteroSeMovio(a: sobreLaMuesca)
    #expect(stage.estado == .dictando)
    #expect(stage.ventanaIgnoraElMouse)
  }

  // MARK: El momento de crecer y el de encoger

  /// La ventana crece **antes** de que la revelación arranque y se encoge
  /// **después** de que el cierre termine. Es la asimetría que deja la
  /// animación entera y el reposo sin zona muerta.
  @MainActor
  @Test func creceAntesDeAbrirseYSeEncogeDespuesDeCerrarse() async {
    let reloj = DrivenClock()
    let stage = escenarioEnReposo(reloj)
    #expect(stage.encuadre == .reposo)
    #expect(stage.marcoDeLaVentana.height == 39)

    stage.claim(.dictation, on: simulado)
    stage.recibir(.escuchar)
    // Ya creció, y la forma todavía no se reveló.
    #expect(stage.encuadre == .abierta)
    #expect(stage.marcoDeLaVentana.size == CGSize(width: 488, height: 190))
    #expect(!stage.dictationContent.isRevealed)

    stage.retract()
    // Sigue grande mientras dura el cierre.
    #expect(stage.estado == .reposo)
    #expect(stage.encuadre == .abierta)

    await reloj.waitForSleeper()
    // En vueltas y no de un solo golpe: el encogimiento y la limpieza del
    // retract arman su espera cada uno por su lado, y un único `advance` puede
    // caer entre los dos.
    while stage.encuadre != .reposo {
      reloj.advance(by: HUDStage.dismissDuration)
      await Task.yield()
    }
    #expect(stage.marcoDeLaVentana.height == 39)
    #expect(stage.marcoDeLaVentana.width == 190)
  }

  /// El log dice qué ventana estaba puesta en cada estado, que es lo que
  /// vuelve diagnosticable esto sin mirar la pantalla de nadie:
  ///
  ///     log show --predicate 'subsystem == "cl.espaciodigital.dilo"' --last 5m
  @Test func elLogLlevaLaVentanaDeCadaEstado() {
    #expect(
      RegistroDeLaMuesca.linea(
        estado: .reposo,
        ventana: HUDNotchGeometry.windowSize(for: simulado, encuadre: .reposo),
        forma: HUDNotchGeometry.reposoSize(for: simulado),
        pantalla: simulado.nombre,
        notchReal: false
      ) == "estado=reposo ventana=190x39 forma=160x24 pantalla=DELL U2412M notchReal=false"
    )
    #expect(
      RegistroDeLaMuesca.linea(
        estado: .dictando,
        ventana: HUDNotchGeometry.windowSize(for: simulado, encuadre: .abierta),
        forma: CGSize(width: 400, height: 88),
        pantalla: simulado.nombre,
        notchReal: false
      ) == "estado=dictando ventana=488x190 forma=400x88 pantalla=DELL U2412M notchReal=false"
    )
  }
}

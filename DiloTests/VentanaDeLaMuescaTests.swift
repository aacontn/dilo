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
        // Ni un punto de alto de más: en reposo no hay sombra que alojar, y
        // lo que sobrara sería barra de menús que la ventana se queda.
        #expect(ventana.height == silueta.height)
      case .abierta:
        let holgura = HUDNotchGeometry.holguraDeRevelacion(for: pantalla)
        #expect(ventana.width == HUDMetrics.standard.contentWidth + holgura * 2)
        #expect(
          ventana.height == HUDNotchGeometry.altoDeLaFormaMasAlta(for: pantalla) + holgura
        )
      }
    }
  }

  /// Los números de la pantalla del reclamo, escritos enteros: 178×24 en
  /// reposo contra los 488×190 de la forma abierta.
  ///
  /// El 190×45 que Alfonso midió con `CGWindowListCopyWindowInfo` el
  /// 2026-09-22 salía de alojar la sombra en reposo. Los 18 puntos de ancho
  /// que quedan son las dos alas cóncavas, que son negro de la propia
  /// silueta: una ventana de 160 exactos se las recortaría.
  @Test func enReposoLaVentanaNoTapaLaBarraDeMenus() {
    let reposo = HUDNotchGeometry.windowSize(for: simulado, encuadre: .reposo)
    #expect(reposo == CGSize(width: 178, height: 24))
    #expect(HUDNotchGeometry.windowSize(for: simulado) == CGSize(width: 488, height: 190))
    // Lo que el reclamo medía: la ventana en reposo no baja de la barra de
    // menús ni un punto.
    #expect(reposo.height == simulado.menuBarHeight)
    #expect(reposo.width < 180)
  }

  /// En reposo la ventana no lleva sombra, así que tampoco lleva holgura para
  /// ella: lo único que cuelga fuera de la silueta son las dos alas cóncavas.
  ///
  /// Las dos mitades del mismo arreglo, y por eso se afirman juntas: la
  /// sombra dibujada y la holgura de la ventana salían del mismo número, y
  /// bajar una sin la otra deja o un halo recortado o una ventana con
  /// pantalla muerta adentro.
  @Test func enReposoNoHayHolguraDeSombraPorqueNoHaySombra() {
    #expect(
      HUDNotchGeometry.holguraDeSombra()
        == HUDMetrics.standard.shadowRadius + HUDMetrics.standard.shadowOffsetY
    )
    #expect(HUDNotchGeometry.holguraDeSombra() == 15)
    for pantalla in [simulado, pildora, conNotch] {
      let holgura = HUDNotchGeometry.holguraEnReposo(for: pantalla)
      #expect(holgura == HUDNotchGeometry.filletSize(for: pantalla), "sólo las alas")
      #expect(holgura < HUDNotchGeometry.holguraDeSombra(), "la sombra no entra en reposo")
      // Y la holgura de la revelación sí la sigue llevando: al abrirse la
      // forma cuelga de verdad sobre el escritorio.
      #expect(
        HUDNotchGeometry.holguraDeRevelacion(for: pantalla)
          >= HUDNotchGeometry.holguraDeSombra()
      )
    }
  }

  /// La ventana en reposo no baja de la barra de menús en ninguna pantalla:
  /// su borde de abajo es el borde de abajo de la silueta.
  @Test func laVentanaEnReposoTerminaDondeTerminaLaSilueta() {
    for pantalla in [simulado, pildora, conNotch] {
      let ventana = HUDNotchGeometry.windowFrame(for: pantalla, encuadre: .reposo)
      let silueta = HUDNotchGeometry.siluetaEnPantalla(
        for: pantalla,
        tamaño: HUDNotchGeometry.reposoSize(for: pantalla),
        encuadre: .reposo
      )
      #expect(ventana.minY == silueta.minY)
      #expect(ventana.height == silueta.height)
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
  private func escenarioEnReposo(
    _ reloj: DrivenClock,
    puntero: CursorSimulado = CursorSimulado()
  ) -> HUDStage {
    let stage = HUDStage(
      settings: AppSettings.previewStore(),
      reloj: reloj.deadlineClock,
      punteroEn: { puntero.punto }
    )
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
  /// dentro de los 178×24, los puntos que ocupan las alas son barra de menús
  /// de la app de al lado.
  @MainActor
  @Test func enReposoConElPunteroFueraLaVentanaIgnoraElMouse() {
    let stage = escenarioEnReposo(DrivenClock())
    #expect(stage.encuadre == .reposo)
    #expect(stage.ventanaIgnoraElMouse)

    // Un punto dentro de la ventana pero al costado de la silueta: la franja
    // de las alas no toma clics.
    let ventana = stage.marcoDeLaVentana
    stage.punteroSeMovio(a: CGPoint(x: ventana.minX + 2, y: ventana.midY))
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

  // MARK: El hover

  /// Posarse sobre la muesca revela contexto, y el único que lo decide es el
  /// monitor del puntero.
  ///
  /// Sale del reporte del 2026-09-22: «hover no hace nada». Eran dos cosas a
  /// la vez, y las dos se afirman acá. La primera, que la revelación exigía
  /// `contexto`, que sólo se escribe al terminar el primer dictado: en una app
  /// recién instalada la condición era falsa siempre. La segunda, que quien
  /// avisaba de la entrada era el `onHover` de la vista, que no puede verla —
  /// la ventana está ignorando el mouse justo cuando el puntero llega— y que
  /// además mandaba una salida falsa al crecer la ventana.
  ///
  /// Nada de esto toca la GUI: el puntero es simulado y el reloj es dirigido.
  @MainActor
  @Test func elPunteroSobreLaMuescaAbreElContextoYAlIrseLoCierra() async {
    let reloj = DrivenClock()
    let puntero = CursorSimulado()
    let stage = escenarioEnReposo(reloj, puntero: puntero)
    let afuera = CGPoint(x: 400, y: simulado.frame.maxY - 8)

    // Recién instalada: nadie dictó todavía, así que no hay nada que contar.
    // Antes esto bastaba para que el hover no hiciera absolutamente nada.
    #expect(stage.dictationContent.contexto == nil)
    #expect(stage.dictationContent.contextoVisible == nil)

    puntero.punto = afuera
    stage.punteroSeMovio(a: afuera)
    #expect(!stage.punteroSobreLaSilueta)
    #expect(!stage.dictationContent.punteroEncima)

    // Encima: el mouse se toma en el acto —si no, el primer clic se pierde—
    // y el contexto todavía no, que es para lo que existe el retardo.
    puntero.punto = sobreLaMuesca
    stage.punteroSeMovio(a: sobreLaMuesca)
    #expect(stage.punteroSobreLaSilueta)
    #expect(!stage.ventanaIgnoraElMouse)
    #expect(!stage.dictationContent.punteroEncima)

    await reloj.waitForSleeper()
    // Por vueltas y no de un golpe: el sondeo del puntero y el retardo del
    // hover arman su espera cada uno por su lado, y un único `advance` puede
    // caer antes de que la segunda se registre.
    while !stage.dictationContent.punteroEncima {
      reloj.advance(by: HUDStage.toleranciaDelHover)
      await Task.yield()
    }
    #expect(stage.dictationContent.contextoVisible == DictationHUDContent.contextoDeFabrica)
    #expect(stage.encuadre == .abierta, "la ventana creció antes que el panel")
    #expect(!stage.estado.captura, "un hover jamás abre el micrófono")

    // Y al irse se cierra tras la misma gracia, sin que la vista avise nada.
    puntero.punto = afuera
    stage.punteroSeMovio(a: afuera)
    #expect(stage.dictationContent.punteroEncima, "todavía no: la gracia manda")
    await reloj.waitForSleeper()
    while stage.dictationContent.punteroEncima {
      reloj.advance(by: HUDStage.toleranciaDelHover)
      await Task.yield()
    }
    #expect(stage.dictationContent.contextoVisible == nil)
    #expect(stage.ventanaIgnoraElMouse)
  }

  /// Lo último que se dictó manda sobre el nombre de fábrica: el hover está
  /// para eso, y el nombre es sólo lo que queda cuando no hay nada mejor.
  @MainActor
  @Test func elHoverPrefiereLoUltimoDictado() {
    let content = DictationHUDContent()
    content.punteroEncima = true
    #expect(content.contextoVisible == DictationHUDContent.contextoDeFabrica)
    content.modoActivo = "Correo"
    #expect(content.contextoVisible == "Correo")
    content.contexto = "Listo · «quedamos el martes»"
    #expect(content.contextoVisible == "Listo · «quedamos el martes»")
    content.punteroEncima = false
    #expect(content.contextoVisible == nil)
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
    #expect(stage.marcoDeLaVentana.height == 24)

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
    #expect(stage.marcoDeLaVentana.height == 24)
    #expect(stage.marcoDeLaVentana.width == 178)
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
      ) == "estado=reposo ventana=178x24 forma=160x24 pantalla=DELL U2412M notchReal=false"
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

  /// Y una línea al arrancar, con su prefijo: si falta, lo que no ocurrió fue
  /// el montaje del escenario, que es un diagnóstico distinto de «la forma
  /// salió mal».
  @Test func elLogDejaUnaLineaAlArrancar() {
    #expect(
      RegistroDeLaMuesca.lineaDelArranque(
        estado: .reposo,
        ventana: HUDNotchGeometry.windowSize(for: simulado, encuadre: .reposo),
        forma: HUDNotchGeometry.reposoSize(for: simulado),
        pantalla: simulado.nombre,
        notchReal: false
      )
        == "arranque estado=reposo ventana=178x24 forma=160x24 "
        + "pantalla=DELL U2412M notchReal=false"
    )
  }

  /// El gating del registro, que es lo que lo dejó mudo.
  ///
  /// En Debug pasa siempre. En Release hay que encenderlo, y la variable de
  /// entorno sola no alcanzaba: una app abierta desde el Finder, desde el Dock
  /// o con `open -a` no hereda el entorno de ningún terminal, así que
  /// `DILO_LOG_MUESCA=1` se exportaba y no llegaba nunca. El ajuste sí llega.
  @Test func elRegistroPasaEnDebugYSoloEncendidoEnRelease() {
    #expect(RegistroDeLaMuesca.dejaPasar(debug: true, entorno: [:], ajustes: nil))
    #expect(!RegistroDeLaMuesca.dejaPasar(debug: false, entorno: [:], ajustes: nil))

    let interruptor = RegistroDeLaMuesca.interruptor
    #expect(
      RegistroDeLaMuesca.dejaPasar(debug: false, entorno: [interruptor: "1"], ajustes: nil)
    )
    #expect(
      RegistroDeLaMuesca.dejaPasar(debug: false, entorno: [interruptor: "TRUE"], ajustes: nil)
    )
    #expect(
      !RegistroDeLaMuesca.dejaPasar(debug: false, entorno: [interruptor: "0"], ajustes: nil)
    )

    let suite = "cl.espaciodigital.dilo.tests.muesca"
    let ajustes = UserDefaults(suiteName: suite)
    ajustes?.removeObject(forKey: interruptor)
    #expect(!RegistroDeLaMuesca.dejaPasar(debug: false, entorno: [:], ajustes: ajustes))
    ajustes?.set(true, forKey: interruptor)
    #expect(RegistroDeLaMuesca.dejaPasar(debug: false, entorno: [:], ajustes: ajustes))
    ajustes?.removeObject(forKey: interruptor)
  }
}

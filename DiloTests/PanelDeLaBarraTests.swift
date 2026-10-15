import CoreGraphics
import Foundation
import Testing

@testable import Dilo

/// El ícono de la barra: clic izquierdo abre Dilo, clic derecho el panel que
/// reemplaza al menú gris (2026-10-15). Todo sin dibujar ni abrir ventanas.
@Suite("El panel de la barra")
struct PanelDeLaBarraTests {
  private let ahora = Date(timeIntervalSinceReferenceDate: 800_000_000)

  /// Todo encendido: lo más que el menú gris llegaba a mostrar.
  private var entradaCompleta: PanelDeLaBarra.Entrada {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.atajoDeDictar = "fn"
    entrada.atajoDeLeer = "⌥ ⎋"
    entrada.ultimo = PanelDeLaBarra.Ultimo(
      entregado: "Hola Marta, quedamos el martes.",
      original: "eh hola marta quedamos el martes",
      propuesta: "Estimada Marta: confirmo el martes.",
      modo: "Correo",
      cuando: ahora.addingTimeInterval(-120)
    )
    entrada.tomaGuardada = "0:12"
    entrada.modos = [.init(id: "correo", nombre: "Correo"), .init(id: "nota", nombre: "Nota")]
    entrada.modoElegido = "correo"
    entrada.ahora = ahora
    return entrada
  }

  @Test func elIzquierdoAbreDiloYElDerechoElPanel() {
    #expect(ClicEnLaBarra.decidir(boton: .izquierdo, conControl: false) == .abrirDilo)
    #expect(ClicEnLaBarra.decidir(boton: .derecho, conControl: false) == .abrirPanel)
    // ⌃clic es el clic derecho de todo el Mac.
    #expect(ClicEnLaBarra.decidir(boton: .izquierdo, conControl: true) == .abrirPanel)
    // Apretado por Accesibilidad: antes abría el menú con todo, y el panel es
    // su reemplazo.
    #expect(ClicEnLaBarra.decidir(boton: .otro, conControl: false) == .abrirPanel)
  }

  /// La promesa del cambio: nada de lo que ofrecía el menú gris se pierde.
  @Test func nadaDelMenuGrisSePierde() {
    let contenido = PanelDeLaBarra.contenido(entradaCompleta)
    let delMenu: [PanelDeLaBarra.Accion] = [
      .dictar, .dictarNota, .leerSeleccion, .transcribirArchivo,
      .copiar(.entregado), .copiar(.original), .copiar(.propuesta),
      .reintentarToma, .descartarToma,
      .abrirDilo, .primerosPasos, .novedades, .buscarActualizaciones, .salir,
    ]
    for accion in delMenu {
      #expect(contenido.todasLasAcciones.contains(accion), "falta \(accion)")
    }
    // Y lo nuevo: el modo del atajo general, con «Normal».
    #expect(contenido.todasLasAcciones.contains(.elegirModo(nil)))
    #expect(contenido.todasLasAcciones.contains(.elegirModo("correo")))
  }

  @Test func ningunaAccionSeOfreceDosVeces() {
    let acciones = PanelDeLaBarra.contenido(entradaCompleta).todasLasAcciones
    #expect(Set(acciones).count == acciones.count)
  }

  /// Lo que el anfitrión no puede hacer se esconde, no falla.
  @Test func loQueElAnfitrionNoAdmiteNoAparece() {
    var entrada = entradaCompleta
    entrada.admiteNota = false
    entrada.admiteLeer = false
    let acciones = PanelDeLaBarra.contenido(entrada).todasLasAcciones
    #expect(!acciones.contains(.dictarNota))
    #expect(!acciones.contains(.leerSeleccion))
    #expect(acciones.contains(.dictar))
  }

  @Test func sinNadaDictadoNoHayQueCopiarNiToma() {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.ultimo = PanelDeLaBarra.Ultimo(entregado: "  \n ", original: "", cuando: ahora)
    let contenido = PanelDeLaBarra.contenido(entrada)
    #expect(contenido.ultimo == nil)
    #expect(contenido.toma == nil)
    #expect(!contenido.todasLasAcciones.contains(.copiar(.entregado)))
    #expect(!contenido.todasLasAcciones.contains(.reintentarToma))
    // Sin modos no hay fila de modos: con sólo «Normal» no hay qué elegir.
    #expect(contenido.modos.isEmpty)
  }

  /// Lo dicho sin el modo y lo que el modo propuso sólo cuando son otra
  /// cosa que lo entregado: dos filas que copian lo mismo es ruido.
  @Test func lasOtrasVersionesSoloSiSonOtraCosa() {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.ahora = ahora
    entrada.ultimo = PanelDeLaBarra.Ultimo(
      entregado: "quedamos el martes",
      original: "quedamos el martes",
      cuando: ahora
    )
    #expect(PanelDeLaBarra.contenido(entrada).ultimo?.otras.isEmpty == true)

    entrada.ultimo?.propuesta = ""
    #expect(PanelDeLaBarra.contenido(entrada).ultimo?.otras.isEmpty == true)

    entrada.ultimo?.original = "eh quedamos el martes"
    entrada.ultimo?.propuesta = "Quedamos el martes a las 10."
    let otras = PanelDeLaBarra.contenido(entrada).ultimo?.otras.map(\.copia)
    #expect(otras == [.original, .propuesta])
  }

  @Test func loUltimoVaEnUnaLineaYDiceDeQueModoVino() {
    var entrada = entradaCompleta
    entrada.ultimo?.entregado = "Hola Marta,\nquedamos el martes."
    let ultimo = PanelDeLaBarra.contenido(entrada).ultimo
    #expect(ultimo?.titulo == "Hola Marta, quedamos el martes.")
    #expect(ultimo?.detalle.hasPrefix("Correo · ") == true)

    entrada.ultimo?.modo = nil
    let sinModo = PanelDeLaBarra.contenido(entrada).ultimo
    #expect(sinModo?.detalle.hasPrefix(String(localized: "Dictado") + " · ") == true)
  }

  /// El dictado le gana a la lectura y las dos a un archivo de fondo: el
  /// mismo orden en que el ícono los dice.
  @Test func elEncabezadoDiceLoMasUrgente() {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.atajoDeDictar = "fn"
    #expect(entrada.actividad == .lista)
    var encabezado = PanelDeLaBarra.contenido(entrada).encabezado
    #expect(encabezado.estado == String(localized: "Listo para dictar"))
    #expect(encabezado.tono == .reposo)
    #expect(encabezado.atajo == "fn")

    entrada.progresoDeArchivo = 0.404
    encabezado = PanelDeLaBarra.contenido(entrada).encabezado
    #expect(entrada.actividad == .transcribiendo(0.404))
    #expect(encabezado.estado == String(localized: "Transcribiendo · \(40) %"))
    #expect(encabezado.tono == .activo)

    entrada.leyendo = true
    #expect(entrada.actividad == .leyendo)
    entrada.dictando = true
    #expect(entrada.actividad == .dictando)
    #expect(PanelDeLaBarra.contenido(entrada).encabezado.estado == String(localized: "Dictando"))
  }

  @Test func sinGatilloNoHayTeclaYUnaTomaPintaElPuntoDeAmbar() {
    var entrada = PanelDeLaBarra.Entrada()
    #expect(PanelDeLaBarra.contenido(entrada).encabezado.atajo == nil)
    entrada.tomaGuardada = "0:12"
    #expect(PanelDeLaBarra.contenido(entrada).encabezado.tono == .aviso)
    #expect(PanelDeLaBarra.contenido(entrada).toma?.reloj == "0:12")
  }

  /// Las filas dicen lo que va a pasar, como decía el menú.
  @Test func dictarYLeerCambianDeNombreMientrasPasan() {
    var entrada = PanelDeLaBarra.Entrada()
    entrada.atajoDeLeer = "⌥ ⎋"
    func titulo(_ accion: PanelDeLaBarra.Accion) -> String? {
      PanelDeLaBarra.contenido(entrada).acciones.first { $0.accion == accion }?.titulo
    }
    #expect(titulo(.dictar) == String(localized: "Empezar a dictar"))
    #expect(titulo(.leerSeleccion) == String(localized: "Leer lo seleccionado"))
    #expect(PanelDeLaBarra.contenido(entrada).acciones.first { $0.accion == .leerSeleccion }?.atajo == "⌥ ⎋")
    entrada.dictando = true
    entrada.leyendo = true
    #expect(titulo(.dictar) == String(localized: "Parar el dictado"))
    #expect(titulo(.leerSeleccion) == String(localized: "Dejar de leer"))
  }

  /// Un modo borrado de la biblioteca deja de estar elegido en vez de
  /// quedar apuntando a nada, como en el panel de la muesca.
  @Test func losModosMarcanAlElegidoYOlvidanAlBorrado() {
    var entrada = entradaCompleta
    var chips = PanelDeLaBarra.contenido(entrada).modos
    #expect(chips.map(\.id) == [nil, "correo", "nota"])
    #expect(chips.filter(\.elegido).map(\.id) == ["correo"])

    entrada.modoElegido = "borrado"
    chips = PanelDeLaBarra.contenido(entrada).modos
    #expect(chips.filter(\.elegido).map(\.id) == [nil])
  }

  /// Como un menú, lo elegido cierra el panel; copiar se queda a mostrar el
  /// ✓ y elegir el modo no cierra, porque el cambio se ve ahí mismo.
  @Test func queCierraElPanel() {
    #expect(PanelDeLaBarra.Accion.dictar.cierre == .alTiro)
    #expect(PanelDeLaBarra.Accion.abrirDilo.cierre == .alTiro)
    #expect(PanelDeLaBarra.Accion.reintentarToma.cierre == .alTiro)
    #expect(PanelDeLaBarra.Accion.copiar(.original).cierre == .trasElAcuse)
    #expect(PanelDeLaBarra.Accion.elegirModo("correo").cierre == .seQueda)
  }

  /// Bajo el ícono, con el borde derecho un poco más allá de su centro, y
  /// separado de la barra.
  @Test func cuelgaDelIconoAlineadoASuDerecha() {
    let pantalla = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let icono = CGRect(x: 1500, y: 1056, width: 24, height: 24)
    let marco = PanelDeLaBarra.marco(tamaño: CGSize(width: 300, height: 360), ancla: icono, pantalla: pantalla)
    #expect(marco.maxX == icono.midX + PanelDeLaBarra.aireDelIcono)
    #expect(marco.maxY == icono.minY - PanelDeLaBarra.separacion)
    #expect(marco.size == CGSize(width: 300, height: 360))
  }

  @Test func noSeSaleDeLaPantalla() {
    let pantalla = CGRect(x: 1920, y: 0, width: 1440, height: 900)
    let tamaño = CGSize(width: 300, height: 360)
    let alBorde = PanelDeLaBarra.marco(
      tamaño: tamaño,
      ancla: CGRect(x: 3350, y: 876, width: 24, height: 24),
      pantalla: pantalla
    )
    #expect(alBorde.maxX == pantalla.maxX - PanelDeLaBarra.margen)
    let alOtroBorde = PanelDeLaBarra.marco(
      tamaño: tamaño,
      ancla: CGRect(x: 1925, y: 876, width: 24, height: 24),
      pantalla: pantalla
    )
    #expect(alOtroBorde.minX == pantalla.minX + PanelDeLaBarra.margen)
  }

  /// Desde la muesca va centrado bajo la silueta: está al medio de la barra.
  @Test func bajoLaMuescaVaCentrado() {
    let pantalla = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let silueta = CGRect(x: 880, y: 1056, width: 160, height: 24)
    let marco = PanelDeLaBarra.marco(
      tamaño: CGSize(width: 300, height: 360),
      ancla: silueta,
      pantalla: pantalla,
      centrado: true
    )
    #expect(marco.midX == silueta.midX)
    #expect(marco.maxY == silueta.minY - PanelDeLaBarra.separacion)
  }
  private let simulado = HUDScreenSnapshot(
    id: 2,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    safeAreaTop: 0,
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil,
    menuBarHeight: 24
  )

  /// El clic en la muesca en reposo abre el panel colgando de la silueta:
  /// centrada arriba, del tamaño del reposo.
  @MainActor
  @Test func laMuescaDaSuSiluetaComoAncla() {
    let stage = HUDStage(settings: AppSettings.previewStore())
    stage.colocar(en: simulado)
    let silueta = stage.siluetaDeAcciones
    let reposo = HUDNotchGeometry.reposoSize(for: simulado)
    #expect(silueta?.size == reposo)
    #expect(silueta?.midX == simulado.frame.midX)
    #expect(silueta?.maxY == simulado.frame.maxY)
  }

  /// Con el panel de la barra abierto, posarse en la muesca no abre el panel
  /// del hover encima, y si estaba abierto se recoge. Al cerrarse, el hover
  /// vuelve a andar.
  @MainActor
  @Test func conElPanelDeLaBarraAbiertoElHoverNoSeAbre() async {
    let reloj = DrivenClock()
    let stage = HUDStage(settings: AppSettings.previewStore(), reloj: reloj.deadlineClock, punteroEn: { .zero })
    stage.colocar(en: simulado)
    let silueta = HUDNotchGeometry.siluetaEnPantalla(
      for: simulado, tamaño: HUDNotchGeometry.reposoSize(for: simulado), encuadre: .reposo
    )
    let encima = CGPoint(x: silueta.midX, y: silueta.midY)
    func esperarAQueAbra() async {
      for _ in 0..<100 where !stage.dictationContent.punteroEncima {
        reloj.advance(by: .milliseconds(10))
        await Task.yield()
      }
    }

    stage.punteroSeMovio(a: encima)
    await esperarAQueAbra()
    #expect(stage.dictationContent.punteroEncima)

    stage.panelDeLaBarraAbierto = true
    #expect(!stage.dictationContent.punteroEncima, "el hover se recoge")
    stage.punteroSeMovio(a: CGPoint(x: encima.x + 2, y: encima.y))
    await esperarAQueAbra()
    #expect(!stage.dictationContent.punteroEncima, "y no vuelve mientras el panel está")

    stage.panelDeLaBarraAbierto = false
    stage.punteroSeMovio(a: encima)
    await esperarAQueAbra()
    #expect(stage.dictationContent.punteroEncima)
  }
}

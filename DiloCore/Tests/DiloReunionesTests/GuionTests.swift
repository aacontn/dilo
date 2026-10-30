import Foundation
import Testing

@testable import DiloReuniones

@Suite("Del audio al guion: relojes, hablantes, eco, dictado y líneas")
struct GuionTests {
  private let utc = TimeZone(identifier: "UTC")!
  private let inicio = Date(timeIntervalSince1970: 1_792_600_200)  // 2026-10-21 16:30:00 UTC

  @Test func lasAnclasCorrigenLaDeriva() {
    // `ellos` corre 0,1 % lento contra el Mac: en 3600 s del Mac entrega
    // 3596,4 s de audio. Sin corregir, Yo contestaría antes de la pregunta.
    let anclas = [
      AnclaDeReloj(pista: nil, muestra: 0, host: 1_000),
      AnclaDeReloj(pista: .ellos, muestra: 0, host: 1_000),
      AnclaDeReloj(pista: .ellos, muestra: Int64(3596.4 * 16_000), host: 4_600),
    ]
    let a = AlineacionDeRelojes(anclas)
    #expect(abs(a.segundos(local: 3596.4, pista: .ellos) - 3600) < 0.001)
    #expect(abs(a.segundos(local: 1798.2, pista: .ellos) - 1800) < 0.001)
    #expect(abs((a.derivaPPM(pista: .ellos) ?? 0) + 1_000) < 1)
    // Y la vuelta.
    #expect(abs(a.local(segundos: 3600, pista: .ellos) - 3596.4) < 0.001)
  }

  @Test func unaPistaQueEmpezoTardeSeCorre() {
    // El tap con `TapAutoStart` no corre hasta que algo suena: su primera
    // muestra llega 7 s después de «Grabar».
    let anclas = [AnclaDeReloj(pista: nil, muestra: 0, host: 500), AnclaDeReloj(pista: .ellos, muestra: 0, host: 507)]
    let a = AlineacionDeRelojes(anclas)
    #expect(abs(a.segundos(local: 1, pista: .ellos) - 8) < 0.0001)
    // Sin anclas de la pista se asume que empezó con la reunión.
    #expect(a.segundos(local: 3, pista: .yo) == 3)
  }

  @Test func lasAnclasSeEscribenYSeLeenPorLinea() {
    let datos = AnclaDeReloj.codificar(AnclaDeReloj(pista: .yo, muestra: 160_000, host: 12.5))
      + Data("basura\n".utf8)
      + AnclaDeReloj.codificar(AnclaDeReloj(pista: nil, muestra: 0, host: 2))
    #expect(AnclaDeReloj.leer(datos).count == 2)
  }

  /// Dos hablantes: el 0 de 0 a 2 s, el 1 de 2 a 4 s, y los dos de 4 a 5 s.
  private var actividad: ActividadDeHablantes {
    ActividadDeHablantes.desde(
      segmentos: [
        .init(hablante: 0, desde: 0, hasta: 2), .init(hablante: 1, desde: 2, hasta: 5),
        .init(hablante: 0, desde: 4, hasta: 5),
      ],
      hablantes: 2
    )
  }

  @Test func cadaPalabraSeVaConQuienMasHablaEnSuTramo() {
    let a = actividad
    #expect(AtribucionDeHablantes.hablante(desde: 0.5, hasta: 0.9, en: a) == .init(hablante: 0))
    #expect(AtribucionDeHablantes.hablante(desde: 2.1, hasta: 2.6, en: a) == .init(hablante: 1))
    // Cruzando el cambio, gana el que tiene más del tramo.
    #expect(AtribucionDeHablantes.hablante(desde: 1.8, hasta: 2.5, en: a).hablante == 1)
    // Los dos sobre el umbral: solape.
    #expect(AtribucionDeHablantes.hablante(desde: 4.2, hasta: 4.6, en: a).solape)
  }

  @Test func unaPalabraEnUnHuecoMiraCerca() {
    let a = ActividadDeHablantes.desde(segmentos: [.init(hablante: 1, desde: 0, hasta: 1)], hablantes: 2, duracion: 5)
    // A 0,3 s del final del segmento: dentro del margen.
    #expect(AtribucionDeHablantes.hablante(desde: 1.2, hasta: 1.4, en: a).hablante == 1)
    // Lejos de todo: nadie.
    #expect(AtribucionDeHablantes.hablante(desde: 3, hasta: 3.4, en: a).hablante == nil)
  }

  @Test func losSegmentosSalenDeLaActividad() {
    let segmentos = actividad.segmentos()
    #expect(segmentos.count == 3)
    #expect(segmentos.first == .init(hablante: 0, desde: 0, hasta: 2))
  }

  private func reunion(salida: SalidaDeAudio = .audifonos, asistentes: [String] = []) -> Reunion {
    Reunion(
      id: "r", titulo: "Reunión con Camila", inicio: inicio,
      evento: EventoDeLaReunion(titulo: "Reunión con Camila", asistentes: asistentes), salida: salida
    )
  }

  @Test func elArmadoIntercalaYNumeraPorLlegada() {
    // El diarizador ordena al revés de como llegaron: el índice 1 habla
    // primero. Igual sale «Hablante 2» el primero.
    let actividad = ActividadDeHablantes.desde(
      segmentos: [.init(hablante: 1, desde: 0, hasta: 3), .init(hablante: 0, desde: 5, hasta: 8)], hablantes: 2
    )
    let r = ArmadoDelGuion.armar(
      yo: [PalabraDeLaPista(texto: "¿Cerramos?", desde: 3.5, hasta: 4)],
      ellos: [
        PalabraDeLaPista(texto: "Sí,", desde: 0.5, hasta: 0.8), PalabraDeLaPista(texto: "pero", desde: 0.9, hasta: 1.1),
        PalabraDeLaPista(texto: "Ojo.", desde: 5.5, hasta: 6),
      ],
      actividad: actividad, relojes: [], reunion: reunion()
    )
    #expect(r.palabras.map(\.texto) == ["Sí,", "pero", "¿Cerramos?", "Ojo."])
    #expect(r.palabras.map(\.hablante) == ["h2", "h2", "yo", "h3"])
    #expect(r.hablantes.map(\.id) == ["yo", "h2", "h3"])
  }

  @Test func sinDiarizadorLaLlamadaEsUnaSolaVoz() {
    let r = ArmadoDelGuion.armar(
      yo: [], ellos: [PalabraDeLaPista(texto: "hola", desde: 0, hasta: 0.4)],
      actividad: nil, relojes: [], reunion: reunion()
    )
    #expect(r.palabras.first?.hablante == "h2")
  }

  @Test func enUnoAUnoElOtroSaleConSuNombre() {
    let r = ArmadoDelGuion.armar(
      yo: [], ellos: [PalabraDeLaPista(texto: "hola", desde: 0, hasta: 0.4)],
      actividad: nil, relojes: [], reunion: reunion(asistentes: ["Camila"])
    )
    #expect(r.hablantes.last?.nombreVisible == "Camila")
    // Con dos asistentes no hay nada que decidir solo.
    let grupo = ArmadoDelGuion.armar(
      yo: [], ellos: [PalabraDeLaPista(texto: "hola", desde: 0, hasta: 0.4)],
      actividad: nil, relojes: [], reunion: reunion(asistentes: ["Camila", "Pedro"])
    )
    #expect(grupo.hablantes.last?.nombre == nil)
  }

  @Test func unaPalabraSueltaTomaAlVecino() {
    let actividad = ActividadDeHablantes.desde(
      segmentos: [.init(hablante: 0, desde: 0, hasta: 1)], hablantes: 1, duracion: 10
    )
    let r = ArmadoDelGuion.armar(
      yo: [],
      ellos: [PalabraDeLaPista(texto: "uno", desde: 0.2, hasta: 0.5), PalabraDeLaPista(texto: "dos", desde: 2.5, hasta: 2.8)],
      actividad: actividad, relojes: [], reunion: reunion()
    )
    #expect(r.palabras.map(\.hablante) == ["h2", "h2"])
  }

  @Test func conParlantesElEcoDeYoNoVaAlGuion() {
    let r = ArmadoDelGuion.armar(
      yo: [
        PalabraDeLaPista(texto: "despacho", desde: 2.2, hasta: 2.6),  // eco: repite a ellos en 0,2 s
        PalabraDeLaPista(texto: "Perfecto,", desde: 9, hasta: 9.5),  // mía
        PalabraDeLaPista(texto: "sí", desde: 20.1, hasta: 20.2),  // corta y sola: se queda
      ],
      ellos: [
        PalabraDeLaPista(texto: "Despacho,", desde: 2, hasta: 2.4), PalabraDeLaPista(texto: "sí", desde: 20, hasta: 20.1),
      ],
      actividad: nil, relojes: [], reunion: reunion(salida: .parlantes)
    )
    let deYo = r.palabras.filter { $0.pista == .yo }
    #expect(deYo.map { $0.tiene(.eco) } == [true, false, false])
    // Con audífonos no se busca eco.
    let conAudifonos = ArmadoDelGuion.armar(
      yo: [PalabraDeLaPista(texto: "despacho", desde: 2.2, hasta: 2.6)],
      ellos: [PalabraDeLaPista(texto: "despacho", desde: 2, hasta: 2.4)],
      actividad: nil, relojes: [], reunion: reunion(salida: .audifonos)
    )
    #expect(conAudifonos.palabras.allSatisfy { !$0.tiene(.eco) })
  }

  @Test func unEcoDePalabrasCortasSeVePorLaVecina() {
    var palabras = [
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 1, hasta: 1.2, texto: "ya"),
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 1.2, hasta: 1.4, texto: "no"),
      PalabraDelGuion(pista: .yo, hablante: "yo", desde: 1.3, hasta: 1.5, texto: "ya"),
      PalabraDelGuion(pista: .yo, hablante: "yo", desde: 1.5, hasta: 1.7, texto: "no"),
    ]
    LimpiezaDelGuion.marcarEco(&palabras)
    #expect(palabras.filter { $0.pista == .yo }.allSatisfy { $0.tiene(.eco) })
  }

  @Test func loDictadoDuranteLaReunionNoEsLaReunion() {
    var r = reunion()
    r.dictados = [TramoDeDictado(desde: 10, hasta: 12)]
    let armado = ArmadoDelGuion.armar(
      yo: [
        PalabraDeLaPista(texto: "Escribe", desde: 10.3, hasta: 10.6),
        PalabraDeLaPista(texto: "Volviendo", desde: 13, hasta: 13.5),
      ],
      ellos: [], actividad: nil, relojes: [], reunion: r
    )
    #expect(armado.palabras.map { $0.tiene(.dictado) } == [true, false])
    #expect(LineasDelGuion.armar(armado.palabras).map(\.texto) == ["Volviendo"])
  }

  @Test func lasLineasSeParteEnCadaCambioDeVoz() {
    let palabras = [
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 0, hasta: 0.4, texto: "Te"),
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 0.4, hasta: 0.8, texto: "cuento"),
      PalabraDelGuion(pista: .yo, hablante: "yo", desde: 0.9, hasta: 1.1, texto: "Ya."),
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 1.0, hasta: 1.4, texto: "lo"),
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 1.4, hasta: 1.8, texto: "nuestro."),
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 9, hasta: 9.4, texto: "Otra."),
    ]
    let lineas = LineasDelGuion.armar(palabras)
    // La interjección parte la línea del otro, en su lugar en el tiempo, y
    // una pausa larga abre otra intervención.
    #expect(lineas.map(\.texto) == ["Te cuento", "Ya.", "lo nuestro.", "Otra."])
    #expect(lineas.map(\.hablante) == ["h2", "yo", "h2", "h2"])
    #expect(lineas[2].primeraPalabra == 3)
  }

  @Test func elGuionLegibleTieneCabeceraYUnaLineaPorIntervencion() {
    var r = reunion()
    r.fin = inicio.addingTimeInterval(42 * 60)
    r.hablantes.append(Hablante(id: "h2", nombre: "Camila", pista: .ellos))
    r.hablantes.append(Hablante(id: "h3", pista: .ellos))
    let lineas = [
      LineaDelGuion(hablante: "yo", desde: 61, hasta: 63, texto: "Partamos por el precio.", solape: false, primeraPalabra: 0),
      LineaDelGuion(hablante: "h2", desde: 70, hasta: 75, texto: "Ya, te cuento.", solape: false, primeraPalabra: 4),
    ]
    let md = LineasDelGuion.markdown(reunion: r, lineas: lineas, zona: utc)
    #expect(md == """
      # Reunión con Camila

      21 oct 2026, 16:30 · 42 min · Hablan: Yo, Camila

      Yo · 16:31 — Partamos por el precio.

      Camila · 16:31 — Ya, te cuento.

      """)
  }

  @Test func guionJSONLAguantaUnaLineaRota() throws {
    let palabras = [
      PalabraDelGuion(pista: .yo, hablante: "yo", desde: 0, hasta: 1, texto: "hola", marcas: [.dictado]),
      PalabraDelGuion(pista: .ellos, hablante: nil, desde: 1, hasta: 2, texto: "chao"),
    ]
    var datos = try ArchivoDelGuion.codificar(palabras)
    datos.append(Data("{\"pista\":".utf8))
    #expect(ArchivoDelGuion.leer(datos) == palabras)
  }

  @Test func juntarYReasignarSeArreglanEnUnClic() {
    var r = reunion()
    r.hablantes += [Hablante(id: "h2", pista: .ellos), Hablante(id: "h5", pista: .ellos)]
    var palabras = [
      PalabraDelGuion(pista: .ellos, hablante: "h2", desde: 0, hasta: 1, texto: "a"),
      PalabraDelGuion(pista: .ellos, hablante: "h5", desde: 2, hasta: 3, texto: "b"),
    ]
    EdicionDelGuion.juntar("h5", en: "h2", palabras: &palabras, reunion: &r)
    #expect(palabras.allSatisfy { $0.hablante == "h2" })
    #expect(r.hablante("h5") == nil)
    let linea = LineasDelGuion.armar(palabras)[0]
    let nuevo = EdicionDelGuion.reasignar(linea, a: nil, palabras: &palabras, reunion: &r)
    #expect(nuevo == "h3")
    #expect(palabras.map(\.hablante) == ["h3", "h3"])
  }
}

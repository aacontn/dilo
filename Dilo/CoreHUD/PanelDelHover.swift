import Foundation
import SwiftUI

/// Algo reciente que el panel del hover deja volver a copiar: un dictado o
/// algo que se copió.
///
/// Pedido del 2026-09-24 (el 6 de la lista de lo que hacen otras apps):
/// «historial del portapapeles, tus últimos dictados y lo último copiado,
/// juntos». Vive sólo en memoria: se pierde al cerrar Dilo, y eso es a
/// propósito —un portapapeles que se guarda en disco guarda también la
/// contraseña que alguien copió un segundo—.
struct ElementoReciente: Identifiable, Equatable, Sendable {
  enum Origen: Equatable, Sendable {
    case dictado
    case copiado
  }

  let id = UUID()
  let texto: String
  let origen: Origen
  let cuando: Date

  /// Una línea, sin saltos: lo que cabe en una fila del panel.
  var vistazo: String {
    texto.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// La reunión que viene, leída del calendario (el 3 de la lista).
struct ProximaReunion: Equatable, Sendable {
  let titulo: String
  let empieza: Date
  let termina: Date
  /// El enlace de la videollamada, si el evento trae uno reconocible.
  let enlace: URL?
  /// Los otros asistentes por nombre (sin quien mira): lo que «Grabar» le
  /// pasa a la reunión para nombrar al otro en un 1:1.
  var asistentes: [String] = []
}

/// Cómo ofrece el panel la traducción.
enum TraduccionDelPanel: Equatable, Sendable {
  /// Lista: traduce al idioma de este código («EN»).
  case hacia(String)
  /// Todavía no hay idioma elegido: el botón lleva a Ajustes.
  case sinDestino
}

/// Un modo tal como el panel lo ofrece: su id y su nombre.
struct ModoDelPanel: Identifiable, Equatable, Sendable {
  let id: String
  let nombre: String
}

extension DictationHUDContent {
  /// Las secciones que el panel del hover dibujaría con lo que hay ahora.
  func seccionesDelPanel(conDatos: Bool) -> SeccionesDelPanel {
    SeccionesDelPanel(
      recientes: min(recientes.count, HUDNotchGeometry.recientesEnElPanel),
      datos: conDatos,
      reunion: proximaReunion != nil,
      // Con un solo modo ya hay elección: ése o «Normal». La fila también
      // lleva «Nota», así que con la nota rápida encendida va aunque no haya
      // modos.
      modos: !modosDelPanel.isEmpty || ofreceNota || traduccionDelPanel != nil
    )
  }

  /// Suma un reciente arriba de todo. Un texto que ya está no se repite ni
  /// sube: Dilo pega sus dictados pasando por el portapapeles, y sin esto
  /// cada dictado aparecería dos veces, una como dictado y otra como copiado.
  func agregarReciente(_ texto: String, origen: ElementoReciente.Origen, cuando: Date = Date()) {
    let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !limpio.isEmpty, !recientes.contains(where: { $0.texto == limpio }) else { return }
    recientes.insert(ElementoReciente(texto: limpio, origen: origen, cuando: cuando), at: 0)
    if recientes.count > Self.recientesGuardados { recientes.removeLast(recientes.count - Self.recientesGuardados) }
  }

  /// Cuántos se guardan en memoria: unos pocos más de los que se ven, para
  /// que un duplicado viejo siga reconociéndose como tal.
  static let recientesGuardados = 12
}

/// El panel que abre el hover: la próxima reunión, lo último dictado en
/// grande con los recientes anteriores debajo, el detalle de los datos y los
/// modos, en ese orden y cada uno sólo si tiene algo.
///
/// **Alto fijo por sección**, sumado en `HUDNotchGeometry.altoDelPanelDeHover`:
/// la forma se dimensiona antes de dibujar, así que ninguna sección puede
/// crecer con su contenido. Por eso la letra no escala con el tamaño de
/// Ajustes y cada fila es una línea recortada.
///
/// **El contenido va sobre oscuro**, con vidrio o sin él: el vidrio es
/// ahumado y lleva un velo negro encima (`PanelDeVidrio`). Las piezas —el último, cada
/// reciente, los chips y los botones— viven en `PiezasDelPanel.swift`, con
/// la jerarquía y la densidad de Droppy.
struct HUDPanelDelHover: View {
  let content: DictationHUDContent
  /// Lo que se dibuja si no hay ningún reciente: el modo o el nombre.
  let contexto: String
  let lados: [LadoDeLaMuesca]
  var ahora = Date()

  /// Si el botón de modo está desplegado. Arranca plegado cada vez que el
  /// panel se abre, porque la vista se monta de nuevo.
  @State private var modosAbiertos = false
  @Namespace private var pildora

  private var secciones: SeccionesDelPanel {
    content.seccionesDelPanel(conDatos: !lados.isEmpty)
  }

  /// En este orden, de lo más urgente a lo más a mano:
  ///
  /// 1. **La próxima reunión**, como tarjeta: es lo único del panel que tiene
  ///    hora, y cuando falta poco se tiñe del acento.
  /// 2. **Lo último**, en grande, y los recientes anteriores en una línea
  ///    cada uno —o, sin recientes, el modo o el nombre en grande—.
  /// 3. **El detalle de los datos**.
  /// 4. **La barra de acciones** al pie: los modos y «Nota».
  ///
  /// Cada sección lleva un alto exacto, el mismo que suma
  /// `HUDNotchGeometry.altoDelPanelDeHover`: si la vista y la geometría no
  /// coincidieran, la forma cortaría el contenido o sobraría negro abajo.
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if secciones.reunion, let reunion = content.proximaReunion {
        tarjetaDeLaReunion(reunion)
          .frame(height: HUDNotchGeometry.altoDeLaReunion, alignment: .top)
      }
      ultimo
      if secciones.recientes > 1 {
        ForEach(content.recientes.prefix(secciones.recientes).dropFirst()) { elemento in
          filaReciente(elemento)
        }
      }
      if secciones.datos {
        VStack(spacing: 0) {
          separador
          HUDDetalleDeLosDatos(lados: lados, ahora: ahora)
            .padding(.top, 2)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: HUDNotchGeometry.altoDelDetalleDeDatos, alignment: .top)
      }
      if secciones.modos {
        VStack(spacing: 0) {
          separador
          modos
        }
        .frame(height: HUDNotchGeometry.altoDeLosModos, alignment: .top)
      }
    }
    .padding(.horizontal, PanelDeVidrio.aireLateral)
    .padding(.bottom, HUDNotchGeometry.aireAlPieDelPanel)
  }

  /// Aire entre secciones, sin línea: con la letra grande y el negro de
  /// fondo, la jerarquía ya separa (antes, una línea al 8 % o una tarjeta).
  private var separador: some View {
    Color.clear.frame(height: HUDNotchGeometry.altoDelSeparador)
  }

  // MARK: Lo último y los recientes

  /// Lo último que se dictó o copió, en grande, con copiar a la derecha. Sin
  /// recientes, el modo o el nombre, y nada que copiar.
  @ViewBuilder
  private var ultimo: some View {
    if let elemento = content.recientes.first, secciones.recientes > 0 {
      let origen = elemento.origen == .dictado ? String(localized: "Dictado") : String(localized: "Copiado")
      HUDUltimoDelPanel(
        titulo: elemento.vistazo,
        subtitulo: "\(origen) · \(TextoDelPanel.hace(elemento.cuando, ahora: ahora))",
        esDictado: elemento.origen == .dictado,
        copiado: content.recienteCopiadoID == elemento.id
      )
      .contentShape(Rectangle())
      .onTapGesture { content.alCopiarReciente?(elemento) }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: elemento.vistazo))
      .accessibilityAddTraits(.isButton)
      .accessibilityHint(Text("Copiar"))
    } else {
      HUDUltimoDelPanel(
        titulo: contexto,
        subtitulo: String(localized: "Todavía no hay nada que copiar"),
        ofreceCopiar: false
      )
      .accessibilityElement(children: .combine)
    }
  }

  private func filaReciente(_ elemento: ElementoReciente) -> some View {
    HUDFilaRecienteDelPanel(
      texto: elemento.vistazo,
      esDictado: elemento.origen == .dictado,
      copiado: content.recienteCopiadoID == elemento.id
    )
    .contentShape(Rectangle())
    .onTapGesture { content.alCopiarReciente?(elemento) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: elemento.vistazo))
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(Text("Copiar"))
  }

  // MARK: La reunión

  /// La reunión como tarjeta: el título, cuándo, y «Unirse» si hay enlace.
  /// Mango cuando faltan diez minutos o menos, que es cuando importa.
  private func tarjetaDeLaReunion(_ reunion: ProximaReunion) -> some View {
    let pronto = Self.esPronto(reunion, ahora: ahora)
    return HStack(spacing: 7) {
      Image(systemName: "calendar")
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(pronto ? PaletaDeDilo.actual.acento.color : .white.opacity(0.55))
      Text(verbatim: reunion.titulo)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
      Text(verbatim: Self.cuando(reunion, ahora: ahora))
        .font(.system(size: 10.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Self.color(reunion, ahora: ahora))
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 6)
      botonesDeGrabar(reunion, pronto: pronto)
    }
    .padding(.leading, 9)
    .padding(.trailing, 4)
    .frame(height: 26)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(pronto ? PaletaDeDilo.actual.acento.color.opacity(0.14) : .white.opacity(0.06))
    )
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture { content.alAbrirReunion?() }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }

  /// «Grabar», y «Unirse y grabar» cuando el evento trae enlace (spec,
  /// «Empezar»). Grabando ya, una sola marca que abre la reunión. Sin
  /// enlace, un clic en la tarjeta sigue abriendo Calendario; con enlace,
  /// unirse sin grabar sigue siendo el clic en la tarjeta.
  @ViewBuilder
  private func botonesDeGrabar(_ reunion: ProximaReunion, pronto: Bool) -> some View {
    if content.reunionEnCurso != nil {
      HStack(spacing: 4) {
        Circle().fill(PaletaDeDilo.actual.grabando.color).frame(width: 6, height: 6)
        Text("Grabando").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
      }
      .padding(.horizontal, 8)
    } else {
      botonDeGrabar(Text("Grabar"), lleno: reunion.enlace == nil && pronto) {
        content.alGrabarReunion?(false)
      }
      if reunion.enlace != nil {
        botonDeGrabar(Text("Unirse y grabar"), lleno: true, color: pronto ? PaletaDeDilo.actual.acento.color : .white) {
          content.alGrabarReunion?(true)
        }
      }
    }
  }

  private func botonDeGrabar(
    _ titulo: Text, lleno: Bool, color: Color = .white, accion: @escaping () -> Void
  ) -> some View {
    Button(action: accion) {
      titulo
      .font(.system(size: 10.5, weight: .semibold))
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(lleno ? .black : .white.opacity(0.9))
      .padding(.horizontal, 8)
      .frame(height: 18)
      .background(Capsule(style: .continuous).fill(lleno ? color : .white.opacity(0.1)))
    }
    .buttonStyle(.plain)
    .layoutPriority(2)
  }

  static func esPronto(_ reunion: ProximaReunion, ahora: Date) -> Bool {
    reunion.empieza.timeIntervalSince(ahora) <= 10 * 60
  }

  /// «en 12 min», «ahora», «a las 16:30».
  static func cuando(_ reunion: ProximaReunion, ahora: Date) -> String {
    if reunion.empieza <= ahora { return String(localized: "ahora") }
    let minutos = Int(reunion.empieza.timeIntervalSince(ahora) / 60)
    if minutos < 60 { return String(localized: "en \(max(1, minutos)) min") }
    let hora = reunion.empieza.formatted(date: .omitted, time: .shortened)
    return String(localized: "a las \(hora)")
  }

  /// Mango cuando falta poco o ya empezó: es lo que dice «ahora sí».
  static func color(_ reunion: ProximaReunion, ahora: Date) -> Color {
    esPronto(reunion, ahora: ahora) ? PaletaDeDilo.actual.acento.color : .white.opacity(0.5)
  }

  // MARK: Los modos

  /// La fila de abajo: el botón de modo a la izquierda y «Traducir» y
  /// «Nota» a la derecha, como íconos. Plegado, el botón muestra sólo el
  /// modo elegido; desplegado, todos como pestañas —el elegido en la
  /// píldora gris— y los íconos se apartan para dejarles la fila.
  private var modos: some View {
    HStack(spacing: 4) {
      if !content.modosDelPanel.isEmpty {
        if modosAbiertos {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
              chip(nombre: String(localized: "Normal"), id: nil)
              ForEach(content.modosDelPanel) { modo in
                chip(nombre: modo.nombre, id: modo.id)
              }
            }
          }
          .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
        } else {
          botonDeModo
          Spacer(minLength: 0)
        }
      } else {
        Spacer(minLength: 0)
      }
      if !modosAbiertos {
        accionesDelPie
          .transition(.opacity)
      }
    }
    // El alto de la sección menos su separador, que va arriba.
    .frame(height: HUDNotchGeometry.altoDeLosModos - HUDNotchGeometry.altoDelSeparador)
  }

  /// El modo elegido, plegado. Un clic despliega los demás.
  private var botonDeModo: some View {
    let elegido = content.modosDelPanel.first { $0.id == content.modoDelPanelID }
    let nombre = elegido?.nombre ?? String(localized: "Normal")
    return HUDBotonDeModo(nombre: nombre, pildora: pildora)
      .onTapGesture {
        withAnimation(CurvaDeLaMuesca.apertura.animacion) { modosAbiertos = true }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("Modo: \(nombre)"))
      .accessibilityAddTraits(.isButton)
      .accessibilityHint(Text("Muestra los otros modos"))
      .help("Cambiar de modo")
  }

  /// «Traducir» y «Nota». Sin el corte fino que los separaba de las
  /// pestañas: con el modo en una sola píldora, el aire ya los separa.
  private var accionesDelPie: some View {
    HStack(spacing: 4) {
      if let traduccion = content.traduccionDelPanel {
        botonDeTraducir(traduccion)
      }
      if content.ofreceNota {
        botonDeNota
      }
    }
  }

  /// Dictar traduciendo, al idioma elegido en Ajustes. Sin idioma todavía,
  /// el botón va apagado y lleva a elegirlo: un «Traducir» que no hace nada
  /// se lee como roto.
  private func botonDeTraducir(_ traduccion: TraduccionDelPanel) -> some View {
    let listo: String? = if case let .hacia(destino) = traduccion { destino } else { nil }
    // «EN» y no «→ EN»: el globo ya dice traducir, y la flecha era la mitad
    // del ancho del botón.
    return HUDBotonDelPanel(
      icono: "globe",
      titulo: listo ?? String(localized: "Traducir"),
      apagado: listo == nil
    )
    .contentShape(Capsule())
    .onTapGesture {
      if listo == nil {
        content.alElegirIdiomaDeTraduccion?()
      } else {
        content.alDictarTraduciendo?()
      }
    }
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(Text(listo == nil ? "Elegir el idioma para traducir" : "Dictar traduciendo"))
    .help(listo == nil ? "Elige a qué idioma traducir" : "Dicta y se pega traducido")
  }

  /// Dictar una nota que termina en Apple Notas. Es un clic, no el hover:
  /// posarse encima nunca abre el micrófono (contrato del notch).
  private var botonDeNota: some View {
    HUDBotonDelPanel(icono: "square.and.pencil")
      .contentShape(Capsule())
      .onTapGesture { content.alDictarNota?() }
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(Text("Dictar una nota"))
      .help("Dicta una nota que termina en Notas")
  }

  /// Elegir un modo lo deja puesto y pliega la fila: la píldora viaja al
  /// elegido y de ahí vuelve al botón.
  private func chip(nombre: String, id: String?) -> some View {
    let elegido = content.modoDelPanelID == id
    return HUDChipDelPanel(nombre: nombre, elegido: elegido, pildora: pildora)
      .contentShape(Capsule())
      .onTapGesture {
        content.alElegirModo?(id)
        withAnimation(CurvaDeLaMuesca.cierre.animacion.delay(0.12)) { modosAbiertos = false }
      }
      .accessibilityAddTraits(elegido ? [.isButton, .isSelected] : .isButton)
  }
}

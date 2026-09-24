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
      modos: !modosDelPanel.isEmpty || ofreceNota
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

/// El panel que abre el hover: recientes, el detalle de los datos, la próxima
/// reunión y los modos, en ese orden y cada uno sólo si tiene algo.
///
/// **Alto fijo por sección**, sumado en `HUDNotchGeometry.altoDelPanelDeHover`:
/// la forma se dimensiona antes de dibujar, así que ninguna sección puede
/// crecer con su contenido. Por eso la letra no escala con el tamaño de
/// Ajustes y cada fila es una línea recortada.
struct HUDPanelDelHover: View {
  let content: DictationHUDContent
  /// Lo que se dibuja si no hay ningún reciente: el modo o el nombre.
  let contexto: String
  let lados: [LadoDeLaMuesca]
  var ahora = Date()

  private var secciones: SeccionesDelPanel {
    content.seccionesDelPanel(conDatos: !lados.isEmpty)
  }

  /// En este orden, de lo más urgente a lo más a mano:
  ///
  /// 1. **La próxima reunión**, como tarjeta: es lo único del panel que tiene
  ///    hora, y cuando falta poco se tiñe de mango.
  /// 2. **Recientes**, con su encabezado —o la línea de contexto si todavía no
  ///    hay nada—.
  /// 3. **El detalle de los datos**, detrás de un separador.
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
      if secciones.recientes > 0 {
        VStack(alignment: .leading, spacing: 0) {
          encabezado("Recientes")
          recientes
        }
      } else {
        Text(verbatim: contexto)
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.78))
          .lineLimit(1)
          .frame(maxWidth: .infinity)
          .frame(height: HUDNotchGeometry.altoDelContextoEnReposo)
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
    .padding(.horizontal, 16)
    .padding(.bottom, secciones.llevaAire ? HUDNotchGeometry.aireAlPieDelPanel : 0)
  }

  /// Una línea finita entre secciones, con su aire.
  private var separador: some View {
    Rectangle()
      .fill(.white.opacity(0.08))
      .frame(height: 1)
      .frame(height: HUDNotchGeometry.altoDelSeparador)
  }

  /// El nombre de una sección, en chico y apagado: ordena sin competir con lo
  /// que hay debajo.
  private func encabezado(_ titulo: LocalizedStringKey) -> some View {
    Text(titulo)
      .textCase(.uppercase)
      .font(.system(size: 8, weight: .semibold, design: .rounded))
      .tracking(0.6)
      .foregroundStyle(.white.opacity(0.42))
      .frame(height: HUDNotchGeometry.altoDelEncabezadoDeSeccion, alignment: .bottom)
  }

  // MARK: Recientes

  private var recientes: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(content.recientes.prefix(HUDNotchGeometry.recientesEnElPanel)) { elemento in
        filaReciente(elemento)
      }
    }
  }

  private func filaReciente(_ elemento: ElementoReciente) -> some View {
    HStack(spacing: 7) {
      Image(systemName: elemento.origen == .dictado ? "waveform" : "doc.on.clipboard")
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.4))
        .frame(width: 12)
      Text(verbatim: elemento.vistazo)
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 6)
      if content.recienteCopiadoID == elemento.id {
        Label("Copiado", systemImage: "checkmark")
          .labelStyle(.titleAndIcon)
          .font(.system(size: 9.5, weight: .semibold, design: .rounded))
          .foregroundStyle(DiloBrand.menta)
      } else {
        // Un ícono apagado y no la palabra en mango: con tres filas, tres
        // «Copiar» en color eran lo más fuerte del panel sin ser lo más
        // importante. El color queda para cuando pasó algo: «Copiado».
        Image(systemName: "doc.on.doc")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.white.opacity(0.38))
      }
    }
    .frame(height: HUDNotchGeometry.altoDeUnReciente)
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
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(pronto ? DiloBrand.mango : .white.opacity(0.55))
      Text(verbatim: reunion.titulo)
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
      Text(verbatim: Self.cuando(reunion, ahora: ahora))
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Self.color(reunion, ahora: ahora))
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 6)
      if reunion.enlace != nil {
        Text("Unirse")
          .font(.system(size: 9.5, weight: .bold, design: .rounded))
          .foregroundStyle(.black)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(Capsule(style: .continuous).fill(DiloBrand.mango))
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 26)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(pronto ? DiloBrand.mango.opacity(0.14) : .white.opacity(0.06))
    )
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture { content.alAbrirReunion?() }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
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
    esPronto(reunion, ahora: ahora) ? DiloBrand.mango : .white.opacity(0.5)
  }

  // MARK: Los modos

  /// La fila de abajo: los modos a la izquierda y «Nota» a la derecha.
  private var modos: some View {
    HStack(spacing: 8) {
      if !content.modosDelPanel.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            chip(nombre: String(localized: "Normal"), id: nil)
            ForEach(content.modosDelPanel) { modo in
              chip(nombre: modo.nombre, id: modo.id)
            }
          }
        }
      } else {
        Spacer(minLength: 0)
      }
      if content.ofreceNota {
        botonDeNota
      }
    }
    // El alto de la sección menos su separador, que va arriba.
    .frame(height: HUDNotchGeometry.altoDeLosModos - HUDNotchGeometry.altoDelSeparador)
  }

  /// Dictar una nota que termina en Apple Notas. Es un clic, no el hover:
  /// posarse encima nunca abre el micrófono (contrato del notch).
  private var botonDeNota: some View {
    HStack(spacing: 4) {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 9, weight: .bold))
      Text("Nota")
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
    }
    .foregroundStyle(DiloBrand.mango)
    .padding(.horizontal, 9)
    .padding(.vertical, 3)
    .background(Capsule(style: .continuous).fill(DiloBrand.mango.opacity(0.16)))
    .contentShape(Capsule())
      .onTapGesture { content.alDictarNota?() }
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(Text("Dictar una nota"))
  }

  private func chip(nombre: String, id: String?) -> some View {
    let elegido = content.modoDelPanelID == id
    return Text(verbatim: nombre)
      .font(.system(size: 9.5, weight: .semibold, design: .rounded))
      .lineLimit(1)
      .foregroundStyle(elegido ? .black : .white.opacity(0.75))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Capsule(style: .continuous).fill(elegido ? DiloBrand.mango : .white.opacity(0.12))
      )
      .contentShape(Capsule())
      .onTapGesture { content.alElegirModo?(id) }
      .accessibilityAddTraits(elegido ? [.isButton, .isSelected] : .isButton)
  }
}

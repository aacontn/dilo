import SwiftUI

/// Lo que el dictado pone adentro del notch, estado por estado
/// (`EstadoDelNotch`): la marca quieta en reposo, y la cabecera + la banda
/// del visual + el texto + el chip de modo cuando está abierto. La forma
/// misma, sus fillets y su crecimiento son de `HUDSurface`, que comparten
/// todas las superficies del HUD.
///
/// El escenario es permanente: esta vista **siempre** está montada, y lo que
/// cambia es qué dibuja y de qué tamaño.
struct DictationHUDShellView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let screen: HUDScreenSnapshot
  let settings: DictationSessionSettings
  let content: DictationHUDContent
  /// El estado de sesión que esta superficie dibuja. Hoy sólo existe uno con
  /// UI; reunión y conversación entran por acá cuando tengan la suya
  /// (`HUDSessionKind`).
  var kind: HUDSessionKind = .dictando

  /// Si esta pantalla no tiene carcasa que medir —píldora o notch simulado—.
  /// Lo decide la pantalla, no el picker de Ajustes: sin carcasa no hay
  /// cámara que esquivar, así que la cabecera de la forma se puede usar.
  private var sinCarcasa: Bool { HUDNotchGeometry.drawsPill(for: screen) }

  /// The shape's dimensions at the session's HUD size. Everything the user
  /// can resize is read from here; the housing band and fillets are not.
  ///
  /// Held to two floors at once: this display's, so the shape never ends up
  /// narrower than the housing it descends from, and the selected visual's, so
  /// a layout built around live text never shrinks past reading it.
  static func metrics(
    picked: HUDMetrics,
    screen: HUDScreenSnapshot,
    visual: HUDVoiceVisualStyle,
    reduceMotion: Bool
  ) -> HUDMetrics {
    HUDMetrics(
      scale: max(
        picked.scale,
        max(
          HUDNotchGeometry.minimumScale(for: screen),
          HUDMetrics.minimumScale(for: visual, reduceMotion: reduceMotion)
        )
      )
    )
  }

  private var metrics: HUDMetrics {
    let base = Self.metrics(
      picked: settings.hudMetrics,
      screen: screen,
      visual: settings.voiceVisual,
      reduceMotion: reduceMotion
    )
    // La píldora siempre lleva texto parcial, así que hereda el piso de los
    // visuales que se construyen alrededor del texto: más chica que eso, el
    // parcial deja de ser texto que alguien lee.
    guard sinCarcasa else { return base }
    return HUDMetrics(scale: max(base.scale, HUDMetrics.minimumReadableScale))
  }

  private var size: CGSize {
    HUDNotchGeometry.contentSize(
      for: screen,
      metrics: metrics,
      // Edge Glow + Draft has no visual band; its hanging stage is 40
      // points, 4 more than the ordinary text band. That extra has to be
      // in the declared size or Slide parks short of hiding the island.
      visualBandHeight: visualBandHeight
        + (showsRecentDraft
          ? metrics.glowDraftStageHeight - metrics.textBandHeight : 0),
      includesTextBand: showsTextBand,
      shapingBandHeight: showsShapingLabel ? metrics.shapingBandHeight : 0
    )
  }

  /// Whether the shape carries the shaping label's strip. Derived from the
  /// content rather than latched: the pick is set before the reveal and is not
  /// cleared until the shaping phase or the next session, so the strip never
  /// appears mid-flight and never leaves under a retracting shape.
  private var showsShapingLabel: Bool {
    chipDeModo != nil
  }

  /// El chip de modo: el nombre del modo, y nada más.
  ///
  /// Antes decía «Transformar: Correo» en gris, que es la etiqueta de un
  /// ajuste, no la de una sesión: nombra el mecanismo en vez de lo que está
  /// pasando. Ahora se lee el nombre del modo en mango —el acento de Dilo— y
  /// si no hay modo no hay chip. Mientras se transforma el mismo chip pasa a
  /// `trabajando`, para que la línea no salte ni cambie de texto justo cuando
  /// el dictado termina.
  private var chipDeModo: HUDChipDeModo.Contenido? {
    Self.chipDeModo(
      estado: content.estado,
      modo: content.shapingName ?? content.shapingChoiceLabel
    )
  }

  /// Qué chip le toca a este estado con este modo. Puro para poder afirmarlo
  /// sin dibujar: el chip nombra el modo, nunca el mecanismo.
  static func chipDeModo(estado: EstadoDelNotch, modo: String?) -> HUDChipDeModo.Contenido? {
    guard let modo, !modo.isEmpty else { return nil }
    switch estado {
    case .dictando: return HUDChipDeModo.Contenido(nombre: modo, trabajando: false)
    case .procesando: return HUDChipDeModo.Contenido(nombre: modo, trabajando: true)
    // En reposo no hay sesión que nombrar, y en preparando el modo todavía no
    // se aplicó a nada. El resultado dice qué pasó con las palabras, no con
    // qué se escribieron.
    case .reposo, .preparando, .resultado: return nil
    }
  }

  /// Reduce Motion always shows the quiet level meter in its slim band.
  /// Compact and Edge Glow + Draft have no band of their own: Compact's
  /// indicator lives in the text band, and Edge Glow + Draft's words overlay
  /// the island. Waveform and Edge Glow keep the tall band —
  /// the waveform fills it, the glow keeps it as an empty stage so the
  /// silhouette has flanks for the light to wrap.
  private var visualBandHeight: CGFloat {
    guard keepsVisualLayout else { return 0 }
    if reduceMotion { return metrics.visualBandHeight }
    // La píldora tiene una sola forma: corona, onda del micrófono y texto
    // parcial. El picker elige el *estilo* de la onda, no si la hay.
    if sinCarcasa { return metrics.waveBandHeight }
    switch settings.voiceVisual {
    case .compact, .glowDraft: return 0
    case .waveform, .glow: return metrics.waveBandHeight
    }
  }

  /// Waveform and Edge Glow replace the draft text entirely while
  /// listening; Compact and Edge Glow + Draft are built around it. With
  /// Reduce Motion the draft text always shows.
  private var showsTextBand: Bool {
    if !keepsVisualLayout || reduceMotion { return true }
    // El texto parcial mientras hablas es parte de la identidad de la
    // píldora, no una opción: es lo que la separa de cualquier HUD del
    // sistema, que nunca muestra lo que estás diciendo.
    if sinCarcasa { return true }
    return settings.voiceVisual.showsDraftWhileListening
  }

  /// Whether the bands stay as a listening session laid them out. Held through
  /// the retract so the shape never resizes while it is sliding away.
  private var keepsVisualLayout: Bool {
    content.showsVoiceVisual || content.isDismissing
  }

  /// Whether the text band is Compact's leading-aligned draft. Not gated on
  /// the listening state — swapping the band's structure at finalize reads
  /// as a glitch mid retract, so the layout stays and the indicator settles
  /// instead. Edge Glow + Draft has its own centered stage.
  private var showsLeadingDraft: Bool {
    !sinCarcasa && settings.voiceVisual == .compact && !reduceMotion
  }

  private var filletSize: CGFloat {
    HUDNotchGeometry.filletSize(for: screen)
  }

  private var housingShape: UnevenRoundedRectangle {
    let top = HUDNotchGeometry.topCornerRadius(for: screen, metrics: metrics)
    return UnevenRoundedRectangle(
      topLeadingRadius: top,
      bottomLeadingRadius: metrics.bottomCornerRadius,
      bottomTrailingRadius: metrics.bottomCornerRadius,
      topTrailingRadius: top,
      style: .continuous
    )
  }

  var body: some View {
    switch kind.surface {
    case .dictado:
      dictationSurface
    // Reunión y conversación están previstas y no se dibujan en v1 (spec §5).
    // Casos explícitos, no un `default:`: cuando lleguen sus specs, el
    // compilador va a traer a alguien hasta acá.
    case .ninguna:
      EmptyView()
    }
  }

  /// La silueta en reposo, ensanchada mientras el hover muestra contexto.
  ///
  /// El hover **nunca** arranca una captura (contrato del notch): lo único
  /// que hace es abrir un poco la forma para nombrar el modo activo o lo
  /// último que se dictó.
  private var tamañoEnReposo: CGSize {
    let base = HUDNotchGeometry.reposoSize(for: screen)
    guard content.contextoVisible != nil else { return base }
    // El mismo ancho que la forma abierta, y no uno medido del texto: el
    // panel del hover y el del dictado son el mismo objeto creciendo, y dos
    // anchos distintos lo delatan. El alto es lo que pide su contenido, con
    // un techo para que nunca se vuelva una ventana.
    return CGSize(
      width: size.width,
      height: min(
        base.height + HUDNotchGeometry.altoDelContextoEnReposo,
        HUDNotchGeometry.altoMaximoDelHover
      )
    )
  }

  private var dictationSurface: some View {
    HUDSurface(
      screen: screen,
      metrics: metrics,
      revealStyle: settings.revealStyle,
      isRevealed: content.isRevealed,
      size: size,
      rippleTrigger: content.sessionEpoch,
      rippleEnabled: settings.voiceVisual.usesEdgeGlow,
      tamañoEnReposo: tamañoEnReposo,
      content: { cuerpo },
      overlays: {
        particleCloud
        edgeGlow
      }
    )
    // Sólo la silueta toma el mouse, y sólo en los estados que hacen algo con
    // él (`EstadoDelNotch.tomaElMouse`); la ventana anfitriona es mucho más
    // ancha que la forma y el resto tiene que dejar pasar el clic.
    //
    // **Sin `onHover`.** Que el puntero esté encima lo decide el monitor del
    // puntero, no esta vista: la ventana ignora el mouse justo mientras el
    // puntero entra, así que el `mouseEntered` de esa entrada no llega nunca,
    // y el `mouseExited` que AppKit manda al rearmar el área de seguimiento
    // cuando la ventana crece cerraba el panel recién abierto
    // (`MonitorDelPuntero`, `HUDStage.punteroSeMovio`).
    .contentShape(Rectangle())
    .onTapGesture {
      guard content.estado.tomaElMouse else { return }
      content.alHacerClic?()
    }
    .allowsHitTesting(content.estado.tomaElMouse)
    // Una línea por cambio de estado con los dos tamaños al lado. Se anota acá
    // y no en `HUDStage` porque estos son los números que la vista acaba de
    // usar para dibujar: recalcularlos afuera sería un segundo lugar que
    // decide el tamaño de la forma, que es exactamente el error que se está
    // diagnosticando (`RegistroDeLaMuesca`).
    .onChange(of: content.estado, initial: true) {
      RegistroDeLaMuesca.anotar(
        estado: content.estado,
        ventana: HUDNotchGeometry.windowSize(for: screen, encuadre: encuadreDeLaVentana),
        forma: formaDibujada,
        pantalla: screen.nombre,
        notchReal: HUDNotchGeometry.hasMeasuredNotch(for: screen)
      )
    }
  }

  /// Qué ventana anfitriona pide este estado. Va al log porque la ventana
  /// dejó de ser una sola: en reposo se ajusta a la muesca y sólo crece
  /// cuando la forma se abre, así que `ventana=` tiene que decir cuál de las
  /// dos estaba puesta (`HUDNotchGeometry.EncuadreDeLaVentana`).
  private var encuadreDeLaVentana: HUDNotchGeometry.EncuadreDeLaVentana {
    content.estado.esCompacto && content.contextoVisible == nil ? .reposo : .abierta
  }

  /// El tamaño que la forma tiene ahora mismo: la silueta en reposo —abierta
  /// por el hover o no— o la forma del estado abierto. Es el mismo número que
  /// `HUDSurface` dibuja, no una estimación.
  private var formaDibujada: CGSize {
    content.estado.esCompacto ? tamañoEnReposo : size
  }

  /// Lo que la forma lleva adentro, según el estado del contrato.
  ///
  /// En reposo es una marca quieta: **nada de lo que anima está montado**, y
  /// esa es la diferencia entre un escenario permanente que cuesta lo que
  /// cuesta una ventana y uno que redibuja un shader sesenta veces por
  /// segundo para siempre (spec §3).
  @ViewBuilder
  private var cuerpo: some View {
    if content.estado.esCompacto {
      HUDMarcaDeReposo(
        dibujaMarca: sinCarcasa,
        contexto: content.contextoVisible,
        modo: modoEnReposo,
        scale: metrics.scale,
        // El alto de la silueta, medido: la marca lo llena y no lo estira.
        alto: tamañoEnReposo.height
      )
    } else {
      islaConEtiquetas
        // El `scard-pop` del overlay de Tauri: lo de adentro entra desde 0,92
        // y opacidad cero mientras la forma crece, y se va apagándose y
        // encogiéndose a 0,96. Va en el contenido y no en la forma porque la
        // forma es la muesca y la muesca no se apaga nunca; lo que aparece y
        // desaparece es lo que trae adentro.
        .scaleEffect(content.isRevealed ? 1 : 0.92, anchor: .top)
        .opacity(content.isRevealed ? 1 : 0)
        .animation(popDelContenido, value: content.isRevealed)
    }
  }

  /// La curva del pop: la de Tauri al abrir, su salida más corta al cerrar.
  private var popDelContenido: Animation {
    if reduceMotion { return .easeOut(duration: 0.12) }
    return content.isRevealed
      ? HUDRevealStyle.aperturaDeTauri
      : .easeOut(duration: 0.24)
  }

  /// El nombre del modo que la muesca dice en reposo, o nil —lo de fábrica—.
  /// El ancho de la silueta no crece por él: un nombre largo se recorta antes
  /// que ensanchar la muesca.
  private var modoEnReposo: String? {
    settings.muestraElModoEnReposo ? content.modoActivo : nil
  }

  private var islaConEtiquetas: some View {
    bands
      // The tag hangs off the shell, not the text band: Waveform and Edge
      // Glow hide the band for the whole listening phase, which is exactly
      // when the live language needs naming. Padded below the header so it
      // clears the camera, and an overlay so it never changes the fixed
      // window's size. Edge Glow + Draft places its own tag on the island.
      .overlay(alignment: .topLeading) {
        if !showsRecentDraft { languageTag }
      }
      // Grow Down springs the island's height. Glyphs opt out so new
      // words land immediately; the token is coarse so a wrap is one spring.
      .animation(
        longDraftStyle == .growDown && !showsRecentDraft
          ? .spring(duration: 0.18, bounce: 0) : nil,
        value: draftHeightToken
      )
      .animation(.spring(duration: 0.25, bounce: 0), value: visualBandHeight)
  }

  private var bands: some View {
    VStack(spacing: 0) {
      island
      if let chip = chipDeModo {
        HUDChipDeModo(
          contenido: chip,
          scale: metrics.scale,
          nivel: content.audioLevel,
          reduceMotion: reduceMotion
        )
        .frame(height: metrics.shapingBandHeight)
      }
    }
  }

  /// Housing plus the bands below it. Edge Glow + Draft's recent-word line
  /// is an overlay on this silhouette, not a ZStack sibling: a
  /// max-height-infinity child in a ZStack expands to the host window and
  /// the black shape follows it. Overlay stays the stacked size, and the
  /// words center in the box the glow wraps — including the housing
  /// flanks, which are visible even though the camera sits in the middle.
  private var island: some View {
    stackedBands
      .overlay {
        if showsRecentDraft {
          HUDRecentDraftText(
            committed: content.text,
            volatile: content.volatileText,
            scale: metrics.scale
          )
          .padding(.horizontal, tagInset * metrics.scale)
        }
      }
      .overlay(alignment: .leading) {
        if showsRecentDraft { languageTag }
      }
  }

  private var stackedBands: some View {
    VStack(spacing: 0) {
      // Strip level with the housing: kept empty so text never collides
      // with the camera. Edge Glow + Draft still counts it in the box the
      // words are centered in, because the flanks of that strip are visible.
      // Sin carcasa la cabecera es la silueta en reposo, de la que la forma
      // abierta crece hacia abajo. Va vacía en los dos casos: la corona mango
      // que la píldora llevaba encima se leía como un segundo objeto pegado
      // arriba, no como el notch creciendo.
      Color.clear
        .frame(height: HUDNotchGeometry.alturaDeCabecera(for: screen))
      if visualBandHeight > 0 {
        Group {
          if reduceMotion {
            HUDLevelMeterView(content: content)
          } else if settings.voiceVisual == .waveform {
            HUDWaveformView(settings: settings, content: content)
          } else {
            // Edge Glow: the centers (particles, orb) are
            // shape-wide overlays, so the band is an empty stage.
            Color.clear
          }
        }
        .frame(height: visualBandHeight)
      }
      if showsTextBand {
        textBand
      }
    }
  }

  /// Draft text lives in the band below the housing. Compact puts its
  /// voice indicator on the leading side, Dynamic Island-style, with the
  /// draft leading-aligned beside it. Edge Glow + Draft only reserves the
  /// hanging stage here; the words themselves overlay the whole island.
  /// The other visuals center the draft.
  @ViewBuilder
  private var textBand: some View {
    if showsRecentDraft {
      Color.clear
        .frame(height: metrics.glowDraftStageHeight)
    } else {
      Group {
        if let resultado = resultadoVisible {
          lineaDeResultado(resultado)
        } else if showsLeadingDraft {
          HStack(alignment: .top, spacing: 10 * metrics.scale) {
            HUDCompactIndicatorView(content: content, scale: metrics.scale)
              .padding(.top, 3 * metrics.scale)
            compactDraftText
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          conCursor { draftText }
        }
      }
      // La tipografía del transcript de Tauri: quince puntos en cursiva. La
      // cursiva no es adorno — separa lo que alguien **acaba de decir** de lo
      // que la forma dice por su cuenta («Listo», «Procesando…»), que sale
      // recto. Blanco al 90 %, como `--color-text` sobre el vidrio.
      .font(.system(size: 15 * metrics.scale, weight: .regular).italic())
      .foregroundStyle(.white.opacity(0.9))
      // The tag sits in the inset rather than in the flow, and the inset grows
      // on both sides, so centered drafts stay centered and nothing overlaps.
      .padding(.horizontal, tagInset * metrics.scale)
      .padding(.top, 4 * metrics.scale)
      .padding(.bottom, 4 * metrics.scale)
      // En la muesca el parcial es **siempre** una línea (`longDraftStyle` cae
      // a `.tailOnly` más abajo), así que la banda mide exactamente lo que la
      // geometría declara: con techo, los 400×88 dejan de depender de cuánto
      // ocupe una cursiva de quince puntos en la versión de macOS de turno.
      // Contra una carcasa real sigue siendo sólo un mínimo, porque ahí la
      // banda sí tiene de dónde crecer (`HUDLongDraftStyle.growDown`).
      .frame(
        minHeight: metrics.textBandHeight,
        maxHeight: sinCarcasa ? metrics.textBandHeight : nil
      )
    }
  }

  /// El resultado que la forma está mostrando, o nil mientras hay sesión.
  private var resultadoVisible: ResultadoDelNotch? {
    guard case let .resultado(resultado) = content.estado else { return nil }
    return resultado
  }

  /// El resultado: qué pasó, y —cuando hay algo que copiar— que un clic lo
  /// copia. Una sola línea recta, en la misma banda: el resultado dura dos
  /// segundos y medio y no vale una franja más de alto.
  private func lineaDeResultado(_ resultado: ResultadoDelNotch) -> some View {
    HStack(spacing: 8 * metrics.scale) {
      Text(content.text.isEmpty ? resultado.texto : content.text)
        .font(.system(size: 13 * metrics.scale, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.tail)
      if resultado.ofreceCopiar {
        Text("Copiar")
          .font(.system(size: 11 * metrics.scale, weight: .semibold, design: .rounded))
          .foregroundStyle(DiloBrand.mango)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// El texto parcial con el cursor mango pegado al final, mientras el
  /// micrófono está abierto. Fuera de ese estado no hay cursor: nada está
  /// creciendo.
  @ViewBuilder
  private func conCursor(@ViewBuilder _ texto: () -> some View) -> some View {
    if content.estado == .dictando {
      HStack(alignment: .firstTextBaseline, spacing: 1 * metrics.scale) {
        texto()
          .layoutPriority(1)
        HUDCursorDeDictado(scale: metrics.scale, reduceMotion: reduceMotion)
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 * metrics.scale }
      }
      .frame(maxWidth: .infinity)
    } else {
      texto()
    }
  }

  /// Qué hace la forma con un dictado largo en **esta** pantalla.
  ///
  /// En la muesca, siempre una línea recortada por la izquierda: lo último
  /// que dijiste es lo que estás revisando, y una forma que crece con el
  /// texto vuelve a ser el panel que la muesca dejó de ser. El ajuste
  /// «Si el texto se pasa de largo» sigue mandando contra una carcasa real,
  /// donde la banda tiene de dónde crecer sin taparle la pantalla a nadie.
  private var longDraftStyle: HUDLongDraftStyle {
    sinCarcasa ? .tailOnly : settings.longDraftStyle
  }

  private var showsRecentDraft: Bool {
    guard !sinCarcasa else { return false }
    return Self.showsRecentDraft(
      visual: settings.voiceVisual,
      listening: content.showsVoiceVisual,
      dismissing: content.isDismissing,
      shaping: content.shapingName != nil,
      reduceMotion: reduceMotion
    )
  }

  /// Edge Glow + Draft's recent-word line: listening, retracting, and
  /// shaping keep it; a status message does not.
  static func showsRecentDraft(
    visual: HUDVoiceVisualStyle,
    listening: Bool,
    dismissing: Bool,
    shaping: Bool,
    reduceMotion: Bool
  ) -> Bool {
    visual == .glowDraft && !reduceMotion && (listening || dismissing || shaping)
  }

  /// The room the language tag needs on each side.
  ///
  /// Symmetric, so a centered draft stays centered. It replaced a
  /// per-character estimate that overshot a language pair by 40%.
  private var tagInset: CGFloat {
    max(24, tagReserve(content.languageTag))
  }

  private func tagReserve(_ tag: String?) -> CGFloat {
    guard let tag, !tag.isEmpty else { return 0 }
    // The capsule's own padding, its inset from the shape's edge, and air
    // before the draft may start.
    return tagTextWidth(tag) + 4 * 2 + 12 + 8
  }

  /// A tag's text width, measured rather than estimated: a prompt name is
  /// typed by the user, so no per-character guess covers both "EN → ES" and
  /// whatever somebody calls their prompt. Unscaled, like every other number
  /// here; the caller applies the scale.
  private func tagTextWidth(_ tag: String) -> CGFloat {
    let width = (tag as NSString)
      .size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold)])
      .width
      // The tracking the label draws with, which the measurement does not
      // know about.
      + 0.5 * CGFloat(tag.count)
    // Capped: past this a name truncates rather than pushing the draft off
    // the shape entirely.
    return min(width.rounded(.up), Self.maximumTagTextWidth)
  }

  private static let maximumTagTextWidth: CGFloat = 150

  @ViewBuilder
  private var languageTag: some View {
    if let tag = content.languageTag {
      tagCapsule(tag)
        .padding(.leading, 12 * metrics.scale)
        // Edge Glow + Draft overlays the tag on the whole island, so it
        // shares the draft's vertical center. Other visuals pin it below
        // the housing from the shell.
        .padding(.top, showsRecentDraft ? 0 : tagTopInset)
        .allowsHitTesting(false)
    }
  }

  private func tagCapsule(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 9 * metrics.scale, weight: .semibold, design: .rounded))
      .tracking(0.5)
      .foregroundStyle(.white.opacity(0.72))
      .lineLimit(1)
      // A long prompt name shrinks rather than truncating: a pick whose name
      // is cut off is a pick the arrows chose blind.
      .truncationMode(.tail)
      .frame(width: tagTextWidth(text) * metrics.scale)
      .padding(.horizontal, 4 * metrics.scale)
      .padding(.vertical, 1.5 * metrics.scale)
      .background(Capsule(style: .continuous).fill(.white.opacity(0.13)))
  }

  private var tagTopInset: CGFloat {
    let housing = HUDNotchGeometry.alturaDeCabecera(for: screen)
    let belowHousing: CGFloat
    if showsTextBand, visualBandHeight > 0 {
      belowHousing = visualBandHeight + 5 * metrics.scale
    } else {
      belowHousing = 5 * metrics.scale
    }
    return housing + belowHousing
  }

  /// Coarse height for Grow Down's spring: one step per ~40 characters, so
  /// wrapping animates the island without tweening every volatile letter.
  private var draftHeightToken: Int {
    (content.text.count + content.volatileText.count) / 40
  }

  /// Committed draft in full white, the current guess lighter, so new words
  /// show as soon as the recognizer emits them. Glyphs opt out of Grow Down's
  /// height spring so they do not fade in with it.
  private var liveDraft: some View {
    let committed = AttributedString(content.text)
    var guess = AttributedString(content.volatileText)
    guess.font = .system(size: 15 * metrics.scale, weight: .regular).italic()
    guess.foregroundColor = Color.white.opacity(0.55)
    return Text(committed + guess)
      .transaction { $0.animation = nil }
  }

  /// The Compact draft: the same long-draft semantics, leading-aligned so
  /// the text hangs off the indicator instead of floating centered.
  @ViewBuilder
  private var compactDraftText: some View {
    switch longDraftStyle {
    case .tailOnly:
      liveDraft
        .lineLimit(1)
        .truncationMode(.head)
    case .growDown:
      liveDraft
        .lineLimit(4)
        .multilineTextAlignment(.leading)
    case .shrinkToFit:
      liveDraft
        .lineLimit(1)
        .truncationMode(.head)
        .minimumScaleFactor(0.55)
    }
  }

  /// The single-line variants truncate the head — the newest words are what
  /// the speaker checks. Grow Down cannot: head truncation forces
  /// single-line rendering, so it wraps and truncates the tail only when
  /// the line cap is hit.
  @ViewBuilder
  private var draftText: some View {
    switch longDraftStyle {
    case .tailOnly:
      liveDraft
        .lineLimit(1)
        .truncationMode(.head)
    case .growDown:
      liveDraft
        .lineLimit(4)
        .multilineTextAlignment(.center)
    case .shrinkToFit:
      liveDraft
        .lineLimit(1)
        .truncationMode(.head)
        .minimumScaleFactor(0.55)
    }
  }

  /// The Edge Glow particle cloud, clipped to the housing so no mote leaks
  /// past the silhouette. Mounted with the glow (not only while listening)
  /// so its drain-out ramp can render too.
  /// Si en este estado hay alguna vista con un `TimelineView` adentro
  /// montada: la nube de partículas, el resplandor del borde, la onda o el
  /// indicador compacto.
  ///
  /// **Es el número del reposo.** Un `TimelineView` montado redibuja aunque
  /// esté pausado en cuanto algo lo despierta, y el spec §3 pide ~0 % de CPU
  /// mientras nadie dicta. Función pura para poder afirmarlo por estado sin
  /// abrir una ventana ni mirar un medidor.
  static func montaVisualesDeVoz(
    estado: EstadoDelNotch,
    visual: HUDVoiceVisualStyle,
    reduceMotion: Bool
  ) -> Bool {
    guard estado.anima else { return false }
    guard !reduceMotion else { return false }
    switch visual {
    case .glow, .glowDraft, .waveform, .compact: return true
    }
  }

  private var montaVisualesDeVoz: Bool {
    Self.montaVisualesDeVoz(
      estado: content.estado,
      visual: settings.voiceVisual,
      reduceMotion: reduceMotion
    )
  }

  @ViewBuilder
  private var particleCloud: some View {
    if montaVisualesDeVoz, settings.voiceVisual == .glow, settings.glowCenter == .particles {
      HUDParticleCloudView(
        content: content,
        settings: settings,
        cornerRadius: metrics.bottomCornerRadius,
        topFilletRadius: filletSize
      )
        .clipShape(housingShape)
    }
  }

  /// The Edge Glow's orb center: centered on the whole notch island rather
  /// than tucked in the band, sized just short of the island's height.
  /// The edge-glow voice visual: an origin glow blooming from the notch
  /// housing along the open silhouette, breathing with the voice
  /// (HUDEdgeGlowView). Mounted whenever the variant is selected — not only
  /// while listening — so the drain-out ramp can render after the session
  /// ends; the view disables its shader once the ramp reaches zero.
  @ViewBuilder
  private var edgeGlow: some View {
    if montaVisualesDeVoz, settings.voiceVisual.usesEdgeGlow {
      HUDEdgeGlowView(
        content: content,
        settings: settings,
        metrics: metrics,
        topFilletRadius: filletSize
      )
    }
  }

  /// Sits alongside the body rather than inside it. Absent on a display with
  /// no notch: the flare exists to meet a housing (ADR-0001).
}

// Live previews in-file so edits to the shell re-render in place; the
// harness (HUDPreviews.swift) drives synthesized speech-like levels.

#Preview("Edge Glow") {
  HUDShellPreviewHarness(visual: .glow)
}

#Preview("Waveform") {
  HUDShellPreviewHarness(visual: .waveform)
}

#Preview("Draft · grow down") {
  HUDShellPreviewHarness(
    text: "A long draft that outgrows a single line wraps and grows the "
      + "shape downward, capped at four lines, so the newest words stay visible"
  )
}

#Preview("Message · simulated notch") {
  HUDShellPreviewHarness(screen: HUDPreviewScreen.external, text: "Secure field")
}

#Preview("Shaping band · glow") {
  HUDShellPreviewHarness(visual: .glow, shapingChoice: "Remove filler words")
}

#Preview("Shaping band · compact") {
  HUDShellPreviewHarness(visual: .compact, shapingChoice: "Remove filler words")
}

#Preview("Edge Glow + Draft") {
  HUDShellPreviewHarness(visual: .glowDraft)
}

#Preview("Edge Glow + Draft · dead mic") {
  HUDShellPreviewHarness(visual: .glowDraft, micAlive: false)
}


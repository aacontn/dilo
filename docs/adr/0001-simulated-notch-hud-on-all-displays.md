# Simulated notch HUD on all displays

The Direct Dictation HUD always descends from the top center of its display. Displays without a physical notch get a simulated notch — the same surface with a stand-in footprint (Tilebar uses 185×32) and without the corner fillets that hug a real housing. We rejected the conventional bottom-center floating pill because two surfaces meant two behaviors to design and test, and the top-anchored notch surface is the product's visual identity: external-monitor users would otherwise never see it.

## Consequences

- One surface, one behavior. Only the notch measurement differs per display.
- The proven implementation pattern comes from Tilebar's `NotchIsland` module, which is not public: fixed-size host window whose origin moves but never resizes, measured-vs-simulated notch split in `NotchGeometry`, fillets only against a real housing, interactive-rects hit testing. Dilo's own version of it is `CoreHUD/`, and `HUDNotchGeometry` is where the measured-vs-simulated split now lives.
- No private APIs: the surface needs only `NSWindow.Level.mainMenu + 3`. A CGS/SkyLight call would rule out App Store distribution.

## Enmienda 2026-09-21 — la muesca simulada se mide y sí lleva fillets

Dos de las decisiones de arriba se revierten, y el resto de la ADR sigue en
pie. Alfonso probó el notch simulado en su Mac mini con dos 1080p sin carcasa:
«deja tu cuadrado terrible feo; la idea es que sea una pequeña muesca, algo
chiquitito».

- **El footprint prestado (185×32) se cambia por uno medido.** El alto pasa a
  ser el de la barra de menús de esa pantalla y el ancho, el de una muesca
  (`HUDNotchGeometry.muescaSimulada`). 185×32 es el notch de un MacBook de 14",
  y en un monitor sin carcasa ese tamaño no lo justifica nada: se lee como un
  bloque negro apoyado encima de la barra.
- **Los fillets dejan de ser exclusivos de una carcasa real.** El argumento de
  entonces —«sin bisel la curva se lee como dos pestañas sueltas»— valía para
  una forma que aparecía al dictar y se iba. Desde que el notch es el escenario
  permanente y vive pegado al borde, son justamente esas dos curvas cóncavas
  las que lo funden con la barra; sin ellas queda el rectángulo. El radio es
  algo menor que contra hardware, porque el bisel que imitan es dibujado.

Lo que no cambia: una sola superficie, la ventana anfitriona de tamaño fijo, el
split medido-vs-simulado y nada de APIs privadas.

## Enmienda 2026-09-22 — la ventana anfitriona mide lo que mide el estado

Se revierte «fixed-size host window whose origin moves but never resizes». La
ventana sigue siendo una sola y sigue calculándose desde la pantalla y no desde
el contenido, pero ahora tiene **dos tamaños**
(`HUDNotchGeometry.EncuadreDeLaVentana`).

Alfonso lo reportó el 2026-09-22: «la zona inmediatamente debajo del notch
queda inutilizada». En reposo la muesca mide 160×24 y la ventana que la
hospedaba medía 488×190 pegada al borde de arriba. macOS le entrega a una
ventana **todos** los clics de su rectángulo aunque no dibuje nada ahí, y el
`hitTest` que devuelve nil (`HUDHostingView`) no hace que el clic siga de largo
a la ventana de abajo: lo pierde. Eran ~190 puntos muertos en el centro de la
barra de menús y debajo, todo el tiempo, en una app que el 99 % del rato es una
muesca de 24 puntos de alto.

El tamaño fijo tenía su razón y ya no alcanza: la revelación con resorte se
pasa del tamaño final y la sombra necesita su holgura, así que una ventana
ajustada al reposo recortaba la animación. La salida es que las dos
direcciones no sean simétricas.

- **En reposo la ventana es la silueta más la holgura que de verdad se
  dibuja**: la sombra (`HUDMetrics.shadowRadius + shadowOffsetY`, 15 puntos) y,
  a los lados, las alas cóncavas si son más anchas. En un 1080p sin carcasa,
  190×39 en vez de 488×190.
- **Abierta, la ventana es el estado más alto más la holgura de la revelación**:
  la sombra más lo que el rebote se pasa del tamaño final. El sobrepaso no se
  estima a ojo, se calcula del `bounce` de cada estilo —`exp(−πζ/√(1−ζ²))`, con
  `bounce = 1 − ζ`— y se toma el peor, que es el del resorte del arrastre
  (0,39 de rebote, un 8,9 %). Hoy los 44 puntos históricos de `shadowPadding`
  ganan por ser mayores; el número queda derivado para que subir un rebote
  agrande la ventana en vez de recortar la animación en silencio.
- **Crece antes y se encoge después.** El escenario agranda la ventana antes de
  que la animación arranque y la achica cuando ya terminó
  (`HUDStage.ajustarVentana`, `dismissDuration`). Así ni la revelación sale
  recortada ni el reposo arrastra la ventana grande.
- **Y en reposo la ventana ignora el mouse fuera de la silueta.**
  `MonitorDelPuntero` —un monitor global de `.mouseMoved`, lo mismo que hacen
  Boring Notch y Notch Buddy— conmuta `NSWindow.ignoresMouseEvents`: `false`
  sólo con el puntero sobre la silueta. El cambio es inmediato y no espera el
  retardo del hover, porque con el retardo el primer clic sobre la muesca se
  perdería; lo que sigue esperando ese retardo es la revelación del contexto.
  Mientras la ventana toma el mouse, sus eventos dejan de llegarle al monitor
  global, así que un sondeo corto —y sólo entonces— es lo que nota que el
  puntero se fue.

Lo que no cambia: una sola superficie, el origen y el tamaño calculados desde
la pantalla y nunca desde el contenido, el split medido-vs-simulado, el panel
que no activa la app y nada de APIs privadas.

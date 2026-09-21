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

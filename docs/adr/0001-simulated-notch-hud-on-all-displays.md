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

- **En reposo la ventana es la silueta, y nada más**: ni un punto debajo de
  ella, y a los lados sólo lo que las dos alas cóncavas cuelgan fuera. En un
  1080p sin carcasa, 178×24 en vez de 488×190. La holgura de la sombra no
  entra, porque **en reposo no hay sombra**: la muesca quieta es hardware y el
  recorte de un MacBook no tiñe lo que tiene debajo. Pintarla igual costaba las
  dos cosas juntas —un halo cruzando la barra de menús y una ventana de 190×45
  medida con `CGWindowListCopyWindowInfo`— y las dos se veían (2026-09-22).
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

## Enmienda 2026-09-22 (tarde) — la ventana no ignora el mouse nunca

Se revierte la última frase de la enmienda de esta misma mañana: «en reposo la
ventana ignora el mouse fuera de la silueta». `MonitorDelPuntero` se retira.

Era el tercer intento de hacer andar el hover y los tres fallaron por la misma
raíz, que la enmienda anterior tenía al revés: **una ventana con
`ignoresMouseEvents = true` no recibe nada, `mouseEntered` incluido**. Por eso
hacía falta un monitor global de `.mouseMoved` para suplirlo, y un monitor
global no ve los eventos que caen sobre nuestra propia ventana — justo los que
importan. El encendido llegaba por un sondeo de 80 ms, o sea tarde, o no
llegaba. Alfonso lo reportó tres veces: «el hover sigue muerto».

- **`ignoresMouseEvents` se queda en `false`, siempre.** Quién se queda con un
  clic lo decide `HUDHostingView.hitTest`, que devuelve nil fuera de
  `zonaInteractiva`: dentro de la jerarquía AppKit sigue buscando hacia atrás,
  y sobre un panel transparente un punto que ninguna vista reclama deja el
  clic en la app de abajo. Es lo que hacen NotchDrop y boring.notch.
  `VentanaDeLaMuescaTests` lo afirma con una vista de prueba detrás.
- **La entrada del puntero la avisa un `NSTrackingArea`** sobre la vista de
  hospedaje (`.activeAlways`, `.mouseEnteredAndExited`, `.mouseMoved`,
  `.inVisibleRect`), más `acceptsMouseMovedEvents` en el panel. `.activeAlways`
  es lo que hace que llegue sin que Dilo esté activa ni la ventana sea key, y
  `.inVisibleRect` lo que evita rearmar el rect cada vez que el hover cambia
  el tamaño de la forma — el paso que se olvida.
- **La zona muerta sigue arreglada por su propio motivo.** Que la ventana en
  reposo mida lo que mide la muesca (`EncuadreDeLaVentana`) no dependía de
  esto y no se toca. Son dos arreglos, no uno con dos mitades.
- **Nada de NotchDrop está copiado.** Se adoptó el patrón, no el código, así
  que el `LICENSE` no cambia. El día que se adapte código suyo (MIT), la
  atribución entra antes que el código.

## Enmienda 2026-09-22 (tarde) — la muesca dictando apenas crece

`contentSize` deja de ser la forma abierta de toda pantalla. Sin carcasa, la
muesca dictando mide `tamañoDictando`: el alto de la barra de menús más un
décimo y un 15 % más de ancho que el reposo — 184×26 donde la barra mide 24.

Alfonso probó los 400×88 aprobados la noche anterior: «crece mucho cuando le
estoy dictando; podría crecer por un 10 % del notch real y avanzar en el texto
como lo está haciendo actualmente, que sería lo ideal». En chico seguía siendo
el panel que la muesca había dejado de ser dos veces.

- **Contra una carcasa real no aplica**, y por física: los primeros
  `safeAreaTop` puntos son el recorte, y una línea de texto ahí es una línea
  que nadie puede leer. Esa pantalla sigue apilando bandas bajo la carcasa.
- **La ventana abierta la dimensiona el panel del hover**, que ahora es la
  forma más alta que esta pantalla dibuja: 488×90 en vez de 488×190.
- **El panel del hover puede ser más grande que la muesca de dictado.** No es
  una inconsistencia: dictando la forma aparece sola encima de la barra
  mientras alguien escribe en otra app, y en el hover el mouse está encima a
  propósito. Ahí van a vivir las acciones que no son el dictado.

## Enmienda 2026-09-23 — sin zona, la ventana sí ignora el mouse

«La ventana no ignora el mouse nunca» dejaba la ventana abierta —488×90 sobre
el centro de la barra de menús— quedándose con los clics mientras se dicta, que
es justo cuando la forma no reclama nada. Si el `hitTest` nil pierde el clic o
lo deja pasar está medido en las dos direcciones en este mismo ADR, así que no
se apuesta a ninguna: **sin `zonaInteractiva` la ventana pone
`ignoresMouseEvents = true`**, y con zona vuelve a `false`, que es lo que el
área de seguimiento del hover necesita. Al volver a tomar el mouse, el
escenario pregunta una vez dónde está el puntero (`HUDStage.posicionDelPuntero`):
terminar de dictar con el mouse parado sobre la muesca no manda ningún
`mouseEntered`.

Y dos cosas del hover que lo hacían parecer roto: la red de seguridad de
cuatro segundos lo cerraba con el puntero todavía encima —ahora sólo cierra si
el puntero de verdad se fue—, y un `mouseExited` con el punto todavía dentro de
la vista, que AppKit puede mandar al rearmar el área cuando la ventana crece,
ya no cuenta como salida.


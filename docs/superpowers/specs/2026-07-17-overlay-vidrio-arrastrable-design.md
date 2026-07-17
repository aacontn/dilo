# Dilo — Overlay de vidrio arrastrable (rediseño visual + posición libre)

**Fecha:** 2026-07-17 · **Estado:** aprobado por Alfonso · **Base:** overlay actual (`src/overlay/`, `src-tauri/src/overlay.rs`)

## Qué es

Rediseño del overlay de grabación en dos frentes:

1. **Visual:** la pastilla deja el look plano con punto rojo pulsante y acento pálido, y pasa a **vidrio esmerilado con ondas de brasa** (elegido por Alfonso sobre maquetas en vivo: base "Vidrio" + colores de "Brasa", glow solo en las ondas).
2. **Funcional:** la pastilla se puede **arrastrar a cualquier parte de la pantalla** y recuerda dónde la dejaste, con memoria independiente por pantalla.

## Decisiones ya tomadas (con el usuario)

1. **Estilo:** vidrio + ondas gradiente mango→rojo con glow tenue **solo en las barras** (ni glow de pastilla ni borde naranjo — "la C es demasiado power"). Sin punto rojo: la onda viva ya comunica "grabando".
2. **Preset vs. arrastre:** el selector Arriba/Abajo de Configuración **se mantiene tal cual**. Arrastrar sobreescribe la posición en silencio (sin estado "Personalizada" visible en settings).
3. **Reset:** ítem **"Restablecer posición del overlay"** en el menú del tray; borra las posiciones guardadas de todas las pantallas. Elegir Arriba o Abajo de nuevo en Configuración también las borra.
4. **Multi-monitor:** **memoria por pantalla** — cada monitor recuerda su propia posición arrastrada. El overlay sigue apareciendo en el monitor donde está el cursor.

## Visual

### Pastilla (todos los estados)

- **Superficie:** translúcida, tinte derivado de `--color-background` para que se adapte a tema claro/oscuro, borde de pelo luminoso (`--color-text` a baja opacidad + inset highlight superior), sombra suave amplia. Reemplaza el `--s-surface` casi opaco actual.
  - **Desviación acordada en el plan (implementada):** el vidrio es **simulado, sin `backdrop-filter`** — WebKit no puede muestrear el escritorio detrás de una ventana transparente de Tauri, y blur real (vibrancy nativa) exigiría ventanas de tamaño fijo que rompen los morfos animados. El tinte sube para compensar: pastilla ~72%, panel Live ~86% (a ~14% sin blur era ilegible).
- **Ondas:** las barras reactivas al mic pasan de color sólido a **gradiente vertical mango→rojo** (`--dilo-mango` #ff9e1b → `--dilo-rojo` #ff5c5c) con **glow tenue por barra** (`box-shadow` ~7px a ~50% de alfa de un naranjo intermedio). La pastilla en sí NO tiene glow ni animación de respiración.
- **Se elimina:** el punto rojo pulsante (`.sdot` y su animación). La zona izquierda de la fila base queda para equilibrio de la grilla (el layout de 3 zonas se conserva).
- **Timer y cancelar (✕):** mismos elementos y posiciones de hoy, colores ajustados para leerse sobre vidrio (texto sigue `--color-text` con opacidades, no grises fijos).
- **Estados working (transcribiendo / puliendo):** mismo vidrio; spinner en mango como hoy; etiqueta con el color de texto del tema.
- **Panel Live (streaming):** misma tarjeta de vidrio, con el tinte de superficie más opaco que la pastilla (punto de partida ~35% vs ~14%; se afina al verificar legibilidad del transcript en vivo sobre fondos ruidosos). Caret mango se mantiene. Las transiciones/morfos actuales (pill→panel, pop-in, fade) no cambian.
- **Tema claro/oscuro:** una sola implementación con tokens del tema (tinte y texto flipean solos, como ya hace el CSS del overlay con `--color-background`/`--color-text`). Los grises fijos `--s-muted`/`--s-faint` se re-derivan de tokens para no quedar ilegibles sobre vidrio.

## Arrastre

- **Zona de agarre:** toda la pastilla/tarjeta, excepto controles interactivos (la ✕; en el panel Live también la zona de scroll del texto sigue siendo scrolleable — el agarre ahí es en la fila de controles y bordes del panel).
- **Mecanismo (enfoque elegido, A):** `mousedown` en zona de agarre → `startDragging()` de Tauri (arrastre nativo del OS, fluido). Al soltar, se lee la posición final de la ventana y se persiste.
  - **Plan B (si el NSPanel de macOS rechaza `startDragging`):** arrastre manual JS (deltas de mousemove → `setPosition`), mismo contrato de persistencia.
  - **Linux con GTK layer-shell:** el arrastre queda deshabilitado (layer-shell ancla la ventana al compositor); sigue rigiendo el preset Arriba/Abajo como hoy. Sin layer-shell (X11/fallback), el arrastre funciona igual que en macOS/Windows.
- **Estados:** se puede arrastrar en cualquier estado visible (recording, transcribing, processing, streaming).
- **Foco:** la ventana sigue siendo no-activante/no-focusable — arrastrar NO roba el foco de la app donde se dicta.
- **Umbral clic vs. arrastre:** dentro de la zona de agarre, el drag nativo recién se inicia cuando el press se movió >~4px; un press que no supera el umbral no hace nada. (Los controles interactivos están excluidos del agarre, así que no necesitan umbral: la ✕ cancela con clic directo.)

## Persistencia y multi-monitor

- **Nuevo dato en settings:** mapa `overlay_custom_positions: { <monitor_key>: { anchor_x, anchor_y, edge } }` (persiste con el resto de settings vía tauri-plugin-store).
  - `monitor_key`: nombre del monitor (`Monitor::name()`); fallback a `pos+size` serializados si el nombre no está disponible.
  - **Ancla, no esquina:** se guarda el **centro horizontal de la tarjeta** (`anchor_x`, fracción 0–1 del ancho del monitor) y la **distancia del borde de la tarjeta al borde superior o inferior del monitor** (`anchor_y` en puntos lógicos + `edge: top|bottom`). Así la tarjeta no salta cuando la ventana cambia de tamaño entre compacto y streaming (la ventana se posiciona derivándola del ancla, igual que hoy se deriva del preset).
- **Elección de monitor al mostrar:** sin cambios — el overlay aparece en el monitor donde está el cursor. Si ese monitor tiene entrada en el mapa, se usa su ancla; si no, el preset Arriba/Abajo.
- **Dirección de crecimiento del panel Live:** derivada del ancla — `edge: top` (pastilla en mitad superior) crece hacia abajo; `edge: bottom` crece hacia arriba. El `edge` se decide al soltar el arrastre según en qué mitad del monitor quedó la tarjeta. Con preset, se comporta como hoy (top crece hacia abajo, bottom hacia arriba).
- **Al soltar el arrastre:** se calcula el ancla respecto al monitor donde quedó el **centro** de la tarjeta, se guarda en el mapa bajo ese monitor, y esa pantalla queda con memoria propia.

## Reset y settings

- **Tray:** nuevo ítem "Restablecer posición del overlay" → vacía `overlay_custom_positions`; el próximo show usa el preset. (Copy es-first; en/others via i18n.)
- **Configuración:** el selector Arriba/Abajo no cambia visualmente. Cualquier **escritura** del setting `overlay_position` (aunque sea re-seleccionar el mismo valor) vacía también el mapa de posiciones custom — así "elegir Abajo de nuevo" siempre resetea, dispare o no un change del dropdown.
- Sin estado "Personalizada" en la UI de settings (decisión explícita del usuario).

## Casos borde

- **Posición fuera de pantalla** (cambio de resolución, monitor distinto con el mismo nombre, restos viejos): al aplicar un ancla se **clampa** para que la tarjeta quede completa dentro del área visible del monitor; si el ancla es inaplicable (monitor sin dimensiones válidas), cae al preset.
- **Monitor desconectado:** su entrada queda en el mapa sin efecto (inofensiva); si se reconecta, recupera su posición. El mapa solo se limpia con los resets.
- **Arrastre a otro monitor:** válido — el ancla se guarda bajo el monitor donde quedó el centro de la tarjeta al soltar.
- **Arrastre durante cambio de estado** (p. ej. suelta la tecla y pasa a transcribing a mitad de drag): el drag nativo sigue siendo del OS; al soltar se persiste normal. El resize compacto↔streaming re-deriva la posición desde el ancla, así que no hay salto.

## Verificación (en vivo, app corriendo)

1. Estilo nuevo visible en los 4 estados (recording / transcribing / processing / streaming), en tema claro y oscuro, sobre fondo claro y oscuro.
2. Arrastrar en cada estado; la ✕ sigue cancelando con clic simple; el scroll del Live sigue funcionando.
3. Arrastrar, cerrar la app, reabrir, dictar → aparece donde quedó.
4. Con 2 pantallas: posición distinta en cada una; el overlay respeta la de la pantalla del cursor.
5. "Restablecer posición" del tray y re-selección de Arriba/Abajo en Configuración → vuelve al preset.
6. Simular fuera-de-rango (cambiar resolución con posición guardada cerca del borde) → la tarjeta aparece clampeada, nunca invisible.
7. El foco de la app activa no se pierde al arrastrar (escribir en un editor mientras se dicta y arrastra).

## Fuera de alcance

- Cambios al selector Arriba/Abajo o nueva UI en Configuración.
- Imanes/snapping a bordes o esquinas.
- Arrastre en Linux layer-shell.
- Cambios de comportamiento del pipeline de dictado, atajos o eventos (`mic-level`, `show-overlay`, etc.).

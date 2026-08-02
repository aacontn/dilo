# Dilo — Reuniones en la barra de menú: indicador, popover y la puerta al archivo

**Fecha:** 2026-08-01 · **Estado:** diseño aprobado por Alfonso en conversación · **Base:** [notetaker usable](2026-07-31-notetaker-usable-design.md) §1 (la ventana propia) y la [spec del notetaker](../../../specs/001-meeting-notetaker/spec.md)

## De dónde sale esto

Alfonso probó la ventana de reuniones y pidió dos cosas:

> "Primer cambio en la pestaña de grabar reuniones tienes que agregar el punto de volver a Dilo. Esa misma pantalla de grabar reuniones sería bueno que fuera algo en la barra de tarea superior."

La primera es un arreglo de una tarde anterior: al abrir Reuniones ahora se
esconde la ventana de Ajustes, y no quedó camino de vuelta. La segunda es este
diseño.

Al precisar el alcance, la forma que pidió fue de tres niveles: **ícono
indicador** arriba → **popover** de vidrio oscuro con lo general y la sesión en
curso → y desde ahí **el panel completo** en su ventana.

## Lo que este diseño NO es

Esto **no reemplaza** la ventana de reuniones de §1. La decisión de tener el
módulo completo en su propia ventana sigue en pie: el registro, los transcripts
y la asignación de hablantes se leen con calma, y eso no cabe —ni se disfruta—
en un popover. Lo que cambia es que la actividad _viva_ sube a la barra.

**El popover es lo que pasa ahora; la ventana es lo que quedó guardado.**

## 1 · El indicador

Un ícono en la barra de menú que refleja el estado de Dilo: reposo, grabando,
transcribiendo.

Esto ya existe. `tray.rs` mantiene `TrayIconState` con esos tres estados y sus
íconos por tema (claro/oscuro/coloreado para Linux). No se inventa nada: se le
cambia el comportamiento del clic.

## 2 · El popover

Al hacer clic se despliega un panel de vidrio, con el mismo tratamiento Liquid
Glass que las ventanas actuales (`transparent(true)` +
`TitleBarStyle::Overlay`).

**Sigue el tema, no un color fijo** (confirmado por Alfonso): vidrio oscuro en
tema oscuro, claro en tema claro. Él usa oscuro, así que en la práctica ve lo
que pidió — sin quedar roto si el tema cambia.

**Cuál tema, exactamente.** El ícono y el popover viven en la misma franja de
pantalla pero obedecen a fuentes distintas, y es deliberado:

| Superficie | Sigue                                    | Por qué                                                                                                                                                                                                                                           |
| ---------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| El ícono   | El tema del **sistema**                  | Legibilidad, no estética: es un bitmap sobre la barra del SO. `get_current_theme` en `tray.rs` ya lo resuelve así, y su comentario explica el caso de Windows —barra oscura con apps claras— donde el tema de la app elegiría un ícono invisible. |
| El popover | El ajuste **de Dilo** (`settings.theme`) | Es superficie propia de la app, no un bitmap peleando contra el fondo del sistema. Si alguien pone Dilo en oscuro con el sistema en claro, quiere Dilo oscuro, popover incluido.                                                                  |

`settings.theme` es `System | Light | Dark` y viene por defecto en `System`, así
que la mayoría nunca nota la diferencia; sólo importa para quien fija el tema a
mano.

Su contenido, en orden de arriba abajo:

1. **La ranura de avisos.** Vacía en esta versión. Es el lugar donde el
   proyecto de detección de reuniones (abajo) pondrá su "detecté una reunión,
   ¿grabo?". Se construye ahora y se deja vacía a propósito: así ese proyecto
   es rellenar una ranura existente, no rediseñar el popover.
2. **La sesión en curso.** Cronómetro, transcript vivo y el botón de detener.
   Sin sesión, el botón de empezar.
3. **Las últimas reuniones.** Las 4 más recientes, con fecha y duración, para
   abrir cualquiera. Cuatro y no "tres o cuatro": un número fijo evita que el
   popover cambie de alto según lo que haya.
4. **Las dos puertas.** Al pie, una junto a la otra:
   - **"Abrir transcript"** → la ventana de reuniones.
   - **"Abrir Dilo"** → la ventana de ajustes.

### Las dos puertas: el popover como conmutador

Alfonso lo pidió explícito: que el popover tenga interacción con las dos
ventanas, no sólo con la de reuniones. Eso lo convierte en **el conmutador de
la app** — desde la barra alcanzas cualquiera de las dos superficies sin pasar
por la otra.

Es lo que hace coherente el intercambio de ventanas que ya existe. Hoy abrir
Reuniones esconde Ajustes y volver hace lo inverso: **una ventana a la vez**.
Sin un lugar donde elegir, esa regla se siente como una puerta que se cierra
sola; con el popover, se siente como cambiar de pestaña. La regla no cambia —
gana el lugar desde donde se ejerce.

**No hace falta backend nuevo.** Las dos puertas son los comandos que ya
existen:

| Puerta           | Comando                 | Qué hace                                    |
| ---------------- | ----------------------- | ------------------------------------------- |
| Abrir transcript | `open_meetings_window`  | Muestra Reuniones y esconde Ajustes         |
| Abrir Dilo       | `return_to_main_window` | Muestra Ajustes y esconde Reuniones si está |

`return_to_main_window` sirve para los dos casos —con Reuniones abierta o sin
ella— porque muestra Ajustes siempre y sólo esconde Reuniones si existe.

### Por qué una ranura vacía y no nada

Dejar el hueco declarado cuesta poco hoy y evita que mañana haya que mover
todo para meter el aviso. Es la única concesión a futuro que se hace acá; el
resto es YAGNI.

## 3 · La ventana no se va

Sigue siendo el archivo: registro completo, transcripts, asignación de
hablantes. Gana además el **botón de volver a Dilo** que Alfonso pidió —
necesario desde que abrir Reuniones esconde Ajustes.

Ese botón es independiente de todo lo demás de este diseño y puede hacerse
solo.

## 4 · Windows y Linux

El popover de barra de menú es de macOS. En Windows y Linux el ícono de
bandeja conserva su menú actual, con la entrada que abre la ventana de
reuniones. **No hay paridad, y se dice en vez de fingirla:** macOS es donde
esto se siente bien y es donde se usa a diario.

Nada de lo que existe hoy en esas plataformas se rompe ni se quita.

## Alcance

**Entra:** el indicador con sus estados, el popover con sus cuatro zonas, la
ranura de avisos vacía, las dos puertas (transcript y Dilo), y el botón de
volver a Dilo en la ventana.

**No entra:**

- **Detección de reuniones.** Ver abajo — es su propio proyecto.
- **Resumen y action items por IA.** Donde estaban.
- **Paridad del popover en Windows/Linux.**

## Restricciones transversales

- **El dictado no cambia.** Todo es aditivo.
- **Copy es-first**, autoral, tuteo chileno; claves en los 21 idiomas.
- **Sin dependencias nuevas.**
- Respeta `prefers-reduced-motion` como el resto de la app.

## Verificación

- El ícono cambia de estado al empezar y terminar una grabación.
- El popover abre, cierra al perder foco, y no estorba mientras trabajas en
  otra app.
- Desde el popover se puede detener una grabación en curso.
- Las dos puertas del popover llevan a su ventana, y cada una esconde la otra:
  una ventana a la vez, sin quedar con las dos encima ni con ninguna.
- El botón de volver dentro de la ventana de reuniones reabre Ajustes.
- En Windows el ícono de bandeja sigue funcionando como antes.

---

## Anexo · Detectar reuniones (proyecto aparte, sin diseño aún)

Alfonso pidió que el aviso de "detecté una reunión" salga **desde este mismo
popover**, como la burbuja de Wispr Flow. La superficie queda lista (la ranura
de avisos); la capacidad no.

Es proyecto propio porque son **dos disparadores distintos**, y ninguno es UI:

- **Agendado** — calendario conectado. Sabe _antes_, con cuenta regresiva. Es
  lo que hace la píldora de Wispr según la inspección del 2026-07-27: va de
  Google Calendar, no de detección.
- **Espontáneo** — una llamada, un Meet que alguien te tira. Sabe _durante_, y
  ningún calendario lo ve venir. Es el caso que Alfonso describió.

Para el espontáneo, las rutas evaluadas:

| Ruta                                | Alcance                            | Costo                                      |
| ----------------------------------- | ---------------------------------- | ------------------------------------------ |
| Proceso corriendo                   | Zoom, Teams nativos                | Barato                                     |
| Título de ventana vía Accesibilidad | Meet, Blackboard en navegador      | Frágil: cambia con cada rediseño del sitio |
| **Micrófono en uso por otra app**   | **Todos, sin conocer ninguna app** | **Una señal, cero lista que mantener**     |

La tercera es la candidata: cubre Zoom, Meet, Blackboard y lo que venga sin
una lista de apps que envejece.

Este proyecto se junta naturalmente con la **captura de audio del sistema**
(Historia 2 del notetaker): en videollamada el micrófono sólo capta tu voz y un
eco pobre de los parlantes — la señal útil de los demás viaja por el sistema.
Detectar la reunión y grabarla bien son la misma conversación técnica.

**Nada de esto está autorizado a implementarse sin su propio diseño.**

# Dilo — Manos libres por doble toque (v0.1.11)

**Fecha:** 2026-07-18 · **Estado:** mecánica aprobada por Alfonso en conversación · **Base:** coordinador de transcripción (`src-tauri/src/transcription_coordinator.rs`)

## Qué es

Dos cosas chicas con impacto directo en el uso diario:

1. **Manos libres estilo Wispr Flow:** en modo push-to-talk, un **doble toque rápido del atajo** deja el dictado abierto sin sostener la tecla. Un **toque simple** lo corta y transcribe. Inspiración de mecánica: Wispr Flow (idea vista también en scribe, MIT — re-implementación propia desde cero, sin copiar código).
2. **Fix de la sombra fantasma:** el halo CSS del vidrio (blur 28px) se recorta contra el borde de la ventana transparente (pad de 12px), dibujando un rectángulo tenue detrás de la pastilla. La sombra pasa a caber dentro del pad.

## Decisiones tomadas (con Alfonso)

- **Mantener apretado** = PTT de siempre, sin ningún cambio de comportamiento.
- **Doble toque** (<~0.4s entre toques) = manos libres; la grabación sigue sola.
- **Cierre del manos libres: UN toque del atajo** (elegido sobre doble-toque simétrico). La ✕ del overlay y Esc/cancel siguen cancelando sin transcribir.
- Sin setting nuevo: la mecánica vive dentro del modo push-to-talk, siempre disponible (YAGNI). En modo toggle (sin PTT) no aplica — ahí el atajo ya es un toggle.
- Sin indicador visual nuevo en v1: la pastilla se ve igual grabando sostenido o en manos libres.

## Mecánica (máquina de estados PTT en el coordinador)

Constantes: `TAP_MAX_MS = 300` (un press más corto que esto es "toque"), `DOUBLE_TAP_WINDOW_MS = 350` (ventana tras soltar el primer toque para el segundo), `AUTOREPEAT_GAP_MS = 80` (ver abajo), `RELEASE_GRACE` (50ms, existente).

- **Press** con pipeline idle → empieza a grabar (igual que hoy). Se registra el instante del press.
- **Release** del binding que graba:
  - sostuvo **> TAP_MAX_MS** → stop diferido con `RELEASE_GRACE` (comportamiento actual intacto).
  - sostuvo **≤ TAP_MAX_MS** (fue un toque) → el stop se difiere `DOUBLE_TAP_WINDOW_MS`, esperando un posible segundo toque. Si la ventana vence sin segundo toque, para y transcribe (un toque corto se comporta como hoy, con ~350ms extra de espera — imperceptible: la grabación de un toque es casi vacía).
- **Press** durante un stop diferido del mismo binding:
  - si viene **< AUTOREPEAT_GAP_MS** después del release → es el par sintético release+press del auto-repeat de X11: se cancela el stop y se sigue grabando (absorbedor actual, intacto). Sin esto, sostener la tecla en Linux se bloquearía solo.
  - si viene después (humano) → **segundo toque: modo manos libres**. Se cancela el stop y se marca `locked`.
- **En `locked`:** los release se ignoran; un **press** → stop + transcribir (+ desbloquear). Cancel (✕/Esc/`--cancel`) limpia el lock como limpia todo.

## Fix sombra

`--s-shadow` pasa de `0 8px 28px` a un halo que quepa en el pad de 12px (≈ `0 2px 10px`, alfa levemente subida para compensar), y en dark su variante. Verificación visual en preview + app real: sin borde rectangular visible sobre fondos claros u oscuros.

## Testing

- La máquina PTT se extrae a una unidad testeable (estilo `classify_ptt_event` actual, que se reemplaza/amplía) con tests unitarios: doble toque → lock; lock + toque → stop; hold largo → stop por grace (regresión); par autorepeat → no lock; toque solitario → stop al vencer la ventana.
- Verificación en vivo por Alfonso antes de publicar (lección v0.1.9): doble toque abre y queda grabando, toque cierra y pega, PTT sostenido igual que siempre, sombra sin rectángulo.

## Fuera de alcance

- Indicador visual de "manos libres" en la pastilla (posible v2 si se echa de menos).
- Cambios al modo toggle, atajos nuevos o settings nuevos.
- El sliver siempre-visible de scribe (descartado: rompe reposo casi-cero).

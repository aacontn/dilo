# Dilo — Modos e IA: piso local, atajos en paralelo y proveedor por modo

**Fecha:** 2026-07-22 · **Estado:** diseño aprobado por Alfonso en conversación · **Base:** sistema de modos (`post_process_prompts`), bindings dinámicos `mode:<id>` (spec del 2026-07-18), pipeline de dictado

## El problema

Alfonso reportó que "solo puede tener un modo activo": al marcar uno en Inicio, el anterior se apaga. La investigación mostró que **la capacidad ya existe** — cada modo puede tener su atajo (`LLMPrompt.shortcut`, `register_mode_shortcuts` recorre todos) — pero solo un modo tenía atajo asignado y la UI no lo hace evidente. Lo que se apaga es el **modo seleccionado**, un concepto distinto que se pisa con el de atajo por modo.

O sea: el punto débil es real, pero es de **modelo mental y descubribilidad**, no de motor. El addendum del spec del 2026-07-18 ya lo había anotado ("al elegir 'literal' los modos de post-proceso desaparecen de la vista"); quedó a medias.

## Decisiones tomadas (con Alfonso)

- **Muere el "modo seleccionado".** Queda un piso siempre activo y modos con atajo propio, todos en paralelo.
- **"Literal + Limpio" deja de ser un modo** y pasa a ser el comportamiento base del dictado.
- **El piso se queda local.** Hacerlo programable por prompt obligaría a una llamada al LLM en cada dictado, rompiendo el offline-first, la latencia y el "funciona recién instalado". Quien quiera un piso programable lo activa explícitamente.
- **"Post-proceso" se llama "Modos e IA"** — el nombre dice dónde viven las claves de API, que fue justo lo que costó encontrar.
- Detección de foco y diccionario auto-aprendido **quedan fuera**, con entrada propia en el roadmap.

## Diseño

### 1 · Piso local (siempre, sin LLM)

Corre en cada transcripción, offline, instantáneo y gratis. Hoy ya existe en `managers/transcription.rs` (`apply_custom_words` + `filter_transcription_output`): quita muletillas por idioma o lista propia, colapsa tartamudeos y aplica el vocabulario del usuario.

**Se le agrega lo que hoy solo hace el LLM: mayúsculas y puntuación por reglas locales.** Alcance deliberadamente modesto — mayúscula tras punto y al inicio, punto final si falta, nombres propios del diccionario del usuario. Nada que requiera entender el texto; eso es trabajo del LLM.

Configurable desde la UI (hoy las listas existen pero están enterradas): palabras propias (`custom_words`) y muletillas propias (`custom_filler_words`).

### 2 · Modos con atajo propio, en paralelo

- Cada modo (`LLMPrompt`) conserva su `shortcut: Option<String>` y su binding dinámico `mode:<id>`. **Sin cambios de motor** — ya funciona.
- **`post_process_selected_prompt_id` se elimina.** Migración: si el usuario tenía un modo seleccionado, se conserva como "modo default" (ver §3) solo si además tenía activado el post-proceso; si no, se descarta sin ruido.
- El binding fijo `transcribe_with_post_process` pasa a disparar el **modo default**. Sin modo default configurado, avisa (toast) en vez de quedarse mudo — mismo criterio que el guard del asistente de voz en v0.1.12.
- **UI:** cada modo se muestra como tarjeta con su atajo visible y editable en la propia tarjeta (`ModeShortcutInput` ya existe en variante compacta). Los modos creados por el usuario aparecen igual que los de fábrica. Ya no hay estado "seleccionado" que confunda.

### 3 · Modo default opcional (piso por LLM)

- Un modo puede designarse **default del dictado normal**. Apagado de fábrica.
- Activado, el atajo de dictado normal pasa el texto por ese prompt. El usuario acepta latencia y costo conscientemente; se advierte en la UI.
- Es el mismo motor de modos ocupando el lugar del piso — no hay una segunda arquitectura.

### 4 · IA distinta por modo

- Hoy el proveedor es global (`post_process_provider_id`). Se agrega **override opcional por modo**: `LLMPrompt.provider_id: Option<String>` y `model: Option<String>`, ambos `serde(default)` → `None`.
- `None` = usa el proveedor global (comportamiento actual, cero migración).
- Las claves siguen viviendo en `post_process_api_keys` (`SecretMap`), una por proveedor — no se duplican por modo.
- Caso de uso real: un modelo rápido y barato para "Limpio", uno bueno para "Correo".

### 5 · Menú reordenado

| #   | Sección               | Nota                               |
| --- | --------------------- | ---------------------------------- |
| 1   | Inicio                |                                    |
| 2   | General               |                                    |
| 3   | **Modos e IA**        | era "Post-proceso"                 |
| 4   | Modelos               |                                    |
| 5   | Voz                   |                                    |
| 6   | **Notas y reuniones** | era "Notas"; anticipa el notetaker |
| 7   | Historial             |                                    |
| 8   | Avanzado              | baja: es para la minoría           |
| 9   | Debug · Acerca de     |                                    |

Progresión: empiezas → configuras lo básico → defines cómo escribe → qué modelo usa → cómo suena → dónde guarda → qué hiciste.

### 6 · Recuperación del pegado

**El problema:** `enigo` reporta éxito cuando _envía_ las teclas, no cuando la app las _recibe_. El fallo más común (foco cambiado, app que ignora input sintético, Secure Input) es **indetectable hoy**. Diseñar "detectar fallo → mostrar modal" no cubriría el caso real.

**Principio: nunca pedir que el usuario cierre nada, y no aparecer cuando todo salió bien.**

- **Overlay que se queda un momento (B):** el overlay que ya sale al transcribir no desaparece de golpe; permanece ~1,5 s con un botón "Copiar" y **se desvanece solo**. Nunca hay una X. No es superficie nueva: es un estado más en `show_overlay_state`, aditivo.
- **Recuperación pasiva (A):** ítem en la bandeja _"Copiar último dictado"_, que copia la última entrada del historial. Cero intrusión visual; red de seguridad cuando se pasó el momento.
- **Respeta `clipboard_handling: DontModify`:** copiar es siempre una acción explícita del usuario (botón), nunca automática.

La versión proactiva (mostrar solo ante sospecha, usando la app en foco) depende de la detección de foco, que queda en el roadmap.

## Restricciones transversales

- **Copy es-first** (autoral, tuteo, sin relleno); claves i18n en los 22 locales — `check:translations` bloquea CI.
- **Offline-first intacto:** el camino por defecto (dictado + piso local) no toca la red ni exige proveedor configurado.
- **Aditivo respecto de upstream:** lo nuevo en módulos propios; los archivos compartidos con Handy se tocan lo mínimo.
- Sin dependencias nuevas.

## Verificación (en vivo, Alfonso)

1. Asignar atajo a tres modos distintos y usar los tres seguidos desde otra app → cada uno aplica su prompt; ninguno "apaga" a otro.
2. Dictado normal sin configurar nada, sin internet → sale limpio, con mayúsculas y punto final, instantáneo.
3. Designar un modo como default → el dictado normal pasa por él; desactivarlo → vuelve al piso local.
4. Poner proveedor distinto en dos modos → cada uno llama al suyo; un modo sin override sigue usando el global.
5. Menú en el orden nuevo, con "Modos e IA" y "Notas y reuniones".
6. Tras dictar, el overlay se queda un momento con "Copiar" y se va solo sin tocar nada; la bandeja copia el último dictado.
7. Usuario que venía de v0.1.12 con modo seleccionado → migra sin perder nada ni ver errores.

## Fuera de alcance (roadmap propio)

- **Detección de la app en foco** → modo automático por app, recuperación proactiva del pegado, no pegar en campos de contraseña. Fuerte en macOS y Windows; Linux queda como está (Wayland no lo permite de forma confiable).
- **Diccionario que aprende solo**: minar el diff entre `transcription_text` y `post_processed_text` del historial para proponer palabras al diccionario local. La señal ya existe; falta el modelo de datos, los umbrales y la UI de confirmación.
- **Posicionamiento y web** (capacidad ancha, mensaje angosto; es-first con la puerta abierta al inglés).
- Afinar un modelo propio.

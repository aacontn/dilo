# Dilo — Atajos por modo + Nota rápida con sincronización (v0.1.12)

**Fecha:** 2026-07-18 · **Estado:** diseño aprobado por Alfonso en conversación (alcance "todo de una"; agrupación "una nota por captura") · **Base:** sistema de modos (`post_process_prompts`), bindings (`shortcut/`), pipeline de dictado

## Qué es

Dos features que convergen:

1. **Atajo por modo (seleccionable):** cada modo de dictado (Literal+Limpio, Prompt, Mensaje, Correo, Código, y los que el usuario cree) gana un campo opcional de atajo global. Apretar el atajo de un modo dicta directamente con ese modo, sin cambiar la selección global. El doble toque manos libres funciona igual en todos.
2. **Nota rápida + "Notas" en Configuración:** un nuevo destino de dictado — en vez de pegar donde está el cursor, la transcripción se guarda como nota. **Local-first:** siempre se escribe un archivo markdown local (instantáneo, offline); la sincronización a destinos externos (Notas de Apple, Notion) es una capa encima, por captura.

## Decisiones tomadas (con Alfonso)

- Alcance **todo de una** en v0.1.12: atajos por modo + nota local (cubre Obsidian/Logseq apuntando la carpeta al vault) + Notas de Apple + Notion.
- **Una nota por captura** (no nota diaria acumulada): cada dictado crea un archivo/nota/página independiente.
- Windows: el destino local (markdown) funciona igual; OneNote (Microsoft Graph + OAuth) queda explícitamente para más adelante. Candidatos futuros: Apple Reminders, Bear, Joplin.

## Diseño

### 1 · Atajos por modo

- **Modelo:** binding dinámico por modo, id `mode:<prompt_id>` (p. ej. `mode:preset_codigo`). Se persiste dentro del `LLMPrompt` (`shortcut: Option<String>`, serde default → None) para que viva y muera con el modo. Vacío = sin atajo.
- **Comportamiento:** el atajo dispara el pipeline completo de dictado con post-proceso usando ESE prompt, sin tocar `post_process_selected_prompt_id` (el modo seleccionado globalmente no cambia). PTT + doble toque manos libres idénticos al atajo principal (pasa por el coordinador con su binding id propio).
- **Registro:** al iniciar y al crear/editar/borrar modos se (des)registran los shortcuts dinámicos junto a los fijos. Conflictos de teclas: se valida contra los bindings existentes al asignar (mismo mecanismo/UX que el input de atajos actual).
- **UI:** en la tarjeta de cada modo (donde se edita nombre/prompt), un input de atajo reutilizando el componente de shortcut existente. Etiqueta es-first: "Atajo del modo (opcional)".

### 2 · Nota rápida

- **Acción nueva** `quick_note` con su propio atajo global (configurable, sin default para no chocar con nada). Flujo: atajo → grabar (PTT/manos libres igual que dictar) → transcribir (SIN post-proceso en v1: la nota es literal+limpio con el filtro de muletillas estándar) → guardar como nota. **No pega** en la app activa; el overlay muestra el estado normal y al terminar un feedback breve de éxito.
- **Archivo local (siempre):** un `.md` por captura en la carpeta configurada.
  - Default: `~/Documents/Dilo/Notas/`.
  - Nombre: `AAAA-MM-DD HH.mm.ss — Nota.md` (ordenable, sin caracteres ilegales).
  - Contenido: frontmatter mínimo (`fecha`) + el texto. Sin plantillas configurables en v1.
  - Apuntar la carpeta a un vault de Obsidian/Logseq = integración lista.
- **Sincronización por captura** a destinos habilitados (0, 1 o ambos):
  - **Notas de Apple** (solo macOS): `osascript` crea la nota en una carpeta "Dilo" (se crea si no existe). Título = primera línea/timestamp; cuerpo = texto.
  - **Notion:** API oficial (`POST /v1/pages`) con token de integración interna del usuario + id de página o base de datos padre. Título + bloque de párrafo con el texto. El token se guarda con el mismo mecanismo de secretos redactados que las API keys de post-proceso.
  - **Pendientes:** si un destino falla (sin internet, token inválido), la nota local ya está a salvo; la sincronización queda en una cola de pendientes (persistida en settings) que se reintenta al capturar la siguiente nota y al iniciar la app. La UI de Notas muestra cuántas hay pendientes y el último error.
- **Sección "Notas" en Configuración:** carpeta local (picker), atajo de nota rápida, toggle+config por destino (Apple Notes: nombre de carpeta; Notion: token + id del padre + botón "Probar conexión"), contador de pendientes.

### 3 · Restricciones transversales

- Copy es-first (es autoral); claves i18n en los 22 locales (lo exige `check:translations`).
- Offline-first: nada de la captura local depende de red. Notion es el único destino con red y falla suave.
- Sin dependencias nuevas pesadas: Apple Notes vía `osascript` (std), Notion vía el HTTP client ya presente en el proyecto (el de post-proceso).
- Windows/Linux: nota local plenamente funcional; destinos externos ocultos si la plataforma no los soporta (Apple Notes fuera de macOS).

## Verificación (en vivo, Alfonso)

1. Asignar atajo a un modo (ej. Código), dictar con él desde otra app → pega con ese modo aplicado; el modo global seleccionado no cambió; manos libres funciona con ese atajo.
2. Nota rápida: atajo → dictar → aparece el `.md` en la carpeta configurada con timestamp y texto correcto; nada se pegó en la app activa.
3. Carpeta apuntada al vault de Obsidian → la nota aparece en Obsidian.
4. Apple Notes habilitado → la nota aparece en la carpeta "Dilo" de Notas.
5. Notion habilitado (token + página) → la página aparece; "Probar conexión" reporta bien/mal según token.
6. Sin internet + Notion habilitado → nota local OK, pendiente en cola; al volver internet y capturar otra nota, se sincronizan ambas.
7. Atajos existentes (dictado normal, post-proceso) intactos.

## Fuera de alcance

- OneNote / Microsoft Graph (Windows) — futuro.
- Nota diaria acumulada, plantillas de nota, post-proceso en notas.
- Resúmenes/LLM sobre notas (territorio de la app hermana agéntica).

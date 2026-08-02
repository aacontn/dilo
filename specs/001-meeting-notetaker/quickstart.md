# Quickstart: Validar el Notetaker de Reuniones

Guía de validación manual end-to-end, una vez implementadas las tasks. No
reemplaza los tests automatizados — es el checklist para confirmar que la
feature cumple la spec con gente real hablando.

## Prerrequisitos

- Build de Dilo con esta feature (`bun run tauri dev` o build de CI).
- Permiso de micrófono concedido.
- macOS con permiso de "Grabación de pantalla y audio del sistema"
  concedido, para la Historia 2.

## Escenario 1 — Diarización presencial (P1, el que más importa)

1. Sentar 3 personas alrededor de una laptop/mic.
2. Iniciar grabación de tipo `presencial`.
3. Conversar ~3-5 minutos, incluyendo al menos un momento donde dos
   personas hablen encimadas a propósito.
4. Detener la grabación.
5. **Verificar**: el transcript resultante distingue a las 3 personas con
   labels consistentes (`Hablante 1/2/3`), y el segmento superpuesto queda
   marcado como tal (no como una sola línea inventada) — corresponde a
   spec SC-001 y al Edge Case de superposición.
6. **Verificar (privacidad)**: revisar logs/tráfico de red durante el paso
   3 y confirmar que no hubo ninguna llamada saliente asociada a
   transcripción o diarización (FR-014, SC-005).

## Escenario 1b — Detección automática de reunión virtual

1. Iniciar una videollamada de prueba sin tocar Dilo antes.
2. **Verificar**: aparece una notificación descartable de "reunión
   detectada" con una acción de un click para grabar (FR-017, SC-008) —
   no arranca a grabar solo.
3. Hacer click en grabar.
4. Colgar la videollamada.
5. **Verificar**: aparece una confirmación para detener o seguir grabando
   (FR-018) — no se corta la grabación sin preguntar.

## Escenario 2 — Reunión virtual

1. Iniciar una videollamada de prueba (Zoom/Meet) con al menos 1 otro
   participante.
2. Iniciar grabación de tipo `virtual` en Dilo, sin compartir pantalla ni
   invitar ningún bot a la llamada.
3. Conversar un par de minutos.
4. **Verificar**: el transcript incluye intervenciones de ambos lados de la
   llamada (FR-016).

## Escenario 3 — Recuperación ante interrupción

1. Iniciar una grabación presencial.
2. Hablar ~30 segundos.
3. Forzar el cierre de la app (kill del proceso, no cierre normal).
4. Reabrir Dilo.
5. **Verificar**: aparece un evento/estado de reunión interrumpida
   (`meeting-interrupted`), y el transcript parcial de esos ~30 segundos
   sigue disponible — no se perdió (FR-007, FR-008, SC-003).

## Escenario 4 — Revisión, búsqueda y preguntas

1. Con al menos 2 reuniones ya grabadas y procesadas (`status: ready`).
2. Abrir una reunión y navegar entre las pestañas Transcript / Resumen /
   Pendientes.
3. **Verificar**: la pestaña "Mis Pensamientos" permite escribir texto libre
   propio, guardado independiente del transcript (FR-009b) — escribir ahí
   no modifica ni se mezcla con la transcripción generada.
4. **Verificar**: los pendientes aparecen como lista independiente, no
   mezclados en el texto del resumen (FR-006).
5. Buscar una palabra que se haya dicho en una de las reuniones.
6. **Verificar**: aparece en resultados con contexto (FR-010, SC-006).
7. Preguntar en lenguaje natural algo sobre el contenido de esa reunión.
8. **Verificar**: la respuesta se basa en el transcript real, no genérica
   (FR-011).

## Escenario 5 — Sincronización

1. Configurar Apple Notes como destino de sincronización.
2. Grabar y procesar una reunión corta.
3. **Verificar**: aparece una nota nueva en Apple Notes con resumen y
   pendientes, sin acción manual (FR-012, SC-007).
4. Quitar el destino configurado, procesar otra reunión.
5. **Verificar**: la reunión queda disponible dentro de Dilo igual, la
   sincronización no es requisito para poder revisarla.

## Escenario 6 — Sesión larga

1. Grabar una sesión presencial o virtual de 2+ horas (puede ser audio de
   prueba en loop).
2. **Verificar**: no hay degradación perceptible de latencia de
   transcripción ni crecimiento descontrolado de memoria entre el inicio y
   el final (SC-004) — inspeccionar con Activity Monitor / `cargo` metrics
   durante la sesión.

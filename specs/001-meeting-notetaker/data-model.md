# Data Model: Notetaker de Reuniones

Deriva de las Key Entities de `spec.md`. Persistencia en SQLite vía
`rusqlite` + `rusqlite_migration`, tablas nuevas (`meetings`,
`meeting_segments`, `meeting_speakers`, `meeting_action_items`), siguiendo
el patrón de migraciones de `managers/history.rs`. No se reutiliza
`transcription_history` — el ciclo de vida de una reunión (parcial,
interrumpida, con hablantes) no encaja en el modelo de entrada única que
usa esa tabla hoy.

## Entidades

### Meeting (`meetings`)

| Campo                 | Tipo                                     | Notas                                                                                                     |
| --------------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `id`                  | INTEGER PK AUTOINCREMENT                 |                                                                                                           |
| `title`               | TEXT                                     | editable por el usuario; default derivado de fecha/hora                                                   |
| `kind`                | TEXT                                     | `presencial` \| `virtual` (Historias 1 y 2)                                                               |
| `started_at`          | INTEGER (unix ts)                        |                                                                                                           |
| `ended_at`            | INTEGER NULL                             | NULL mientras está en curso                                                                               |
| `status`              | TEXT                                     | `recording` \| `processing` \| `ready` \| `interrupted` — ver Transiciones de Estado                      |
| `summary`             | TEXT NULL                                | generado vía `llm_client.rs`, NULL hasta que `status = ready`                                             |
| `summary_prompt`      | TEXT NULL                                | prompt usado, editable por el usuario (mismo patrón que `post_process_prompt` en `transcription_history`) |
| `sync_destination_id` | INTEGER NULL FK → `sync_destinations.id` | NULL = no sincronizar                                                                                     |
| `synced_at`           | INTEGER NULL                             | NULL si aún no sincronizó                                                                                 |

**Validación**: `ended_at` NULL mientras `status = recording`; una vez
`status IN (ready, interrupted)`, `ended_at` MUST NOT ser NULL (FR-008).

### MeetingSegment (`meeting_segments`)

| Campo           | Tipo                                    | Notas                                                                         |
| --------------- | --------------------------------------- | ----------------------------------------------------------------------------- |
| `id`            | INTEGER PK AUTOINCREMENT                |                                                                               |
| `meeting_id`    | INTEGER FK → `meetings.id`              |                                                                               |
| `speaker_id`    | INTEGER NULL FK → `meeting_speakers.id` | NULL = hablante incierto (FR-004)                                             |
| `text`          | TEXT                                    |                                                                               |
| `started_at_ms` | INTEGER                                 | offset desde el inicio de la reunión                                          |
| `ended_at_ms`   | INTEGER                                 |                                                                               |
| `overlapped`    | BOOLEAN DEFAULT 0                       | marca si el segmento se solapó con otro hablante (Edge Case de superposición) |

**Validación**: se insertan de forma incremental durante la grabación (no
al final) — es el mecanismo detrás de FR-002/FR-007.

### MeetingSpeaker (`meeting_speakers`)

| Campo            | Tipo                                    | Notas                                                                                                |
| ---------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `id`             | INTEGER PK AUTOINCREMENT                |                                                                                                      |
| `meeting_id`     | INTEGER FK → `meetings.id`              | un hablante es local a una reunión, no global                                                        |
| `label`          | TEXT                                    | `Hablante 1`, `Hablante 2`... por defecto                                                            |
| `display_name`   | TEXT NULL                               | asignado por el usuario (FR-005)                                                                     |
| `merged_into_id` | INTEGER NULL FK → `meeting_speakers.id` | si se fusionó con otro (FR-005); segmentos apuntando a un hablante fusionado se resuelven al destino |

### MeetingNote (`meeting_notes`)

| Campo        | Tipo                              | Notas                                                               |
| ------------ | --------------------------------- | ------------------------------------------------------------------- |
| `id`         | INTEGER PK AUTOINCREMENT          |                                                                     |
| `meeting_id` | INTEGER FK → `meetings.id` UNIQUE | una nota propia por reunión (pestaña "Mis Pensamientos", FR-009b)   |
| `content`    | TEXT                              | texto libre, escrito por el usuario, nunca generado automáticamente |
| `updated_at` | INTEGER                           |                                                                     |

**Validación**: independiente de `meeting_segments` — nunca se sobreescribe
con contenido transcrito ni se mezcla con `summary`.

### ActionItem (`meeting_action_items`)

| Campo         | Tipo                       | Notas                 |
| ------------- | -------------------------- | --------------------- |
| `id`          | INTEGER PK AUTOINCREMENT   |                       |
| `meeting_id`  | INTEGER FK → `meetings.id` |                       |
| `text`        | TEXT                       |                       |
| `done`        | BOOLEAN DEFAULT 0          |                       |
| `order_index` | INTEGER                    | orden de presentación |

**Nota**: separado de `summary` (texto libre) a propósito — FR-006 pide
listas de pendientes independientes del resumen, no mezcladas dentro del
texto.

### SyncDestination (`sync_destinations`)

| Campo     | Tipo                     | Notas                                                       |
| --------- | ------------------------ | ----------------------------------------------------------- |
| `id`      | INTEGER PK AUTOINCREMENT |                                                             |
| `kind`    | TEXT                     | `apple_notes` (v1); extensible a otros destinos después     |
| `config`  | TEXT (JSON)              | detalle específico del destino (ej. carpeta de Apple Notes) |
| `enabled` | BOOLEAN DEFAULT 1        |                                                             |

## Transiciones de Estado (`meetings.status`)

```text
              start_meeting
                   │
                   ▼
              [recording] ──stop_meeting──▶ [processing] ──resumen+pendientes listos──▶ [ready]
                   │                                                                        │
                   │ crash / cierre forzado                                                  │
                   ▼                                                                        │
             [interrupted] ◀── reabrir Dilo y detectar sesión sin `ended_at` ────────────────┘
```

- `recording → processing`: al llamar `stop_meeting`; dispara generación de
  resumen/pendientes (Historia 3) de forma asíncrona.
- `recording → interrupted`: detectado al reiniciar la app (FR-008), no por
  una transición explícita del usuario — el transcript parcial ya
  persistido (FR-007) se conserva.
- `interrupted` es un estado terminal: no se reanuda la grabación, se puede
  seguir revisando el transcript parcial (Historia 3, escenario 3).

## Relación con entidades existentes

- No hay FK hacia `transcription_history` — son ciclos de vida
  independientes. El dictado normal sigue funcionando exactamente igual
  durante una reunión grabada (no se bloquean mutuamente a nivel de
  managers, aunque no pueden usar el mismo audio del micrófono a la vez a
  nivel de dispositivo).
- `summary`/`summary_prompt` reutilizan el mismo `PostProcessProvider` que
  ya gestiona `llm_client.rs` para `transcription_history.post_process_*` —
  no se crea una segunda abstracción de proveedor LLM.

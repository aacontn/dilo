# Contract: Comandos Tauri — Notetaker de Reuniones

Sigue el patrón comando-evento ya usado por el resto de Dilo (frontend →
backend por comandos, backend → frontend por eventos). Tipos compartidos
generados vía `tauri-specta` como el resto de `bindings.ts`.

## Comandos

### `start_meeting`

- **Input**: `{ kind: "presencial" | "virtual" }`
- **Output**: `{ meetingId: number }`
- **Errores**: `recording_busy` si ya hay una reunión o dictado usando el
  micrófono de forma exclusiva.
- Corresponde a Historias 1 y 2, escenario 1.

### `stop_meeting`

- **Input**: `{ meetingId: number }`
- **Output**: `void` (el progreso de procesamiento llega por evento)
- Transición `recording → processing` (ver data-model.md).

### `cancel_meeting`

- **Input**: `{ meetingId: number }`
- **Output**: `void`
- Descarta una reunión en curso sin generar resumen (distinto de `stop`).

### `list_meetings`

- **Input**: `{ query?: string, limit: number, offset: number }`
- **Output**: `{ meetings: MeetingSummary[], hasMore: boolean }`
- `query` implementa la búsqueda de texto de Historia 4, escenario 1.

### `get_meeting`

- **Input**: `{ meetingId: number }`
- **Output**: `Meeting` completo (con `segments`, `speakers`, `actionItems`)
- Alimenta las pestañas de Historia 3 (Transcript / Resumen / Pendientes).

### `rename_meeting`

- **Input**: `{ meetingId: number, title: string }`
- **Output**: `void`

### `delete_meeting`

- **Input**: `{ meetingId: number }`
- **Output**: `void`

### `assign_speaker_name`

- **Input**: `{ speakerId: number, displayName: string }`
- **Output**: `void`
- Historia 1 (implícito en revisión), FR-005.

### `merge_speakers`

- **Input**: `{ meetingId: number, sourceSpeakerId: number, targetSpeakerId: number }`
- **Output**: `void`
- FR-005 — fusiona dos identificadores que el sistema separó de más.

### `ask_meeting_question`

- **Input**: `{ meetingId: number, question: string }`
- **Output**: `{ answer: string }`
- Historia 4, escenario 2. Usa el transcript de esa reunión como contexto
  para el proveedor LLM existente — no responde sin fundamento en lo
  grabado (ver spec).

### `save_meeting_notes`

- **Input**: `{ meetingId: number, content: string }`
- **Output**: `void`
- Historia 4, escenario 2 (pestaña "Mis Pensamientos"), FR-009b. Guarda
  texto libre del usuario, independiente del transcript.

### `set_sync_destination` / `get_sync_destinations`

- **Input** (`set`): `{ meetingId: number | null, destinationId: number | null }`
  (`meetingId: null` = destino por defecto para reuniones futuras)
- **Output**: `void` / `SyncDestination[]`
- Historia 5.

## Eventos (backend → frontend)

### `meeting-segment`

Emitido cada vez que un nuevo `MeetingSegment` queda transcrito
(incremental, ver research.md §2). Payload: `MeetingSegment` completo,
incluyendo `speakerId` (o `null` si incierto, FR-004).

### `meeting-progress`

Emitido durante `processing` (generación de resumen/pendientes). Payload:
`{ meetingId: number, phase: "transcribing" | "diarizing" | "summarizing" }`.

### `meeting-finished`

Payload: `{ meetingId: number }` — `status` pasó a `ready`.

### `meeting-error`

Payload: `{ meetingId: number, error: string }`.

### `meeting-interrupted`

Emitido al arrancar la app si se detecta una reunión sin `ended_at` de una
sesión anterior (FR-008). Payload: `{ meetingId: number }`.

### `meeting-call-detected`

Historia 3, FR-017. Emitido cuando se detecta audio de sistema de una
videollamada activa y no hay ninguna grabación en curso. Payload:
`{ callSource: string }` (ej. nombre de la app detectada, si se puede
determinar). El frontend muestra la notificación descartable con la acción
de un click — este evento no inicia la grabación por sí solo.

### `meeting-call-ended`

Historia 3, FR-018. Emitido cuando la videollamada que originó una
grabación activa por detección automática terminó. Payload:
`{ meetingId: number }`. El frontend ofrece detener o seguir grabando —
este evento no detiene la grabación por sí solo.

## Tipos compartidos (referencia, no exhaustivo)

```ts
type MeetingStatus = "recording" | "processing" | "ready" | "interrupted";
type MeetingKind = "presencial" | "virtual";

interface MeetingSummary {
  id: number;
  title: string;
  kind: MeetingKind;
  startedAt: number;
  endedAt: number | null;
  status: MeetingStatus;
}

interface Meeting extends MeetingSummary {
  summary: string | null;
  notes: string | null;
  segments: MeetingSegment[];
  speakers: MeetingSpeaker[];
  actionItems: ActionItem[];
}

interface MeetingSegment {
  id: number;
  speakerId: number | null;
  text: string;
  startedAtMs: number;
  endedAtMs: number;
  overlapped: boolean;
}

interface MeetingSpeaker {
  id: number;
  label: string;
  displayName: string | null;
}

interface ActionItem {
  id: number;
  text: string;
  done: boolean;
}
```

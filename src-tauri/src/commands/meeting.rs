//! Tauri commands for the meeting notetaker feature. `start_meeting` (T011)
//! is the first one — see `specs/001-meeting-notetaker/contracts/
//! tauri-commands.md` for the full contract this feature will grow into.
//! `stop_meeting` (T015) es el segundo.

use crate::managers::meeting::MeetingManager;
use std::sync::Arc;
use tauri::State;

/// Start a new meeting recording: inserts a `meetings` row with
/// `status = "recording"` and returns its `id`.
///
/// This command deliberately does not touch the microphone or start any
/// audio capture — that's a separate, later task (T012) that needs to
/// understand how `AudioRecordingManager`'s dictation recording works
/// before deciding how the two coexist. It also does not check for a
/// dictation recording in progress, only for another meeting already
/// recording (`meetings.status = 'recording'`), per
/// `specs/001-meeting-notetaker/contracts/tauri-commands.md#start_meeting`.
#[tauri::command]
#[specta::specta]
pub async fn start_meeting(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    kind: String,
) -> Result<i64, String> {
    if kind != "presencial" && kind != "virtual" {
        return Err(format!("Invalid meeting kind: {}", kind));
    }

    meeting_manager
        .start_meeting(&kind)
        .map_err(|e| e.to_string())
}

/// Detener una reunión en curso: `recording → processing` (contrato:
/// `tauri-commands.md#stop_meeting`, output `void` — el progreso llega por
/// evento).
///
/// El comando devuelve apenas la transición de estado está confirmada, y deja
/// el resto corriendo en background por dos razones:
///
/// 1. Detener la captura **bloquea**: `stop_capture` junta los hilos de
///    watchdog y transcripción, que antes de salir drenan la cola de turnos
///    pendientes (transcribir cada uno puede tardar segundos). Hacer eso en el
///    hilo del comando congelaría la UI justo cuando el usuario apretó
///    "detener".
/// 2. El contrato ya dice que el progreso viaja por eventos
///    (`meeting-progress`, `meeting-finished`, `meeting-error`), así que la
///    UI no necesita que el comando espere.
///
/// El estado se mueve a `processing` **antes** de devolver: si la app se cae
/// mientras se drena la cola, la reunión no queda como `recording` sin
/// `ended_at` y la recuperación de T021 no la confunde con una sesión
/// interrumpida de verdad.
#[tauri::command]
#[specta::specta]
pub async fn stop_meeting(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    meeting_id: i64,
) -> Result<(), String> {
    meeting_manager
        .stop_meeting(meeting_id)
        .map_err(|e| e.to_string())?;

    let manager = Arc::clone(&meeting_manager);
    tauri::async_runtime::spawn_blocking(move || manager.drain_and_finalize(meeting_id));

    Ok(())
}

/// Ponerle nombre a un hablante detectado, o renombrarlo (FR-005). Mandar un
/// nombre vacío borra el nombre y deja la etiqueta automática `Hablante N`.
#[tauri::command]
#[specta::specta]
pub async fn assign_speaker_name(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    speaker_id: i64,
    display_name: String,
) -> Result<(), String> {
    meeting_manager
        .assign_speaker_name(speaker_id, &display_name)
        .map_err(|e| e.to_string())
}

/// Fusionar dos hablantes que el sistema separó de más (FR-005): todo lo de
/// `sourceSpeakerId` pasa a mostrarse bajo `targetSpeakerId`.
///
/// Es la contraparte necesaria de la atribución automática: el registro de
/// hablantes prefiere no asignar antes que adivinar (FR-004), pero cuando de
/// todos modos separa a una misma persona en dos, corregirlo es del usuario y
/// no de un re-clustering silencioso del transcript que ya vio.
#[tauri::command]
#[specta::specta]
pub async fn merge_speakers(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    meeting_id: i64,
    source_speaker_id: i64,
    target_speaker_id: i64,
) -> Result<(), String> {
    meeting_manager
        .merge_speakers(meeting_id, source_speaker_id, target_speaker_id)
        .map_err(|e| e.to_string())
}

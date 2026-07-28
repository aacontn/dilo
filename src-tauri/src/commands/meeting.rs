//! Tauri commands for the meeting notetaker feature. `start_meeting` (T011)
//! is the first one — see `specs/001-meeting-notetaker/contracts/
//! tauri-commands.md` for the full contract this feature will grow into.

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

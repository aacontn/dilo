//! Manages the lifecycle of a meeting notetaker session: recording, live
//! transcription, and speaker diarization. This is currently a skeleton —
//! real behavior lands in later tasks (T005 onward).

// Nothing constructs this yet — Tauri state registration happens in T007.
#![allow(dead_code)]

pub struct MeetingManager {}

impl MeetingManager {
    pub fn new() -> Self {
        Self {}
    }
}

impl Default for MeetingManager {
    fn default() -> Self {
        Self::new()
    }
}

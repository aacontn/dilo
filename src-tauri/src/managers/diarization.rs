//! Speaker diarization engine: identifies "who spoke when" within a meeting
//! recording. This is currently a skeleton — real behavior lands in later
//! tasks (T005 onward).

// Nothing constructs this yet — Tauri state registration happens in T007.
#![allow(dead_code)]

pub struct DiarizationEngine {}

impl DiarizationEngine {
    pub fn new() -> Self {
        Self {}
    }
}

impl Default for DiarizationEngine {
    fn default() -> Self {
        Self::new()
    }
}

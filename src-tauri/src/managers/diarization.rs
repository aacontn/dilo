//! Speaker diarization engine: identifies "who spoke when" within a meeting
//! recording. This is currently a skeleton — real behavior lands in later
//! tasks (T005 onward).

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

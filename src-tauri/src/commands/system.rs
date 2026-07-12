/// Total physical RAM in whole GiB. The onboarding flow uses it to pick the
/// model recommendation for this machine.
#[tauri::command]
#[specta::specta]
pub fn get_total_memory_gb() -> u32 {
    let mut sys = sysinfo::System::new();
    sys.refresh_memory();
    (sys.total_memory() / (1024 * 1024 * 1024)) as u32
}

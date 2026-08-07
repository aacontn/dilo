use clap::Parser;
use std::path::PathBuf;

#[derive(Parser, Debug, Clone, Default)]
#[command(name = "dilo", about = "Dilo - Dictado por voz offline")]
pub struct CliArgs {
    /// Start with the main window hidden
    #[arg(long)]
    pub start_hidden: bool,

    /// Disable the system tray icon
    #[arg(long)]
    pub no_tray: bool,

    /// Toggle transcription on/off (sent to running instance)
    #[arg(long)]
    pub toggle_transcription: bool,

    /// Toggle transcription with a transformation mode on/off (sent to running
    /// instance). Optionally pick the mode by id or name
    /// (`--toggle-post-process=dilo-code`); without a value Dilo uses the first
    /// mode that has a key assigned — the same one its key would run.
    #[arg(long, value_name = "MODE", num_args = 0..=1, require_equals = true, default_missing_value = "")]
    pub toggle_post_process: Option<String>,

    /// Cancel the current operation (sent to running instance)
    #[arg(long)]
    pub cancel: bool,

    /// Enable debug mode with verbose logging
    #[arg(long)]
    pub debug: bool,

    /// Transcribe this WAV (16 kHz mono) headlessly and exit. Runs the same
    /// batch transcription path as the app — no mic, no VAD, no download
    /// (the model must already be installed).
    #[arg(short = 'f', long, value_name = "WAV")]
    pub transcribe_file: Option<PathBuf>,

    /// Model id to load for --transcribe-file (default: the selected model).
    #[arg(long)]
    pub model: Option<String>,

    /// Hard-select the compute device for --transcribe-file by its registry
    /// index (see --list-devices). Omit to use the persisted accelerator
    /// setting. transcribe-cpp (whisper-family) models only.
    #[arg(long, value_name = "N")]
    pub device_index: Option<usize>,

    /// List the transcribe-cpp compute devices (with indices) and exit.
    #[arg(long)]
    pub list_devices: bool,

    /// List the available models (with ids) and exit. Pass an id to --model.
    /// Honors --json for machine-readable output.
    #[arg(long)]
    pub list_models: bool,

    /// Repeat the transcription N times (best_ms reports the fastest run).
    #[arg(long, value_name = "N")]
    pub repeat: Option<usize>,

    /// Emit --transcribe-file results as JSON.
    #[arg(long)]
    pub json: bool,
}

#[cfg(test)]
mod tests {
    use super::CliArgs;
    use clap::{CommandFactory, Parser};

    #[test]
    fn la_definicion_de_la_cli_es_coherente() {
        // `debug_assert` es el chequeo interno de clap: pilla las
        // combinaciones inválidas de `num_args`/`require_equals`/
        // `default_missing_value` acá y no como pánico al arrancar la app.
        CliArgs::command().debug_assert();
    }

    #[test]
    fn toggle_post_process_lleva_un_modo_opcional() {
        // Sin valor = "el modo de mi tecla de transformar"; con valor = ese
        // modo por id o por nombre. Ver `signal_handle::resolve_post_process_target`.
        let sin_modo = CliArgs::parse_from(["dilo", "--toggle-post-process"]);
        assert_eq!(sin_modo.toggle_post_process.as_deref(), Some(""));

        let con_modo = CliArgs::parse_from(["dilo", "--toggle-post-process=dilo-code"]);
        assert_eq!(con_modo.toggle_post_process.as_deref(), Some("dilo-code"));

        let ausente = CliArgs::parse_from(["dilo"]);
        assert_eq!(ausente.toggle_post_process, None);
    }

    #[test]
    fn el_modo_no_se_come_la_bandera_siguiente() {
        // `require_equals` existe por esto: sin él, `num_args = 0..=1` haría
        // que `--toggle-post-process --debug` se tragara `--debug` como
        // nombre de modo.
        let args = CliArgs::parse_from(["dilo", "--toggle-post-process", "--debug"]);
        assert_eq!(args.toggle_post_process.as_deref(), Some(""));
        assert!(args.debug);
    }
}

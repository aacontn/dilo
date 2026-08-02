//! Stub para plataformas sin process taps de CoreAudio: Windows, Linux, y
//! macOS por debajo de 14.2 (ese caso no se resuelve acá porque es una
//! versión de macOS, no un target distinto — lo maneja `macos::open()` en
//! tiempo de ejecución; ver su comentario).
//!
//! Mismo contrato público que `macos::SystemAudioRecorder`: `open()` es el
//! único método que puede fallar, y falla con un error legible en vez de
//! entrar en pánico. `start()`/`stop()`/`close()` son no-ops seguros para que
//! un llamador que no revisó `open()` no se caiga igual.

use std::error::Error;
use std::fmt;

#[derive(Debug)]
struct NotAvailable;

impl fmt::Display for NotAvailable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "La captura de audio del sistema sólo está disponible en macOS 14.2 o superior"
        )
    }
}

impl Error for NotAvailable {}

pub struct SystemAudioRecorder;

impl SystemAudioRecorder {
    pub fn new() -> Result<Self, Box<dyn Error>> {
        Ok(SystemAudioRecorder)
    }

    pub fn open(&mut self) -> Result<(), Box<dyn Error>> {
        Err(Box::new(NotAvailable))
    }

    pub fn start(&self) -> Result<(), Box<dyn Error>> {
        Ok(())
    }

    pub fn stop(&self) -> Result<Vec<f32>, Box<dyn Error>> {
        Ok(Vec::new())
    }

    pub fn close(&mut self) -> Result<(), Box<dyn Error>> {
        Ok(())
    }
}

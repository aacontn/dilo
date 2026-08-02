//! Captura del audio que suena en el equipo (las voces de los demás en una
//! reunión de Meet/Zoom/Teams), no del micrófono.
//!
//! **Alcance de este módulo: sólo la captura, aislada.** Nadie lo llama
//! todavía — conectarlo al flujo de reuniones es una tarea posterior.
//!
//! ## Por qué process taps y no ScreenCaptureKit
//!
//! La vía elegida son los **process taps de CoreAudio** (macOS 14.2+), no
//! ScreenCaptureKit. Verificado inspeccionando Wispr Flow (que resuelve esto
//! en producción): no enlaza ScreenCaptureKit y declara
//! `NSAudioCaptureUsageDescription`. La ventaja frente a ScreenCaptureKit es
//! que pide **permiso de audio, no de grabación de pantalla** — sin el
//! indicador morado y mucho menos invasivo para transcribir una reunión.
//!
//! ## Forma de la API
//!
//! Espeja a propósito la de [`super::recorder::AudioRecorder`] (`new()`,
//! `open()`, `start()`, `stop()`) para que el código que la consuma después
//! no tenga que aprender un segundo modelo. Se aparta en dos puntos: no hay
//! parámetro de dispositivo en `open()` — un tap global no selecciona un
//! dispositivo de entrada, captura todo lo que suena en el equipo — y
//! `stop()` devuelve [`CaptureResult`] en vez de un `Vec<f32>` desnudo:
//! verificado contra hardware real, sin el permiso de captura concedido
//! CoreAudio no da ningún error, sólo entrega buffers del tamaño y la tasa
//! correctos llenos de cero digital exacto. Un `Vec<f32>` vacío o en
//! silencio no alcanza para que el llamador sepa si eso significa "sin
//! permiso" o "reunión silenciosa" — `CaptureResult::diagnosis` sí.
//!
//! ## Dónde vive cada cosa
//!
//! - Las funciones puras (mezcla a mono, cálculo de largo al remuestrear,
//!   mapeo de `OSStatus` a texto, parseo de versión de macOS) están al tope
//!   de este archivo, sin `cfg`, y tienen tests — mismo patrón que
//!   `popover.rs` separa la geometría pura de las llamadas al sistema.
//! - El cuerpo real que habla con CoreAudio vive en el submódulo `macos`,
//!   gateado con `#[cfg(target_os = "macos")]`.
//! - Windows/Linux y macOS < 14.2 usan el stub de más abajo: compila igual y
//!   `open()` devuelve un error legible en vez de entrar en pánico.

/// Cuántos canales por frame asume la mezcla a mono cuando CoreAudio entrega
/// el tap en un único buffer intercalado (el caso normal para un tap
/// stereo). Documentado acá porque `mix_interleaved_to_mono` es genérica en
/// el número de canales — este valor no se usa en el código, es la
/// referencia para quien lea los tests.
#[cfg(test)]
const STEREO_CHANNELS: usize = 2;

/// Mezcla a mono un buffer **intercalado** (`frame = channels` muestras
/// consecutivas, formato que CoreAudio entrega para un tap stereo en un solo
/// `AudioBuffer`). Misma técnica de promedio por frame que ya usa
/// `AudioRecorder::build_stream` para el micrófono — no es una segunda
/// implementación del mismo cálculo, es la única que existe en el árbol,
/// reutilizada acá porque el tap de audio del sistema no pasa por `cpal`.
///
/// Escribe en `out` (se limpia primero) en vez de devolver un `Vec` nuevo:
/// el callback de tiempo real que llama a esto (I1 del reporte) reutiliza un
/// buffer reciclado, así que esta función no puede ser la que fuerce una
/// asignación nueva en cada bloque.
///
/// `channels == 0` no puede ocurrir con datos reales de CoreAudio (un
/// `AudioBuffer` con cero canales no transporta nada); se trata como "sin
/// datos" en vez de dividir por cero.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn mix_interleaved_to_mono(samples: &[f32], channels: usize, out: &mut Vec<f32>) {
    out.clear();
    if channels == 0 {
        return;
    }
    if channels == 1 {
        out.extend_from_slice(samples);
        return;
    }

    for frame in samples.chunks_exact(channels) {
        let sum: f32 = frame.iter().sum();
        out.push(sum / channels as f32);
    }
}

/// Mezcla a mono N buffers **planos** (uno por canal, formato que CoreAudio
/// usaría si el tap entregara un `AudioBufferList` con más de un
/// `AudioBuffer` en vez del intercalado habitual). Se cubre por completitud —
/// el tap stereo que arma `open()` no debería producir este layout (y,
/// verificado con hardware real, no lo hace — ver I3 del reporte), pero si
/// CoreAudio lo hiciera, mejor mezclarlo bien que ignorar el audio en
/// silencio.
///
/// Escribe en `out` (se limpia primero) por la misma razón que
/// `mix_interleaved_to_mono`.
///
/// Trunca al canal más corto en vez de entrar en pánico si los buffers
/// llegaran con largos distintos (no debería pasar con audio real, pero un
/// dato inesperado del sistema no puede tumbar la captura).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn mix_planar_to_mono(channels: &[&[f32]], out: &mut Vec<f32>) {
    out.clear();
    match channels.len() {
        0 => {}
        1 => out.extend_from_slice(channels[0]),
        _ => {
            let frame_count = channels.iter().map(|c| c.len()).min().unwrap_or(0);
            let n = channels.len() as f32;
            out.extend((0..frame_count).map(|i| channels.iter().map(|c| c[i]).sum::<f32>() / n));
        }
    }
}

/// Cuántos frames produce remuestrear `input_frames` de `in_hz` a `out_hz`.
/// Pura, sin acceso a `rubato`: sirve para dimensionar buffers y para loguear
/// sin tener que instanciar un resampler. Redondea al entero más cercano,
/// igual que el cálculo de `frame_samples` en `FrameResampler::new`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn resampled_frame_count(input_frames: usize, in_hz: u32, out_hz: u32) -> usize {
    if in_hz == 0 {
        return 0;
    }
    ((input_frames as f64) * (out_hz as f64) / (in_hz as f64)).round() as usize
}

/// True si `samples` tiene al menos una muestra distinta de cero. Extraída
/// como función propia (I6 del reporte) para que el criterio de "esto es
/// exactamente silencio digital, no audio bajo" quede en un solo lugar
/// testeable, en vez de repetido inline en el hilo consumidor de `macos.rs`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn has_nonzero_sample(samples: &[f32]) -> bool {
    samples.iter().any(|&s| s != 0.0)
}

/// Convierte un `OSStatus` de CoreAudio a un mensaje legible en español. Los
/// códigos cubiertos son los que `AudioHardwareCreateProcessTap`,
/// `AudioHardwareCreateAggregateDevice`, `AudioObjectGetPropertyData` y
/// `AudioDeviceStart`/`Stop` documentan como posibles; cualquier otro cae al
/// formato genérico FourCC + valor numérico.
///
/// No importa `objc2_core_audio` a propósito — los valores están copiados de
/// ahí (`AudioHardware.rs`) como literales para que esta función, y su test,
/// compilen en cualquier plataforma sin el bloque `#[cfg(target_os =
/// "macos")]`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn describe_osstatus(status: i32) -> String {
    let known = match status {
        0 => Some("sin error"),
        0x73746f70 => Some("el dispositivo de audio no está corriendo (kAudioHardwareNotRunningError)"),
        0x77686174 => Some("error sin especificar de CoreAudio (kAudioHardwareUnspecifiedError)"),
        0x77686f3f => Some("propiedad desconocida (kAudioHardwareUnknownPropertyError)"),
        0x2173697a => Some("tamaño de propiedad inválido (kAudioHardwareBadPropertySizeError)"),
        0x6e6f7065 => Some("operación no permitida en este objeto (kAudioHardwareIllegalOperationError)"),
        0x216f626a => Some("AudioObjectID inválido (kAudioHardwareBadObjectError)"),
        0x21646576 => Some("AudioDeviceID inválido (kAudioHardwareBadDeviceError)"),
        0x21737472 => Some("AudioStreamID inválido (kAudioHardwareBadStreamError)"),
        0x756e6f70 => Some("operación no soportada por este dispositivo (kAudioHardwareUnsupportedOperationError)"),
        0x6e726479 => Some("el hardware de audio no está listo todavía (kAudioHardwareNotReadyError)"),
        0x21646174 => Some("formato de audio no soportado (kAudioDeviceUnsupportedFormatError)"),
        0x21686f67 => {
            Some("sin permiso de audio del sistema — falta autorizar la captura (kAudioDevicePermissionsError)")
        }
        _ => None,
    };

    match known {
        Some(msg) => format!("{msg} [{status}]"),
        None => format!("{} [{status}]", fourcc_or_numeric(status)),
    }
}

/// Intenta leer `status` como un código FourCC imprimible (la convención que
/// usa CoreAudio para casi todos sus `OSStatus`); si no son 4 bytes ASCII
/// imprimibles, devuelve sólo el valor numérico.
fn fourcc_or_numeric(status: i32) -> String {
    let bytes = status.to_be_bytes();
    if bytes.iter().all(|b| b.is_ascii_graphic()) {
        format!("código CoreAudio '{}'", String::from_utf8_lossy(&bytes))
    } else {
        format!("código CoreAudio {status}")
    }
}

/// True si esta versión de macOS soporta `AudioHardwareCreateProcessTap`
/// (disponible desde macOS 14.2, ver `CoreAudio/AudioHardwareTapping.h`).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn is_process_tap_available(major: u32, minor: u32) -> bool {
    (major, minor) >= (14, 2)
}

/// Parsea una versión estilo `ProductVersion` ("14.2.1", "15.0", "14") a
/// `(mayor, menor)`. `None` si el texto no empieza con un número.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn parse_macos_version(version: &str) -> Option<(u32, u32)> {
    let mut parts = version.trim().split('.');
    let major: u32 = parts.next()?.parse().ok()?;
    let minor: u32 = match parts.next() {
        Some(m) => m.parse().ok()?,
        None => 0,
    };
    Some((major, minor))
}

/// Resultado de `stop()`: las muestras a 16 kHz mono listas para el pipeline
/// de transcripción, más un diagnóstico de por qué podrían venir vacías o en
/// silencio (I6 del reporte — ver el comentario del módulo).
#[derive(Debug, Clone)]
pub struct CaptureResult {
    pub samples: Vec<f32>,
    pub diagnosis: CaptureDiagnosis,
}

/// Por qué `CaptureResult::samples` puede no traer audio útil. Verificado
/// contra hardware real: sin el permiso de captura de audio del sistema
/// concedido, CoreAudio no devuelve ningún `OSStatus` de error — crea el
/// tap, entrega buffers del tamaño y la tasa correctos, pero todos en cero
/// digital exacto. La única forma de distinguir eso de un silencio real es
/// cruzar "¿todo lo capturado fue exactamente cero?" con "¿había algo
/// sonando en el equipo en ese momento?".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureDiagnosis {
    /// Se capturó audio con contenido real (al menos una muestra distinta de
    /// cero en algún bloque de la sesión).
    AudioPresent,
    /// No se capturó ninguna muestra (por ejemplo, `stop()` sin `start()`
    /// previo, o una sesión demasiado corta).
    NoSamplesCaptured,
    /// Todo lo capturado es exactamente cero y había procesos reproduciendo
    /// audio en ese momento — la explicación más probable es que falte
    /// conceder el permiso de captura de audio del sistema.
    LikelyMissingPermission,
    /// Todo lo capturado es exactamente cero y no había nada sonando: es
    /// silencio real, no un problema de permisos.
    GenuineSilence,
    /// Todo lo capturado es exactamente cero pero no se pudo determinar si
    /// había procesos reproduciendo audio (falló la consulta a CoreAudio) —
    /// no se puede distinguir el caso.
    Undetermined,
}

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::SystemAudioRecorder;

#[cfg(not(target_os = "macos"))]
mod unsupported;
#[cfg(not(target_os = "macos"))]
pub use unsupported::SystemAudioRecorder;

#[cfg(test)]
mod tests {
    use super::*;

    // ---------- mix_interleaved_to_mono ----------------------------------

    #[test]
    fn mezcla_estereo_intercalado_a_mono() {
        // frames: (1,3) y (2,4) -> promedios 2.0 y 3.0
        let mut out = Vec::new();
        mix_interleaved_to_mono(&[1.0, 3.0, 2.0, 4.0], STEREO_CHANNELS, &mut out);
        assert_eq!(out, vec![2.0, 3.0]);
    }

    #[test]
    fn mono_intercalado_es_passthrough() {
        let mut out = Vec::new();
        mix_interleaved_to_mono(&[0.1, -0.2, 0.3], 1, &mut out);
        assert_eq!(out, vec![0.1, -0.2, 0.3]);
    }

    #[test]
    fn canales_en_cero_no_divide_por_cero() {
        let mut out = Vec::new();
        mix_interleaved_to_mono(&[1.0, 2.0], 0, &mut out);
        assert_eq!(out, Vec::<f32>::new());
    }

    #[test]
    fn intercalado_descarta_frame_incompleto() {
        // 5 muestras / 2 canales = 2 frames completos; el 5to elemento sobra.
        let mut out = Vec::new();
        mix_interleaved_to_mono(&[1.0, 1.0, 2.0, 2.0, 99.0], 2, &mut out);
        assert_eq!(out, vec![1.0, 2.0]);
    }

    #[test]
    fn intercalado_reutiliza_buffer_con_basura_previa() {
        // El callback de tiempo real (I1) le pasa a esta función un buffer
        // reciclado, no uno vacío recién creado — tiene que limpiarlo antes
        // de escribir, no sólo confiar en que venga vacío.
        let mut out = vec![99.0, 99.0, 99.0, 99.0, 99.0];
        mix_interleaved_to_mono(&[1.0, 3.0, 2.0, 4.0], STEREO_CHANNELS, &mut out);
        assert_eq!(out, vec![2.0, 3.0]);
    }

    // ---------- mix_planar_to_mono ----------------------------------------

    #[test]
    fn mezcla_planar_dos_canales() {
        let left = [1.0f32, 3.0];
        let right = [2.0f32, 4.0];
        let mut out = Vec::new();
        mix_planar_to_mono(&[&left, &right], &mut out);
        assert_eq!(out, vec![1.5, 3.5]);
    }

    #[test]
    fn planar_un_canal_es_passthrough() {
        let ch = [0.5f32, -0.5];
        let mut out = Vec::new();
        mix_planar_to_mono(&[&ch], &mut out);
        assert_eq!(out, vec![0.5, -0.5]);
    }

    #[test]
    fn planar_sin_canales_da_vacio() {
        let mut out = Vec::new();
        mix_planar_to_mono(&[], &mut out);
        assert!(out.is_empty());
    }

    #[test]
    fn planar_trunca_al_canal_mas_corto() {
        let left = [1.0f32, 1.0, 1.0];
        let right = [1.0f32]; // más corto, no debería pasar con audio real
        let mut out = Vec::new();
        mix_planar_to_mono(&[&left, &right], &mut out);
        assert_eq!(out, vec![1.0]);
    }

    #[test]
    fn planar_reutiliza_buffer_con_basura_previa() {
        let left = [1.0f32, 3.0];
        let right = [2.0f32, 4.0];
        let mut out = vec![99.0, 99.0, 99.0];
        mix_planar_to_mono(&[&left, &right], &mut out);
        assert_eq!(out, vec![1.5, 3.5]);
    }

    // ---------- has_nonzero_sample -----------------------------------------

    #[test]
    fn detecta_muestra_distinta_de_cero() {
        assert!(has_nonzero_sample(&[0.0, 0.0, 0.001, 0.0]));
    }

    #[test]
    fn todo_cero_no_tiene_muestra_distinta_de_cero() {
        assert!(!has_nonzero_sample(&[0.0, 0.0, 0.0]));
    }

    #[test]
    fn vacio_no_tiene_muestra_distinta_de_cero() {
        assert!(!has_nonzero_sample(&[]));
    }

    // ---------- resampled_frame_count --------------------------------------

    #[test]
    fn cuenta_frames_48k_a_16k() {
        assert_eq!(resampled_frame_count(48_000, 48_000, 16_000), 16_000);
    }

    #[test]
    fn cuenta_frames_passthrough_misma_tasa() {
        assert_eq!(resampled_frame_count(480, 16_000, 16_000), 480);
    }

    #[test]
    fn cuenta_frames_redondea() {
        // 1000 frames a 44100 -> 16000: 1000 * 16000 / 44100 = 362.86... -> 363
        assert_eq!(resampled_frame_count(1000, 44_100, 16_000), 363);
    }

    #[test]
    fn cuenta_frames_in_hz_cero_no_divide_por_cero() {
        assert_eq!(resampled_frame_count(1000, 0, 16_000), 0);
    }

    // ---------- describe_osstatus -------------------------------------------

    #[test]
    fn sin_error_se_reconoce() {
        assert!(describe_osstatus(0).contains("sin error"));
    }

    #[test]
    fn error_de_permisos_se_reconoce() {
        let msg = describe_osstatus(0x21686f67);
        assert!(msg.to_lowercase().contains("permiso"));
    }

    #[test]
    fn error_no_soportado_se_reconoce() {
        let msg = describe_osstatus(0x756e6f70);
        assert!(msg.contains("kAudioHardwareUnsupportedOperationError"));
    }

    #[test]
    fn codigo_desconocido_cae_a_fourcc() {
        // 'test' en FourCC, no está en la tabla: debe mostrar el fourcc y el número.
        let status = i32::from_be_bytes(*b"test");
        let msg = describe_osstatus(status);
        assert!(msg.contains("test"), "mensaje: {msg}");
        assert!(msg.contains(&status.to_string()), "mensaje: {msg}");
    }

    #[test]
    fn codigo_no_imprimible_muestra_solo_el_numero() {
        let msg = describe_osstatus(-1);
        assert!(msg.contains("-1"));
    }

    // ---------- is_process_tap_available / parse_macos_version -------------

    #[test]
    fn disponible_desde_14_2() {
        assert!(is_process_tap_available(14, 2));
        assert!(is_process_tap_available(14, 3));
        assert!(is_process_tap_available(15, 0));
        assert!(is_process_tap_available(20, 0));
    }

    #[test]
    fn no_disponible_antes_de_14_2() {
        assert!(!is_process_tap_available(14, 1));
        assert!(!is_process_tap_available(13, 9));
        assert!(!is_process_tap_available(10, 15));
    }

    #[test]
    fn parsea_version_con_patch() {
        assert_eq!(parse_macos_version("14.2.1"), Some((14, 2)));
    }

    #[test]
    fn parsea_version_sin_minor() {
        assert_eq!(parse_macos_version("14"), Some((14, 0)));
    }

    #[test]
    fn version_invalida_da_none() {
        assert_eq!(parse_macos_version(""), None);
        assert_eq!(parse_macos_version("catorce.dos"), None);
    }
}

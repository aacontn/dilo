//! Implementación real: process taps de CoreAudio (macOS 14.2+).
//!
//! ## Cómo encajan las piezas de CoreAudio
//!
//! 1. `CATapDescription` describe QUÉ capturar. Acá pedimos un tap **global**
//!    (`initStereoGlobalTapButExcludeProcesses` con la lista de exclusión
//!    vacía = todos los procesos), mezclado a stereo por CoreAudio — la
//!    mezcla final a mono es nuestra (`mix_interleaved_to_mono`), no de
//!    CATapDescription, para que quede en una función pura testeable.
//! 2. `AudioHardwareCreateProcessTap` crea el tap a partir de esa
//!    descripción y devuelve un `AudioObjectID`.
//! 3. Un tap solo no es un dispositivo de audio: hace falta envolverlo en un
//!    **dispositivo agregado** (`AudioHardwareCreateAggregateDevice`) que
//!    combina el tap con un sub-dispositivo real (el de salida por defecto)
//!    para heredar su reloj — el patrón documentado por Apple y el mismo que
//!    usa AudioCap (github.com/insidegui/AudioCap), la referencia de código
//!    abierto más citada para esta API.
//! 4. `AudioDeviceCreateIOProcID` registra la función C que CoreAudio llama
//!    en su hilo de tiempo real con cada bloque de audio.
//! 5. `AudioDeviceStart`/`AudioDeviceStop` prenden y apagan la entrega de
//!    audio sin recrear nada de lo anterior — así `stop()` seguido de
//!    `start()` nunca duplica un tap (requisito de la tarea): la creación de
//!    recursos vive únicamente en `open()`.
//!
//! ## Hilo consumidor, remuestreo en línea (I4) y la barrera de `stop()`
//!
//! El callback de CoreAudio (`tap_io_proc`) corre en el hilo de tiempo real
//! del propio CoreAudio: sólo hace la mezcla a mono (barata) y un
//! `Sender::send` no bloqueante, igual que `AudioRecorder::build_stream` hace
//! con el micrófono ("keep the callback cheap"). Un hilo consumidor aparte
//! recibe esos bloques y los remuestrea a 16 kHz **a medida que llegan**
//! (mismo patrón que `AudioRecorder::run_consumer` usa para el micrófono):
//! antes, este módulo acumulaba la reunión entera a la tasa nativa (48 kHz)
//! y remuestreaba todo junto en `stop()` — ~690 MB/hora residentes con un
//! pico del doble por el realloc, y un `stop()` que bloqueaba segundos. Ahora
//! `buffer` guarda directamente las muestras ya remuestreadas a 16 kHz, y
//! `stop()` sólo drena lo que el hilo consumidor ya produjo.
//!
//! `AudioDeviceStop` documenta que, cuando retorna, el IOProc no vuelve a
//! llamarse — pero el hilo consumidor puede ir un paso atrás del canal en
//! ese instante. Por eso `stop()` manda un mensaje `Msg::Barrier` **después**
//! de `AudioDeviceStop` y espera su ack: como ambos productores (el IOProc y
//! `stop()`) escriben al mismo `mpsc::Sender` clonado, el orden FIFO del
//! canal garantiza que la barrera llega después de toda la audio pendiente.
//! Al recibir la barrera, el hilo consumidor llama `FrameResampler::finish()`
//! (para no perder la cola del remuestreo) y después `reset()` (para que la
//! siguiente sesión de grabación, si la hay antes de `close()`, no arranque
//! con las colas FFT de la anterior — el mismo riesgo de "crosstalk" que
//! `resampler.rs` prueba explícitamente) antes de confirmar la barrera. Es la
//! misma garantía de "no perder el último bloque" que
//! `AudioRecorder::run_consumer` logra con su sentinela `EndOfStream`, pero
//! más simple acá porque `AudioDeviceStop` ya da el corte limpio que cpal no
//! ofrece.
//!
//! ## Reciclaje de buffers en el callback de tiempo real (I1)
//!
//! `tap_io_proc` corre en el hilo de tiempo real de CoreAudio, donde pedir
//! memoria al sistema puede provocar cortes audibles — y durante una reunión
//! corre en paralelo con el callback de `cpal` del micrófono, duplicando esa
//! presión sobre el allocator en dos hilos de tiempo real a la vez. El hilo
//! consumidor devuelve cada `Vec<f32>` ya vacío por un canal de reciclaje
//! (`IoProcContext::free_rx`) después de consumirlo; el callback intenta
//! sacar uno de ahí antes de construir uno nuevo, así que en régimen
//! permanente no pide memoria nueva para la mezcla a mono. El primer puñado
//! de bloques (antes de que el reciclaje se ponga al día) sí asigna, igual
//! que hoy. Lo que **no** se eliminó: `mpsc::Sender::send` sigue asignando un
//! nodo por mensaje — es una limitación del canal de `std::sync::mpsc`, no
//! del tamaño del buffer, y es el mismo patrón que ya usa
//! `AudioRecorder::build_stream` para el micrófono en este mismo árbol.
//! Reemplazarlo por un ring buffer sin asignaciones es factible pero es
//! infraestructura nueva de concurrencia de bajo nivel en un camino de
//! tiempo real crítico para audio — se juzgó que el riesgo de un bug ahí no
//! se paga con la ganancia marginal frente al nodo, ya fijo y pequeño, del
//! canal.
//!
//! ## Diagnóstico de silencio (I6)
//!
//! Verificado contra hardware real: **sin el permiso de captura de audio del
//! sistema concedido, CoreAudio no devuelve ningún error.** Crea el tap,
//! acepta el dispositivo agregado, entrega buffers del tamaño y la tasa
//! correctos — todos en cero digital exacto. `stop()` no puede seguir
//! devolviendo sólo un `Vec<f32>`: un archivo mudo por falta de permiso y un
//! archivo mudo porque la reunión estaba en silencio real se ven
//! idénticos. Por eso ahora devuelve [`CaptureResult`], que además de las
//! muestras trae un [`CaptureDiagnosis`]. La señal que distingue los dos
//! casos es cruzar "¿todo lo capturado es exactamente cero?" (se seguía en
//! vivo, en el hilo consumidor, con `has_nonzero_sample` sobre cada bloque
//! *antes* de remuestrear — el remuestreo de puro cero también da cero, pero
//! confiar en eso sería confiar en un detalle de implementación de FFT) con
//! "¿había algún proceso reproduciendo audio en ese momento?"
//! (`any_process_playing_audio`, vía `kAudioHardwarePropertyProcessObjectList`
//! y `kAudioProcessPropertyIsRunningOutput` — no existe una consulta pública
//! y estable al estado de TCC para este permiso, así que esta heurística es
//! el camino).
//!
//! ## Cambio de dispositivo de salida en caliente (I5)
//!
//! `open()` fija el UID del dispositivo de salida por defecto en el momento
//! de construir el dispositivo agregado. Si el usuario cambia de salida a
//! mitad de reunión (por ejemplo, conecta AirPods), el agregado sigue
//! apuntando al dispositivo viejo — que puede haber desaparecido — y la
//! captura queda muda sin ningún error. Reconstruir el agregado en caliente
//! (destruir sub-dispositivo/tap-list y recrearlos con el nuevo UID mientras
//! el IOProc puede estar corriendo) es frágil: no hay garantía de que
//! CoreAudio no deje el agregado en un estado a medias si el cambio ocurre
//! entre la creación y el primer `AudioDeviceStart`, y el costo de acertar
//! esa máquina de estados no se paga solo para evitar avisar. Este módulo
//! registra un listener sobre `kAudioHardwarePropertyDefaultOutputDevice` con
//! `AudioObjectAddPropertyListener` (variante de función C, no de bloque —
//! mismo estilo que ya usa `tap_io_proc`, sin sumar `block2`/`dispatch2`
//! como dependencias directas) y sólo levanta una bandera
//! (`output_device_changed()`); el llamador decide si avisa al usuario o
//! cierra y reabre para reconstruir contra el dispositivo nuevo. Quedarse
//! mudo sin decir nada, que era el comportamiento anterior, no es aceptable.
//!
//! ## Seguimiento: fallo total de lectura, diagnóstico en caliente y decisión testeable
//!
//! Tres hallazgos "Important" de la revisión de seguimiento tocan esta parte:
//!
//! - **Fallo total de `any_process_playing_audio()` (Important 1).** El
//!   `unwrap_or(0)` por proceso sigue siendo correcto para uno que murió
//!   entre enumerarlo y leerlo, pero si **todas** las lecturas fallaran (un
//!   selector que dejara de estar soportado en una macOS futura, por
//!   ejemplo) la función devolvía `Ok(false)` — "nadie reproduce nada" —
//!   cuando en realidad no se pudo preguntar. Ahora cuenta lecturas exitosas
//!   aparte del resultado: sin ninguna, devuelve `Err`, que el llamador
//!   traduce a `CaptureDiagnosis::Undetermined` en vez de a un falso
//!   "silencio real" (la inversión exacta de la señal que este mecanismo
//!   existe para dar).
//! - **Diagnóstico consultable en caliente (Important 2).** `stop()`
//!   calculaba el diagnóstico una sola vez, al final — en una reunión larga
//!   el usuario se enteraba recién al colgar. `diagnose_now()` expone la
//!   misma lógica de sólo lectura (no consume `buffer`, no resetea
//!   `saw_nonzero`) para que el llamador pueda sondear cada tanto durante la
//!   grabación y avisar a tiempo. Llamarlo muy temprano, antes de que llegue
//!   el primer bloque, puede dar legítimamente `NoSamplesCaptured` — no es un
//!   error.
//! - **Decisión testeable (Important 3).** El árbol de decisión (vacío → sin
//!   muestras; alguna muestra no-cero → hay audio; si no, cruzar con
//!   `any_process_playing_audio()`) vivía inline en `stop()`, gateado por
//!   `#[cfg(target_os = "macos")]`, sin tests. Ahora es
//!   [`super::diagnose`], función pura en `system_audio.rs` sin `cfg`, con
//!   sus cinco casos cubiertos por test. `stop()` y `diagnose_now()`
//!   comparten `compute_diagnosis()` (más abajo) para llamarla igual.
//!
//! Además (Important 4): si desregistrar el listener de I5 falla en
//! `close()`, ya no se libera igual el `Box` al que apunta — se filtra a
//! propósito (`Box::leak`) para evitar un use-after-free en un hilo de la
//! HAL de CoreAudio si un callback llegara a mitad de camino. Y `LeakGuard`
//! (M6) ahora también desregistra ese listener cuando ya estaba registrado
//! en el momento de armarse, no sólo el tap/agregado/IOProc — ver el
//! comentario sobre orden de declaración en `finish_open_with_aggregate`.
//!
//! ## Cableado a reuniones: `with_frame_callback` y `system_audio_available`
//!
//! Este módulo seguía sin que nadie lo llamara desde el flujo de reuniones.
//! `with_frame_callback` cierra ese hueco entregando, en vivo y en el mismo
//! hilo consumidor descrito arriba, cada frame de 16 kHz ya remuestreado —
//! antes de esto sólo existía el camino por lotes (`start()`/`stop()` con
//! todo junto al final). El callback se llama en el mismo punto donde antes
//! sólo se escribía en `buffer`, y sigue escribiendo ahí también: `stop()` y
//! `diagnose_now()` no cambiaron. `system_audio_available()` expone en
//! caliente la misma condición de plataforma que `open()` ya verificaba
//! (macOS 14.2+) para que el ajuste de fuente de audio de reuniones pueda
//! resolverse sin intentar abrir una sesión primero.

use std::error::Error;
use std::ffi::{c_void, CString};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use objc2::AnyThread;
use objc2_core_audio::{
    kAudioAggregateDeviceIsPrivateKey, kAudioAggregateDeviceIsStackedKey,
    kAudioAggregateDeviceNameKey, kAudioAggregateDeviceSubDeviceListKey,
    kAudioAggregateDeviceTapAutoStartKey, kAudioAggregateDeviceTapListKey,
    kAudioAggregateDeviceUIDKey, kAudioDevicePropertyDeviceUID,
    kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList,
    kAudioObjectPropertyElementMain, kAudioObjectPropertyScopeGlobal, kAudioObjectSystemObject,
    kAudioProcessPropertyIsRunningOutput, kAudioSubDeviceUIDKey, kAudioSubTapDriftCompensationKey,
    kAudioSubTapUIDKey, kAudioTapPropertyFormat, kAudioTapPropertyUID, AudioDeviceCreateIOProcID,
    AudioDeviceDestroyIOProcID, AudioDeviceIOProcID, AudioDeviceStart, AudioDeviceStop,
    AudioHardwareCreateAggregateDevice, AudioHardwareCreateProcessTap,
    AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap,
    AudioObjectAddPropertyListener, AudioObjectGetPropertyData, AudioObjectGetPropertyDataSize,
    AudioObjectID, AudioObjectPropertyAddress, AudioObjectRemovePropertyListener, CATapDescription,
    CATapMuteBehavior,
};
use objc2_core_audio_types::{
    kAudioFormatFlagIsFloat, kAudioFormatLinearPCM, AudioBufferList, AudioStreamBasicDescription,
    AudioTimeStamp,
};
use objc2_core_foundation::{CFArray, CFBoolean, CFDictionary, CFRetained, CFString, CFType};
use objc2_foundation::{NSArray, NSNumber};

use super::{
    describe_osstatus, diagnose, has_nonzero_sample, is_process_tap_available,
    mix_interleaved_to_mono, mix_planar_to_mono, parse_macos_version, resampled_frame_count,
    CaptureDiagnosis, CaptureResult,
};
use crate::audio_toolkit::{audio::FrameResampler, constants};

/// Mensajes que fluyen por el único canal que comparten el callback de
/// CoreAudio (productor de `Audio`) y `stop()` (productor de `Barrier`). Ver
/// el comentario del módulo para por qué comparten canal.
enum Msg {
    Audio(Vec<f32>),
    Barrier(mpsc::Sender<()>),
}

struct IoProcContext {
    tx: mpsc::Sender<Msg>,
    /// Buffers ya vacíos que el hilo consumidor devuelve para reciclar (I1,
    /// ver el comentario del módulo). Sólo el hilo de CoreAudio que llama a
    /// `tap_io_proc` saca de acá — es exactamente el uso de "un solo
    /// consumidor" para el que está pensado `mpsc::Receiver`, aunque el
    /// acceso pase por un puntero crudo en vez de por el tipo Rust normal
    /// (ver la nota de seguridad de `tap_io_proc`).
    free_rx: mpsc::Receiver<Vec<f32>>,
}

/// Contexto del listener de cambio de dispositivo de salida (I5). Vive en su
/// propio `Box`, separado de `IoProcContext`, porque CoreAudio lo llama por
/// una API distinta (`AudioObjectAddPropertyListener`, no un IOProc) con su
/// propio ciclo de vida de registro/desregistro.
struct OutputDeviceListenerContext {
    changed: Arc<AtomicBool>,
}

/// Callback en vivo de `with_frame_callback` — mismo tipo, sin nombrarlo así,
/// que `audio_toolkit::audio::recorder::AudioFrameCallback` (no se reusa ese
/// alias directamente para no crear una dependencia de `system_audio` hacia
/// el módulo del micrófono sólo por un tipo).
type FrameCallback = Arc<dyn Fn(&[f32]) + Send + Sync + 'static>;

/// Captura del audio del sistema vía process taps de CoreAudio — ver el
/// comentario del módulo para el diseño completo.
///
/// `start()`/`stop()` toman `&self`, no `&mut self`, lo que puede sugerir que
/// es seguro compartirlo entre hilos sin más cuidado. No lo es (M9 del
/// reporte de seguimiento): `ctx` guarda un `mpsc::Receiver<Vec<f32>>`
/// (`free_rx`, dentro de `IoProcContext`), y `Receiver` no es `Sync` — eso
/// alcanza para que todo `SystemAudioRecorder` sea `!Sync`. Quien lo cablee
/// a un flujo con más de un hilo (por ejemplo, un comando de Tauri que corre
/// en el pool async y un callback que corre en otro) va a necesitar
/// envolverlo en un `Mutex` igual que hace `AudioRecorder` con sus propios
/// canales.
pub struct SystemAudioRecorder {
    tap_id: Option<AudioObjectID>,
    aggregate_device_id: Option<AudioObjectID>,
    /// `AudioDeviceIOProcID` ya es un `Option` internamente (alias de
    /// `AudioDeviceIOProc`) — `None` es "sin IOProc registrado", no hace
    /// falta envolverlo en un segundo `Option`.
    io_proc_id: AudioDeviceIOProcID,
    /// Vive mientras el IOProc está registrado: `client_data` apunta adentro
    /// de este `Box`. Se suelta en `close()`, después de desregistrar el
    /// IOProc — nunca antes.
    ctx: Option<Box<IoProcContext>>,
    cmd_tx: Option<mpsc::Sender<Msg>>,
    consumer: Option<std::thread::JoinHandle<()>>,
    /// Muestras a 16 kHz mono ya remuestreadas por el hilo consumidor (I4) —
    /// no la tasa nativa del tap.
    buffer: Arc<Mutex<Vec<f32>>>,
    /// Tasa de muestreo nativa del tap (la que reporta
    /// `kAudioTapPropertyFormat`), no necesariamente 48 kHz. Sólo se usa para
    /// configurar el `FrameResampler` del hilo consumidor; se expone por
    /// `native_sample_rate()` para diagnóstico.
    native_rate: u32,
    running: AtomicBool,
    /// True si algún bloque de la sesión de grabación actual trajo alguna
    /// muestra distinta de cero (I6). Se resetea en cada `stop()`.
    saw_nonzero: Arc<AtomicBool>,
    /// True si `kAudioHardwarePropertyDefaultOutputDevice` cambió desde
    /// `open()` (I5). Ver `output_device_changed()`.
    output_device_changed: Arc<AtomicBool>,
    output_listener_ctx: Option<Box<OutputDeviceListenerContext>>,
    /// Callback en vivo para el flujo de reuniones (tarea de cableado): ver
    /// `with_frame_callback`. `None` hasta que se registre uno — `stop()`
    /// sigue funcionando igual sin él, drenando `buffer` como siempre.
    frame_cb: Option<FrameCallback>,
}

impl SystemAudioRecorder {
    pub fn new() -> Result<Self, Box<dyn Error>> {
        Ok(Self {
            tap_id: None,
            aggregate_device_id: None,
            io_proc_id: None,
            ctx: None,
            cmd_tx: None,
            consumer: None,
            buffer: Arc::new(Mutex::new(Vec::new())),
            native_rate: 0,
            running: AtomicBool::new(false),
            saw_nonzero: Arc::new(AtomicBool::new(false)),
            output_device_changed: Arc::new(AtomicBool::new(false)),
            output_listener_ctx: None,
            frame_cb: None,
        })
    }

    /// Registra un callback que recibe cada frame de 16 kHz mono **en
    /// vivo**, a medida que el hilo consumidor los remuestrea — misma forma
    /// y mismas garantías que `AudioRecorder::with_audio_callback` (en
    /// orden, en el hilo consumidor, barato: ver el comentario del módulo
    /// sobre "keep the callback cheap"). A diferencia del callback del
    /// micrófono, éste entrega las muestras **sin filtrar por VAD**: este
    /// módulo no tiene ningún VAD propio (el del micrófono vive adentro de
    /// `AudioRecorder`). Quien necesite el mismo corte por voz que el
    /// micrófono debe aplicar su propio VAD sobre estas muestras antes de
    /// usarlas — ver `managers/meeting.rs::build_meeting_system_audio_recorder`.
    ///
    /// Debe llamarse ANTES de `open()`: `open()` clona esta referencia hacia
    /// el hilo consumidor que crea, así que registrarlo después de abrir la
    /// sesión no tiene efecto.
    pub fn with_frame_callback<F>(mut self, cb: F) -> Self
    where
        F: Fn(&[f32]) + Send + Sync + 'static,
    {
        self.frame_cb = Some(Arc::new(cb));
        self
    }

    pub fn open(&mut self) -> Result<(), Box<dyn Error>> {
        if self.aggregate_device_id.is_some() {
            return Ok(()); // ya está abierto, igual que AudioRecorder::open
        }

        let (major, minor) = macos_version().ok_or_else(|| {
            core_audio_error("no se pudo determinar la versión de macOS instalada")
        })?;
        if !is_process_tap_available(major, minor) {
            return Err(core_audio_error(&format!(
                "la captura de audio del sistema necesita macOS 14.2 o superior (esta máquina tiene {major}.{minor})"
            )));
        }

        // Tap global: lista de exclusión vacía = todos los procesos.
        let exclude = NSArray::<NSNumber>::from_slice(&[]);
        let description = unsafe {
            CATapDescription::initStereoGlobalTapButExcludeProcesses(
                CATapDescription::alloc(),
                &exclude,
            )
        };
        unsafe {
            description.setPrivate(true);
            // Nunca silenciar al proceso tapeado: el usuario tiene que
            // seguir escuchando la reunión por sus parlantes/audífonos.
            description.setMuteBehavior(CATapMuteBehavior::Unmuted);
        }

        let mut tap_id: AudioObjectID = 0;
        let status = unsafe { AudioHardwareCreateProcessTap(Some(&description), &mut tap_id) };
        check_osstatus(status, "AudioHardwareCreateProcessTap")?;

        // A partir de acá hay un recurso del sistema vivo: cualquier `?` que
        // siga debe destruirlo antes de propagar el error, para no dejar un
        // tap colgando en CoreAudio.
        let result = self.finish_open(tap_id);
        if result.is_err() {
            unsafe { AudioHardwareDestroyProcessTap(tap_id) };
        }
        result
    }

    fn finish_open(&mut self, tap_id: AudioObjectID) -> Result<(), Box<dyn Error>> {
        let format = tap_stream_format(tap_id)?;
        if format.mFormatID != kAudioFormatLinearPCM
            || format.mFormatFlags & kAudioFormatFlagIsFloat == 0
        {
            return Err(core_audio_error(&format!(
                "formato de tap inesperado (mFormatID={:#x}, mFormatFlags={:#x}) — se esperaba Float32 lineal",
                format.mFormatID, format.mFormatFlags
            )));
        }
        // M7 (reporte de seguimiento): con tasa 0, `FrameResampler::new`
        // (más abajo, en el hilo consumidor) panickea al construir el
        // `FftFixedIn` de rubato — y lo hace en ESE hilo, que muere en
        // silencio mientras `open()` ya devolvió `Ok`. Todo `send` posterior
        // sigue "funcionando" (el canal no se cierra por un panic en el otro
        // extremo hasta que se intenta drenarlo), así que el síntoma visible
        // es sólo que `stop()` termina reportando `NoSamplesCaptured` sin
        // ninguna pista de por qué. Se valida acá, junto al resto del
        // formato, para fallar `open()` con un mensaje legible en vez de
        // eso.
        if format.mSampleRate <= 0.0 {
            return Err(core_audio_error(&format!(
                "el tap reportó una tasa de muestreo inválida ({})",
                format.mSampleRate
            )));
        }

        let tap_uid = tap_property_uid(tap_id)?;
        let output_device_id = default_output_device_id()?;
        let output_uid = device_uid(output_device_id)?;
        let aggregate_uid = format!("com.dilo.system-audio-tap.{}", unique_suffix());
        let description_dict =
            build_aggregate_device_description(&aggregate_uid, &output_uid, &tap_uid);

        let mut aggregate_device_id: AudioObjectID = 0;
        let status = unsafe {
            AudioHardwareCreateAggregateDevice(
                &description_dict,
                NonNull::from(&mut aggregate_device_id),
            )
        };
        check_osstatus(status, "AudioHardwareCreateAggregateDevice")?;

        let result =
            self.finish_open_with_aggregate(tap_id, aggregate_device_id, format.mSampleRate);
        if result.is_err() {
            unsafe { AudioHardwareDestroyAggregateDevice(aggregate_device_id) };
        }
        result
    }

    fn finish_open_with_aggregate(
        &mut self,
        tap_id: AudioObjectID,
        aggregate_device_id: AudioObjectID,
        sample_rate: f64,
    ) -> Result<(), Box<dyn Error>> {
        let (tx, rx) = mpsc::channel::<Msg>();
        let (free_tx, free_rx) = mpsc::channel::<Vec<f32>>();
        let ctx = Box::new(IoProcContext {
            tx: tx.clone(),
            free_rx,
        });
        // SAFETY: `ctx` se mueve a `self.ctx` más abajo sin reubicar su
        // contenido (mover un `Box` no mueve lo que apunta) — este puntero
        // sigue siendo válido mientras `self.ctx` exista. Se destruye el
        // registro del IOProc (`AudioDeviceDestroyIOProcID`) en `close()`
        // antes de soltar `self.ctx`, así que CoreAudio nunca ve el puntero
        // después de que deja de ser válido.
        let client_data = std::ptr::addr_of!(*ctx) as *mut c_void;

        let mut io_proc_id: AudioDeviceIOProcID = None;
        let status = unsafe {
            AudioDeviceCreateIOProcID(
                aggregate_device_id,
                Some(tap_io_proc),
                client_data,
                NonNull::from(&mut io_proc_id),
            )
        };
        check_osstatus(status, "AudioDeviceCreateIOProcID")?;

        // I5: listener de cambio de dispositivo de salida por defecto — ver
        // el comentario del módulo. Un fallo acá no aborta `open()`: se
        // pierde la detección del cambio, pero la captura en sí sigue
        // siendo funcional. Se registra ACÁ, antes del guard M6 de más
        // abajo y del `std::thread::spawn` que sigue, a propósito: así el
        // guard, que se arma después, también lo cubre si el spawn
        // panickea (ver el comentario de `LeakGuard` más abajo sobre por
        // qué el orden de declaración de `output_listener_ctx` frente al
        // guard importa).
        let output_device_changed = Arc::new(AtomicBool::new(false));
        let output_listener_ctx = Box::new(OutputDeviceListenerContext {
            changed: Arc::clone(&output_device_changed),
        });
        let listener_client_data = std::ptr::addr_of!(*output_listener_ctx) as *mut c_void;
        let output_device_address = AudioObjectPropertyAddress {
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        };
        let listener_status = unsafe {
            AudioObjectAddPropertyListener(
                kAudioObjectSystemObject as AudioObjectID,
                NonNull::from(&output_device_address),
                Some(output_device_listener),
                listener_client_data,
            )
        };
        // `output_listener_ctx` se queda `Some` sólo si CoreAudio confirmó el
        // registro — en el `else` el `Box` no llegó a registrarse en ningún
        // lado, así que dropearlo (al salir de este `if`/`else` sin moverlo)
        // es completamente seguro, no hay ningún puntero vivo apuntando ahí.
        let (output_listener_ctx, output_listener_client_data) = if listener_status == 0 {
            (Some(output_listener_ctx), Some(listener_client_data))
        } else {
            log::warn!(
                "no se pudo registrar el listener de cambio de dispositivo de salida: {}",
                describe_osstatus(listener_status)
            );
            (None, None)
        };

        // Guard M6: a partir de acá el tap, el agregado, el IOProc y (si se
        // registró) el listener de I5 ya existen como recursos vivos en
        // CoreAudio, pero todavía no están guardados en `self` — si algo
        // entre acá y el final de la función *panickea* en vez de devolver
        // `Err` (el único candidato es `std::thread::spawn`, que panickea si
        // el sistema operativo no puede crear el hilo), ni el `Drop` de
        // `SystemAudioRecorder` (no sabe de estos recursos todavía) ni el
        // manejo de `Err` de más arriba (espera un `Result`, no un unwind)
        // los liberan: quedan colgados en el sistema del usuario hasta que
        // reinicie. El guard cubre ese hueco y se desarma justo antes del
        // único `return` normal de la función, así que en el camino feliz
        // no hace nada de más.
        //
        // Orden de declaración (Minor del reporte de seguimiento): `ctx` y
        // `output_listener_ctx` están declarados ANTES que `leak_guard` a
        // propósito. Las variables locales se destruyen en orden inverso de
        // declaración, así que si el `thread::spawn` de más abajo
        // panickea, `leak_guard` (declarado después) se destruye PRIMERO —
        // desregistrando el IOProc y el listener en CoreAudio — y recién
        // DESPUÉS se liberan las cajas `ctx`/`output_listener_ctx` a las que
        // esos callbacks apuntaban. Invertir este orden reabriría un
        // use-after-free en un hilo de la HAL: no reordenar estas
        // declaraciones sin mover también la del guard.
        let mut leak_guard = LeakGuard {
            tap_id,
            aggregate_device_id,
            io_proc_id,
            output_listener_client_data,
            armed: true,
        };

        let native_rate = sample_rate.round() as u32;
        let buffer = Arc::new(Mutex::new(Vec::<f32>::new()));
        let consumer_buffer = Arc::clone(&buffer);
        let saw_nonzero = Arc::new(AtomicBool::new(false));
        let consumer_saw_nonzero = Arc::clone(&saw_nonzero);
        let frame_cb = self.frame_cb.clone();

        let consumer = std::thread::spawn(move || {
            // I4: el remuestreo a 16 kHz vive acá, no en `stop()` — así el
            // buffer compartido nunca guarda más que la sesión ya reducida a
            // 16 kHz, y `stop()` no tiene que remuestrear la reunión entera
            // de una sola vez.
            let mut resampler = FrameResampler::new(
                native_rate as usize,
                constants::WHISPER_SAMPLE_RATE as usize,
                Duration::from_millis(30),
            );
            while let Ok(msg) = rx.recv() {
                match msg {
                    Msg::Audio(samples) => {
                        // I6: si algún bloque de esta sesión trae algo
                        // distinto de cero, ya no puede tratarse de "sin
                        // permiso" — se registra apenas se ve la primera
                        // muestra no-cero para no tener que releer toda la
                        // sesión después.
                        if !consumer_saw_nonzero.load(Ordering::Relaxed)
                            && has_nonzero_sample(&samples)
                        {
                            consumer_saw_nonzero.store(true, Ordering::Relaxed);
                        }
                        {
                            let mut buf = consumer_buffer.lock().unwrap();
                            buf.reserve(resampled_frame_count(
                                samples.len(),
                                native_rate,
                                constants::WHISPER_SAMPLE_RATE,
                            ));
                        }
                        // El callback en vivo (cableado a reuniones) se
                        // llama SIN el lock de `buffer` tomado — sólo se
                        // toma, por frame, para el `extend_from_slice`. Si
                        // se llamara con el lock puesto, cualquier trabajo
                        // que haga el callback (acá, VAD + push a un
                        // acumulador de turnos, ver `managers/meeting.rs`)
                        // quedaría corriendo con `buffer` tomado, compitiendo
                        // con `stop()`/`diagnose_now()` sin necesidad: nada
                        // de eso depende de tener el lock durante el
                        // callback, así que no vale la pena arriesgarlo.
                        resampler.push(&samples, |frame| {
                            if let Some(cb) = &frame_cb {
                                cb(frame);
                            }
                            consumer_buffer.lock().unwrap().extend_from_slice(frame);
                        });
                        // I1: se devuelve para reciclar en vez de dejar que
                        // el `Vec` simplemente se libere — el próximo
                        // `tap_io_proc` lo reutiliza en vez de pedir memoria
                        // nueva. Si el receptor ya se soltó (cerrando), esto
                        // no hace nada distinto de dropear el `Vec`.
                        let _ = free_tx.send(samples);
                    }
                    Msg::Barrier(ack) => {
                        resampler.finish(|frame| {
                            if let Some(cb) = &frame_cb {
                                cb(frame);
                            }
                            consumer_buffer.lock().unwrap().extend_from_slice(frame);
                        });
                        // Limpia las colas FFT antes de la próxima sesión
                        // (stop() seguido de otro start() sin pasar por
                        // close()) para que no haya crosstalk entre
                        // grabaciones — mismo riesgo que
                        // `FrameResampler::reset` documenta y prueba.
                        resampler.reset();
                        let _ = ack.send(());
                    }
                }
            }
        });

        self.tap_id = Some(tap_id);
        self.aggregate_device_id = Some(aggregate_device_id);
        self.io_proc_id = io_proc_id;
        self.ctx = Some(ctx);
        self.cmd_tx = Some(tx);
        self.consumer = Some(consumer);
        self.buffer = buffer;
        self.native_rate = native_rate;
        self.saw_nonzero = saw_nonzero;
        self.output_device_changed = output_device_changed;
        self.output_listener_ctx = output_listener_ctx;
        leak_guard.armed = false;
        Ok(())
    }

    pub fn start(&self) -> Result<(), Box<dyn Error>> {
        let (Some(device_id), Some(io_proc_id)) = (self.aggregate_device_id, self.io_proc_id)
        else {
            return Err(core_audio_error("start() llamado antes de open()"));
        };
        if self.running.swap(true, Ordering::SeqCst) {
            return Ok(()); // ya estaba corriendo
        }
        let status = unsafe { AudioDeviceStart(device_id, Some(io_proc_id)) };
        if let Err(e) = check_osstatus(status, "AudioDeviceStart") {
            self.running.store(false, Ordering::SeqCst);
            return Err(e);
        }
        Ok(())
    }

    pub fn stop(&self) -> Result<CaptureResult, Box<dyn Error>> {
        let Some(device_id) = self.aggregate_device_id else {
            return Ok(CaptureResult {
                samples: Vec::new(),
                diagnosis: CaptureDiagnosis::NoSamplesCaptured,
            });
        };
        let io_proc_id = self.io_proc_id;

        if self.running.swap(false, Ordering::SeqCst) {
            let status = unsafe { AudioDeviceStop(device_id, io_proc_id) };
            check_osstatus(status, "AudioDeviceStop")?;
        }

        // Barrera: ver el comentario del módulo. Sin esto, el último bloque
        // de audio que llegó justo antes del stop podría quedar en el canal
        // sin drenar cuando leemos `self.buffer` más abajo.
        if let Some(tx) = &self.cmd_tx {
            let (ack_tx, ack_rx) = mpsc::channel();
            if tx.send(Msg::Barrier(ack_tx)).is_ok()
                && ack_rx.recv_timeout(Duration::from_secs(2)).is_err()
            {
                // M8 (reporte de seguimiento): si la barrera nunca confirma,
                // el hilo consumidor puede seguir procesando el resto del
                // canal después de que `stop()` ya devolvió — y ese
                // `finish()`/`reset()` tardío escribiría en `self.buffer`
                // después de que la línea de abajo ya lo drenó para esta
                // sesión, así que la cola terminaría en el buffer de la
                // PRÓXIMA sesión de grabación si hay un `start()` antes de
                // `close()`. No se pudo justificar una solución completa
                // (por ejemplo, un número de sesión que el hilo consumidor
                // verifique antes de escribir) para un timeout que en la
                // práctica no se vio disparar — pero que no deje ni rastro
                // en el log tampoco era aceptable.
                log::warn!(
                    "la barrera de stop() no confirmó en 2s — el hilo consumidor puede estar atascado; \
                     el resto de su cola podría terminar en el buffer de la próxima sesión de grabación"
                );
            }
        }

        let samples = {
            let mut buf = self.buffer.lock().unwrap();
            std::mem::take(&mut *buf)
        };

        // I6: diagnóstico de por qué `samples` podría no traer audio útil.
        // `saw_nonzero` ya viene calculado sobre las muestras nativas, antes
        // del remuestreo — no depende de que el remuestreo preserve el cero
        // exacto. La decisión en sí vive en `compute_diagnosis` (Important 3
        // del reporte de seguimiento) para que `diagnose_now()` la comparta.
        let has_samples = !samples.is_empty();
        let saw_nonzero = self.saw_nonzero.swap(false, Ordering::Relaxed);
        let diagnosis = compute_diagnosis(has_samples, saw_nonzero);

        Ok(CaptureResult { samples, diagnosis })
    }

    /// Diagnóstico consultable en caliente, sin esperar a `stop()` (Important
    /// 2 del reporte de seguimiento). Antes, el único diagnóstico posible
    /// era el de `stop()` — en una reunión de 40 minutos el usuario recién se
    /// enteraba de que faltaba el permiso al colgar. Esto expone la misma
    /// lógica de sólo lectura: no consume `self.buffer` (a diferencia de
    /// `stop()`, que lo drena con `mem::take`) ni resetea `saw_nonzero`, así
    /// que se puede llamar tantas veces como se quiera durante la grabación
    /// sin alterar lo que `stop()` va a reportar después.
    ///
    /// Llamarlo muy temprano — antes de que llegue el primer bloque de audio
    /// del tap — puede dar legítimamente `NoSamplesCaptured`: no es un error,
    /// es que todavía no hay nada que diagnosticar. El llamador que quiera
    /// sondear "¿va a andar esta reunión?" debería esperar al menos un par de
    /// segundos después de `start()` antes de tratar ese resultado como una
    /// señal real.
    pub fn diagnose_now(&self) -> CaptureDiagnosis {
        let has_samples = !self.buffer.lock().unwrap().is_empty();
        let saw_nonzero = self.saw_nonzero.load(Ordering::Relaxed);
        compute_diagnosis(has_samples, saw_nonzero)
    }

    pub fn close(&mut self) -> Result<(), Box<dyn Error>> {
        self.running.store(false, Ordering::SeqCst);

        if let (Some(device_id), Some(io_proc_id)) = (self.aggregate_device_id, self.io_proc_id) {
            // Ignora el status: si ya estaba detenido, CoreAudio devuelve
            // kAudioHardwareNotRunningError y no es un problema — close()
            // no debe fallar por algo que ya está en el estado que
            // queremos.
            let _ = unsafe { AudioDeviceStop(device_id, Some(io_proc_id)) };
            let _ = unsafe { AudioDeviceDestroyIOProcID(device_id, Some(io_proc_id)) };
        }
        self.io_proc_id = None;

        // Desregistra el listener de I5 antes de soltar su contexto — mismo
        // orden que el IOProc: CoreAudio no debe poder llamar a un puntero
        // que ya dejó de ser válido.
        //
        // Important 4 (reporte de seguimiento): si la desregistración
        // FALLA, ya no se libera `listener_ctx` igual — antes,
        // `self.output_listener_ctx = None` corría sin condición después de
        // este bloque, así que un status distinto de cero dejaba a
        // CoreAudio con un callback pendiente apuntando a memoria recién
        // liberada: un use-after-free en un hilo de la HAL la próxima vez
        // que el sistema disparara el evento. `Box::leak` saca el valor de
        // la gestión normal de memoria de Rust — el proceso los recupera al
        // salir, no antes — y es infinitamente preferible a esa alternativa.
        if let Some(listener_ctx) = self.output_listener_ctx.take() {
            let address = AudioObjectPropertyAddress {
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain,
            };
            let client_data = std::ptr::addr_of!(*listener_ctx) as *mut c_void;
            let status = unsafe {
                AudioObjectRemovePropertyListener(
                    kAudioObjectSystemObject as AudioObjectID,
                    NonNull::from(&address),
                    Some(output_device_listener),
                    client_data,
                )
            };
            if status != 0 {
                log::error!(
                    "no se pudo desregistrar el listener de cambio de dispositivo de salida ({}) — se filtra el contexto a propósito para evitar un use-after-free en un hilo de CoreAudio",
                    describe_osstatus(status)
                );
                Box::leak(listener_ctx);
            }
            // Si `status == 0`, `listener_ctx` se libera acá normalmente al
            // salir de scope: CoreAudio ya confirmó que no lo va a volver a
            // llamar.
        }

        // Soltar `cmd_tx` y `ctx` (que tiene su propio clon del `Sender`)
        // cierra el canal: `rx.recv()` en el hilo consumidor devuelve `Err`
        // y el hilo termina solo, sin necesitar un mensaje de apagado.
        self.cmd_tx = None;
        self.ctx = None;
        if let Some(handle) = self.consumer.take() {
            let _ = handle.join();
        }

        if let Some(aggregate_device_id) = self.aggregate_device_id.take() {
            unsafe { AudioHardwareDestroyAggregateDevice(aggregate_device_id) };
        }
        if let Some(tap_id) = self.tap_id.take() {
            unsafe { AudioHardwareDestroyProcessTap(tap_id) };
        }

        *self.buffer.lock().unwrap() = Vec::new();
        self.native_rate = 0;
        self.saw_nonzero.store(false, Ordering::Relaxed);
        self.output_device_changed.store(false, Ordering::Relaxed);
        Ok(())
    }

    /// Tasa de muestreo nativa del tap reportada por CoreAudio, 0 si todavía
    /// no se llamó a `open()`. Sólo para diagnóstico/logging — la captura ya
    /// remuestrea internamente a 16 kHz.
    pub fn native_sample_rate(&self) -> u32 {
        self.native_rate
    }

    /// True si `kAudioHardwarePropertyDefaultOutputDevice` cambió desde
    /// `open()` (I5, ver el comentario del módulo). El agregado sigue
    /// apuntando al dispositivo de salida que era el de por defecto al
    /// abrir, que puede haber desaparecido — la captura puede haber quedado
    /// muda sin ningún error. El llamador decide qué hacer: avisar al
    /// usuario, o cerrar y reabrir para reconstruir contra el dispositivo
    /// nuevo.
    pub fn output_device_changed(&self) -> bool {
        self.output_device_changed.load(Ordering::SeqCst)
    }

    /// Limpia la señal de `output_device_changed()` después de que el
    /// llamador ya reaccionó (por ejemplo, mostró el aviso una vez).
    pub fn acknowledge_output_device_change(&self) {
        self.output_device_changed.store(false, Ordering::SeqCst);
    }
}

impl Drop for SystemAudioRecorder {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

/// Ver el comentario sobre M6 en `finish_open_with_aggregate`.
struct LeakGuard {
    tap_id: AudioObjectID,
    aggregate_device_id: AudioObjectID,
    io_proc_id: AudioDeviceIOProcID,
    /// Puntero de `client_data` del listener de I5 (M6 del reporte de
    /// seguimiento), sólo si ya se había registrado con éxito en CoreAudio
    /// en el momento de armar este guard. `None` si el registro falló — en
    /// ese caso no hay nada que desregistrar, el listener nunca llegó a
    /// existir del lado de CoreAudio.
    output_listener_client_data: Option<*mut c_void>,
    armed: bool,
}

impl Drop for LeakGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        // SAFETY: mientras el guard esté armado, estos recursos identifican
        // lo que `finish_open_with_aggregate` acaba de crear y que todavía
        // no pasó a manos de `self` — nadie más pudo haberlos destruido ya.
        // El listener se desregistra ANTES de destruir el resto — ver el
        // comentario sobre orden de declaración en
        // `finish_open_with_aggregate`: este `Drop` corre antes que el de
        // `output_listener_ctx`/`ctx`, así que CoreAudio ya no puede llamar
        // a esos punteros para cuando sus cajas se liberan. Si la
        // desregistración fallara acá (caso extremo: ocurre sólo si
        // `std::thread::spawn` ya panickeó, algo que hoy no tiene manejo de
        // "no liberar la memoria" como sí tiene `close()` para el mismo
        // caso — ver Important 4), se ignora el status igual que para el
        // resto de los recursos de este guard: es un camino de pánico ya
        // degradado, no el camino normal.
        unsafe {
            if let Some(client_data) = self.output_listener_client_data {
                let address = AudioObjectPropertyAddress {
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain,
                };
                let _ = AudioObjectRemovePropertyListener(
                    kAudioObjectSystemObject as AudioObjectID,
                    NonNull::from(&address),
                    Some(output_device_listener),
                    client_data,
                );
            }
            if let Some(proc_id) = self.io_proc_id {
                let _ = AudioDeviceDestroyIOProcID(self.aggregate_device_id, Some(proc_id));
            }
            AudioHardwareDestroyAggregateDevice(self.aggregate_device_id);
            AudioHardwareDestroyProcessTap(self.tap_id);
        }
    }
}

// ---------------------------------------------------------------------------
// El callback de CoreAudio y la extracción de audio (no testeable sin
// hardware real: usa punteros que sólo CoreAudio llena).
// ---------------------------------------------------------------------------

/// # Safety
/// CoreAudio garantiza que todos los punteros son válidos durante la llamada
/// y que `in_client_data` es el mismo puntero pasado a
/// `AudioDeviceCreateIOProcID` (acá, siempre un `*const IoProcContext`
/// vigente — ver el comentario sobre `client_data` en
/// `finish_open_with_aggregate`). CoreAudio llama a este IOProc siempre
/// desde el mismo hilo de tiempo real dedicado a este dispositivo, nunca de
/// forma concurrente consigo mismo — por eso `ctx.free_rx.try_recv()` es
/// seguro con sólo `&IoProcContext` pese a que `Receiver` no es `Sync`: no
/// hay dos llamadas de esta función corriendo a la vez.
unsafe extern "C-unwind" fn tap_io_proc(
    _in_device: AudioObjectID,
    _in_now: NonNull<AudioTimeStamp>,
    in_input_data: NonNull<AudioBufferList>,
    _in_input_time: NonNull<AudioTimeStamp>,
    _out_output_data: NonNull<AudioBufferList>,
    _in_output_time: NonNull<AudioTimeStamp>,
    in_client_data: *mut c_void,
) -> i32 {
    if in_client_data.is_null() {
        return 0;
    }
    // SAFETY: ver el comentario de la función.
    let ctx = unsafe { &*(in_client_data as *const IoProcContext) };
    // SAFETY: ídem — `in_input_data` es válido durante la llamada.
    let list = unsafe { in_input_data.as_ref() };

    // I1: reutiliza un buffer reciclado por el hilo consumidor en vez de
    // pedir memoria nueva en el camino común. `unwrap_or_default()` cae a un
    // `Vec::new()` recién creado si todavía no hay nada reciclado (arranque
    // en frío) o si el canal ya se cerró — sigue siendo correcto, sólo
    // pierde la ventaja de no asignar en esos casos puntuales.
    let mut mono = ctx.free_rx.try_recv().unwrap_or_default();
    // SAFETY: ver el comentario de `mono_from_buffer_list_into`.
    unsafe { mono_from_buffer_list_into(list, &mut mono) };
    if !mono.is_empty() {
        let _ = ctx.tx.send(Msg::Audio(mono));
    }
    0
}

/// # Safety
/// Ver el comentario de `tap_io_proc`: CoreAudio llama siempre desde el
/// mismo hilo dedicado a este listener, nunca de forma concurrente consigo
/// mismo, así que `&OutputDeviceListenerContext` con un `Arc<AtomicBool>`
/// adentro es seguro pese a construirse a partir de un puntero crudo.
unsafe extern "C-unwind" fn output_device_listener(
    _in_object_id: AudioObjectID,
    _in_number_addresses: u32,
    _in_addresses: NonNull<AudioObjectPropertyAddress>,
    in_client_data: *mut c_void,
) -> i32 {
    if in_client_data.is_null() {
        return 0;
    }
    // SAFETY: ver el comentario de la función.
    let ctx = unsafe { &*(in_client_data as *const OutputDeviceListenerContext) };
    ctx.changed.store(true, Ordering::SeqCst);
    0
}

/// Extrae y mezcla a mono un `AudioBufferList` entregado por el IOProc,
/// escribiendo el resultado en `out` (se limpia primero, se reutiliza su
/// capacidad — ver I1).
///
/// # Safety
/// `list` debe ser un `AudioBufferList` real de CoreAudio: `mBuffers` está
/// declarado en el binding Rust como `[AudioBuffer; 1]` porque C no tiene
/// "flexible array member" tipado, pero la memoria real tiene
/// `mNumberBuffers` elementos contiguos — es el mismo truco de siempre para
/// este tipo de struct de la API C de CoreAudio. Cada `AudioBuffer.mData` no
/// nulo debe apuntar a `mDataByteSize` bytes de Float32 nativo (verificado en
/// `open()` contra `kAudioTapPropertyFormat` antes de registrar el IOProc).
unsafe fn mono_from_buffer_list_into(list: &AudioBufferList, out: &mut Vec<f32>) {
    let n = list.mNumberBuffers as usize;
    if n == 0 {
        out.clear();
        return;
    }
    // SAFETY: ver el comentario de la función.
    let buffers = unsafe { std::slice::from_raw_parts(list.mBuffers.as_ptr(), n) };

    if n == 1 {
        let buf = &buffers[0];
        let channels = buf.mNumberChannels as usize;
        if buf.mData.is_null() || channels == 0 {
            out.clear();
            return;
        }
        let sample_count = buf.mDataByteSize as usize / std::mem::size_of::<f32>();
        // SAFETY: ver el comentario de la función.
        let samples = unsafe { std::slice::from_raw_parts(buf.mData as *const f32, sample_count) };
        mix_interleaved_to_mono(samples, channels, out);
        return;
    }

    // Camino planar: verificado con hardware real (I3 del reporte) que la
    // HAL entrega siempre `mNumberBuffers=1` para este tap — esta rama no se
    // ejerce en la práctica. Se mantiene por completitud (mejor mezclarla
    // bien que tratarla como silencio si algún día CoreAudio cambiara de
    // forma), pero el `Vec::with_capacity(n)` de acá abajo sigue asignando
    // en el hilo de tiempo real: no se justificó reemplazarlo por algo más
    // elaborado (por ejemplo un arreglo fijo en el stack) para un camino que
    // nunca se ejecuta con este tap.
    out.clear();
    let mut planar: Vec<&[f32]> = Vec::with_capacity(n);
    for buf in buffers {
        if buf.mData.is_null() {
            return;
        }
        let sample_count = buf.mDataByteSize as usize / std::mem::size_of::<f32>();
        // SAFETY: ver el comentario de la función.
        let samples = unsafe { std::slice::from_raw_parts(buf.mData as *const f32, sample_count) };
        planar.push(samples);
    }
    mix_planar_to_mono(&planar, out);
}

// ---------------------------------------------------------------------------
// Glue de CoreAudio: construcción del diccionario del dispositivo agregado y
// consultas de propiedades. Nada acá es puro (todo habla con CoreAudio), así
// que no tiene tests unitarios — el test de hardware al final del archivo
// cubre esta parte end-to-end a mano.
// ---------------------------------------------------------------------------

fn key(cstr: &std::ffi::CStr) -> CFRetained<CFString> {
    // `to_string_lossy()` nunca panickea (a diferencia de `to_str().expect(...)`):
    // si alguna de las claves de CoreAudio dejara de ser ASCII válido en una
    // versión futura del SDK, preferimos una clave rara a un panic en medio
    // de `open()`.
    CFString::from_str(&cstr.to_string_lossy())
}

fn build_aggregate_device_description(
    aggregate_uid: &str,
    output_device_uid: &CFString,
    tap_uid: &CFString,
) -> CFRetained<CFDictionary> {
    let sub_device_uid_key = key(kAudioSubDeviceUIDKey);
    let sub_device_dict: CFRetained<CFDictionary<CFString, CFType>> =
        CFDictionary::from_slices(&[&sub_device_uid_key], &[output_device_uid.as_ref()]);

    let sub_tap_uid_key = key(kAudioSubTapUIDKey);
    let sub_tap_drift_key = key(kAudioSubTapDriftCompensationKey);
    let drift_true: &CFBoolean = CFBoolean::new(true);
    let tap_dict: CFRetained<CFDictionary<CFString, CFType>> = CFDictionary::from_slices(
        &[&sub_tap_uid_key, &sub_tap_drift_key],
        &[tap_uid.as_ref(), drift_true.as_ref()],
    );

    let sub_device_list = CFArray::from_objects(&[sub_device_dict.as_ref() as &CFType]);
    let tap_list = CFArray::from_objects(&[tap_dict.as_ref() as &CFType]);

    let name = CFString::from_str("Dilo - captura de audio del sistema");
    let agg_uid = CFString::from_str(aggregate_uid);
    let is_private: &CFBoolean = CFBoolean::new(true);
    let is_stacked: &CFBoolean = CFBoolean::new(false);
    let autostart: &CFBoolean = CFBoolean::new(true);

    let name_key = key(kAudioAggregateDeviceNameKey);
    let uid_key = key(kAudioAggregateDeviceUIDKey);
    let private_key = key(kAudioAggregateDeviceIsPrivateKey);
    let stacked_key = key(kAudioAggregateDeviceIsStackedKey);
    let autostart_key = key(kAudioAggregateDeviceTapAutoStartKey);
    let subdevice_list_key = key(kAudioAggregateDeviceSubDeviceListKey);
    let taplist_key = key(kAudioAggregateDeviceTapListKey);

    let dict: CFRetained<CFDictionary<CFString, CFType>> = CFDictionary::from_slices(
        &[
            &name_key,
            &uid_key,
            &private_key,
            &stacked_key,
            &autostart_key,
            &subdevice_list_key,
            &taplist_key,
        ],
        &[
            name.as_ref(),
            agg_uid.as_ref(),
            is_private.as_ref(),
            is_stacked.as_ref(),
            autostart.as_ref(),
            sub_device_list.as_ref(),
            tap_list.as_ref(),
        ],
    );

    // SAFETY: `AudioHardwareCreateAggregateDevice` sólo lee el diccionario.
    // `CFDictionary<CFString, CFType>` y el `CFDictionary` (==
    // `CFDictionary<Opaque, Opaque>`) type-erased que pide su firma son la
    // misma `CFDictionaryRef` en tiempo de ejecución — el parámetro de tipo
    // de `objc2-core-foundation` sólo existe en tiempo de compilación.
    unsafe { CFRetained::cast_unchecked(dict) }
}

fn default_output_device_id() -> Result<AudioObjectID, Box<dyn Error>> {
    let address = AudioObjectPropertyAddress {
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    };
    let mut device_id: AudioObjectID = 0;
    let mut size = std::mem::size_of::<AudioObjectID>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            kAudioObjectSystemObject as AudioObjectID,
            NonNull::from(&address),
            0,
            std::ptr::null(),
            NonNull::from(&mut size),
            NonNull::new(&mut device_id as *mut AudioObjectID as *mut c_void).unwrap(),
        )
    };
    check_osstatus(
        status,
        "AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultOutputDevice)",
    )?;
    Ok(device_id)
}

fn device_uid(device_id: AudioObjectID) -> Result<CFRetained<CFString>, Box<dyn Error>> {
    get_property_cfstring(device_id, kAudioDevicePropertyDeviceUID)
}

fn tap_property_uid(tap_id: AudioObjectID) -> Result<CFRetained<CFString>, Box<dyn Error>> {
    get_property_cfstring(tap_id, kAudioTapPropertyUID)
}

fn get_property_cfstring(
    object_id: AudioObjectID,
    selector: objc2_core_audio::AudioObjectPropertySelector,
) -> Result<CFRetained<CFString>, Box<dyn Error>> {
    let address = AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    };
    let mut uid_ptr: *const CFString = std::ptr::null();
    let mut size = std::mem::size_of::<*const CFString>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            object_id,
            NonNull::from(&address),
            0,
            std::ptr::null(),
            NonNull::from(&mut size),
            NonNull::new(&mut uid_ptr as *mut *const CFString as *mut c_void).unwrap(),
        )
    };
    check_osstatus(status, "AudioObjectGetPropertyData(UID)")?;
    let ptr = NonNull::new(uid_ptr as *mut CFString)
        .ok_or_else(|| core_audio_error("CoreAudio devolvió un UID nulo"))?;
    // SAFETY: la HAL de CoreAudio documenta las propiedades CFString con la
    // convención "Get" (Copy): el llamador recibe +1 retain y es
    // responsable de liberarlo. `CFRetained::from_raw` toma dueño de esa
    // referencia sin retener de nuevo, que es justo lo que corresponde acá.
    Ok(unsafe { CFRetained::from_raw(ptr) })
}

/// Lee una propiedad `UInt32` de un `AudioObject` (por ejemplo
/// `kAudioProcessPropertyIsRunningOutput`, que CoreAudio expone como 0/1).
fn get_property_u32(
    object_id: AudioObjectID,
    selector: objc2_core_audio::AudioObjectPropertySelector,
) -> Result<u32, Box<dyn Error>> {
    let address = AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    };
    let mut value: u32 = 0;
    let mut size = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            object_id,
            NonNull::from(&address),
            0,
            std::ptr::null(),
            NonNull::from(&mut size),
            NonNull::new(&mut value as *mut u32 as *mut c_void).unwrap(),
        )
    };
    check_osstatus(status, "AudioObjectGetPropertyData(u32)")?;
    Ok(value)
}

/// Enumera los `AudioObjectID` de `kAudioHardwarePropertyProcessObjectList`
/// (I6, ver el comentario del módulo). CoreAudio devuelve esta propiedad
/// como un array plano de `AudioObjectID`, no como `CFArray` — hace falta
/// consultar el tamaño primero porque la cantidad de procesos de audio
/// cambia todo el tiempo.
fn audio_process_object_ids() -> Result<Vec<AudioObjectID>, Box<dyn Error>> {
    let address = AudioObjectPropertyAddress {
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    };
    let system_object = kAudioObjectSystemObject as AudioObjectID;

    let mut size: u32 = 0;
    let status = unsafe {
        AudioObjectGetPropertyDataSize(
            system_object,
            NonNull::from(&address),
            0,
            std::ptr::null(),
            NonNull::from(&mut size),
        )
    };
    check_osstatus(
        status,
        "AudioObjectGetPropertyDataSize(kAudioHardwarePropertyProcessObjectList)",
    )?;

    let count = size as usize / std::mem::size_of::<AudioObjectID>();
    if count == 0 {
        return Ok(Vec::new());
    }

    let mut ids = vec![0 as AudioObjectID; count];
    let mut io_size = size;
    let status = unsafe {
        AudioObjectGetPropertyData(
            system_object,
            NonNull::from(&address),
            0,
            std::ptr::null(),
            NonNull::from(&mut io_size),
            NonNull::new(ids.as_mut_ptr() as *mut c_void).unwrap(),
        )
    };
    check_osstatus(
        status,
        "AudioObjectGetPropertyData(kAudioHardwarePropertyProcessObjectList)",
    )?;
    ids.truncate(io_size as usize / std::mem::size_of::<AudioObjectID>());
    Ok(ids)
}

/// True si algún proceso del sistema tiene salida de audio activa ahora
/// mismo (I6). Se usa sólo para desambiguar un `stop()`/`diagnose_now()` que
/// capturó puro cero: cruzado con eso, "algo tiene salida activa y
/// capturamos cero" es la firma de "falta el permiso de captura de audio del
/// sistema"; "nada tiene salida activa" es silencio normal.
///
/// M5 (reporte de seguimiento) — ojo con lo que esto garantiza de verdad:
/// `kAudioProcessPropertyIsRunningOutput` documenta (`AudioHardware.h`,
/// líneas 1971-1974 del SDK) que el proceso "está corriendo IO y tiene al
/// menos un stream de salida activo" — NO que esté produciendo sonido
/// audible. Un proceso con el stream abierto pero mudo (Spotify en pausa con
/// el output todavía prendido, una pestaña con un `AudioContext` vivo que no
/// suena) puede devolver 1 igual. Por eso el diagnóstico que cruza esto se
/// llama `LikelyMissingPermission`, no `MissingPermission` a secas — sigue
/// siendo la mejor señal disponible (no existe una consulta pública al
/// estado de TCC para este permiso), pero no es una prueba.
///
/// Un proceso individual que falle la consulta (por ejemplo, uno que terminó
/// entre la enumeración y la lectura de su propiedad) se trata como "no
/// tiene salida activa" en vez de abortar toda la consulta por uno solo.
/// Important 1 (reporte de seguimiento): eso es distinto de que **todas**
/// las lecturas fallen — un selector que dejara de estar soportado en una
/// macOS futura, por ejemplo. Antes, ese caso también caía en `Ok(false)`
/// ("nadie tiene salida activa"), que un `stop()` con `saw_nonzero == false`
/// traduce en `GenuineSilence` — exactamente la inversión de la señal que
/// este mecanismo existe para dar si en realidad había audio y faltaba el
/// permiso. Por eso se cuentan las lecturas exitosas aparte del resultado: si
/// hubo procesos para consultar pero ninguna lectura funcionó, se devuelve
/// `Err` — el llamador lo traduce a `CaptureDiagnosis::Undetermined`.
fn any_process_playing_audio() -> Result<bool, Box<dyn Error>> {
    let ids = audio_process_object_ids()?;
    if ids.is_empty() {
        // No hay ningún proceso de audio para preguntar: no es un fallo de
        // lectura, es que no hay nada con salida que pueda estar activa.
        return Ok(false);
    }

    let mut any_read_ok = false;
    for id in ids {
        match get_property_u32(id, kAudioProcessPropertyIsRunningOutput) {
            Ok(value) => {
                any_read_ok = true;
                if value != 0 {
                    return Ok(true);
                }
            }
            Err(_) => {
                // Este proceso puntual no se pudo leer (por ejemplo, terminó
                // entre enumerarlo y consultarle la propiedad) — se sigue
                // con el resto en vez de abortar toda la consulta por uno.
            }
        }
    }

    if !any_read_ok {
        return Err(core_audio_error(
            "no se pudo leer kAudioProcessPropertyIsRunningOutput de ningún proceso enumerado",
        ));
    }
    Ok(false)
}

/// Calcula el diagnóstico de `stop()`/`diagnose_now()` (Important 3 del
/// reporte de seguimiento): comparte la consulta a
/// `any_process_playing_audio()` — sólo se hace cuando hace falta, es decir
/// cuando hay muestras pero todas en cero — y la traduce a la forma que
/// espera la función pura [`diagnose`] de `system_audio.rs`, logueando el
/// motivo si la consulta falla. No toma `&self`: no necesita ningún campo de
/// `SystemAudioRecorder`, sólo lo que `stop()`/`diagnose_now()` ya
/// calcularon sobre su propio estado.
fn compute_diagnosis(has_samples: bool, saw_nonzero: bool) -> CaptureDiagnosis {
    let playing = if has_samples && !saw_nonzero {
        any_process_playing_audio().map_err(|e| {
            log::warn!(
                "no se pudo consultar si había procesos con salida de audio activa para diagnosticar el silencio: {e}"
            );
        })
    } else {
        // `diagnose()` no mira `playing` cuando no hay muestras o cuando ya
        // hubo una muestra no-cero — este `Err(())` es un valor descartable,
        // no una consulta que efectivamente falló.
        Err(())
    };
    diagnose(has_samples, saw_nonzero, playing)
}

fn tap_stream_format(tap_id: AudioObjectID) -> Result<AudioStreamBasicDescription, Box<dyn Error>> {
    let address = AudioObjectPropertyAddress {
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    };
    // SAFETY: `AudioStreamBasicDescription` es un struct plano de f64/u32
    // (`#[repr(C)]`), sin invariantes que un patrón de bits en cero pueda
    // violar; CoreAudio lo sobrescribe completo antes de que se lea.
    let mut format: AudioStreamBasicDescription = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of::<AudioStreamBasicDescription>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            tap_id,
            NonNull::from(&address),
            0,
            std::ptr::null(),
            NonNull::from(&mut size),
            NonNull::new(&mut format as *mut AudioStreamBasicDescription as *mut c_void).unwrap(),
        )
    };
    check_osstatus(
        status,
        "AudioObjectGetPropertyData(kAudioTapPropertyFormat)",
    )?;
    Ok(format)
}

fn check_osstatus(status: i32, context: &str) -> Result<(), Box<dyn Error>> {
    if status == 0 {
        Ok(())
    } else {
        Err(core_audio_error(&format!(
            "{context}: {}",
            describe_osstatus(status)
        )))
    }
}

fn core_audio_error(msg: &str) -> Box<dyn Error> {
    Box::<dyn Error>::from(msg.to_string())
}

fn unique_suffix() -> String {
    use std::sync::atomic::AtomicU64;
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:x}-{n}")
}

/// True si esta máquina soporta la captura de audio del sistema ahora mismo
/// (macOS 14.2+, ver `is_process_tap_available`). Consulta la versión de
/// macOS en caliente cada vez — no cachea — porque quien la usa (el ajuste
/// de fuente de audio de reuniones, `managers/meeting.rs`) la llama a lo
/// sumo una vez por sesión de reunión, no en un camino caliente.
pub fn system_audio_available() -> bool {
    macos_version()
        .map(|(major, minor)| is_process_tap_available(major, minor))
        .unwrap_or(false)
}

/// Lee `kern.osproductversion` vía `sysctlbyname` (por ejemplo "14.2.1") y lo
/// reduce a `(mayor, menor)`. Se eligió `sysctlbyname` — `libc` ya está en el
/// árbol vía `coreaudio-rs` — en vez de `NSProcessInfo` para no sumar la
/// superficie de Foundation sólo para esta consulta.
fn macos_version() -> Option<(u32, u32)> {
    let name = CString::new("kern.osproductversion").ok()?;
    let mut size: libc::size_t = 0;
    // SAFETY: llamada estándar de sysctlbyname en modo "sólo tamaño"
    // (buffer nulo): sólo escribe `size`.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 || size == 0 {
        return None;
    }

    let mut buf = vec![0u8; size];
    // SAFETY: `buf` tiene exactamente `size` bytes reservados, tal como
    // sysctlbyname acaba de reportar.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            buf.as_mut_ptr() as *mut c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return None;
    }

    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    let text = std::str::from_utf8(&buf[..end]).ok()?;
    parse_macos_version(text)
}

// ---------------------------------------------------------------------------
// Test de hardware — no se corre en CI ni en `cargo test --lib` normal.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Prueba end-to-end contra CoreAudio real. Requiere:
    /// - macOS 14.2+ con permiso de audio del sistema ya concedido (o el
    ///   diálogo del sistema aparecerá la primera vez).
    /// - Algo sonando en el equipo durante la ventana de grabación (un video,
    ///   música) para que el buffer no salga vacío.
    ///
    /// No se corrió como parte de esta tarea — instrucción explícita de no
    /// ejecutar la app ni depender de hardware desde acá. Para correrlo a
    /// mano:
    ///
    /// ```sh
    /// cargo test --lib -- --ignored system_audio::macos::tests::captura_real_del_audio_del_sistema --nocapture
    /// ```
    #[test]
    #[ignore]
    fn captura_real_del_audio_del_sistema() {
        let mut rec = SystemAudioRecorder::new().expect("new() no debería fallar");
        rec.open()
            .expect("open() — ¿permiso de audio del sistema concedido?");
        assert!(!rec.output_device_changed());

        rec.start().expect("start()");
        std::thread::sleep(Duration::from_secs(3));
        let first = rec.stop().expect("stop()");
        assert!(
            !first.samples.is_empty(),
            "no se capturó audio — ¿había algo sonando?"
        );
        assert_eq!(
            first.diagnosis,
            CaptureDiagnosis::AudioPresent,
            "se esperaba audio real con algo sonando en el equipo"
        );

        // stop() seguido de start() no debe recrear el tap ni el
        // dispositivo agregado (requisito de la tarea): si acumulara
        // recursos, esta segunda vuelta fallaría o degradaría con el uso.
        rec.start().expect("segundo start() tras stop()");
        std::thread::sleep(Duration::from_secs(1));
        let second = rec.stop().expect("segundo stop()");
        assert!(!second.samples.is_empty());

        rec.close().expect("close()");
    }
}

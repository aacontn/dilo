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
//! ## Hilo consumidor y la barrera de `stop()`
//!
//! El callback de CoreAudio (`tap_io_proc`) corre en el hilo de tiempo real
//! del propio CoreAudio: sólo hace la mezcla a mono (barata) y un
//! `Sender::send` no bloqueante, igual que `AudioRecorder::build_stream` hace
//! con el micrófono ("keep the callback cheap"). Un hilo consumidor aparte
//! junta esas muestras en `buffer`.
//!
//! `AudioDeviceStop` documenta que, cuando retorna, el IOProc no vuelve a
//! llamarse — pero el hilo consumidor puede ir un paso atrás del canal en
//! ese instante. Por eso `stop()` manda un mensaje `Msg::Barrier` **después**
//! de `AudioDeviceStop` y espera su ack: como ambos productores (el IOProc y
//! `stop()`) escriben al mismo `mpsc::Sender` clonado, el orden FIFO del
//! canal garantiza que la barrera llega después de toda la audio pendiente.
//! Es la misma garantía de "no perder el último bloque" que
//! `AudioRecorder::run_consumer` logra con su sentinela `EndOfStream`, pero
//! más simple acá porque `AudioDeviceStop` ya da el corte limpio que cpal no
//! ofrece.

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
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyElementMain,
    kAudioObjectPropertyScopeGlobal, kAudioObjectSystemObject, kAudioSubDeviceUIDKey,
    kAudioSubTapDriftCompensationKey, kAudioSubTapUIDKey, kAudioTapPropertyFormat,
    kAudioTapPropertyUID, AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID,
    AudioDeviceIOProcID, AudioDeviceStart, AudioDeviceStop, AudioHardwareCreateAggregateDevice,
    AudioHardwareCreateProcessTap, AudioHardwareDestroyAggregateDevice,
    AudioHardwareDestroyProcessTap, AudioObjectGetPropertyData, AudioObjectID,
    AudioObjectPropertyAddress, CATapDescription, CATapMuteBehavior,
};
use objc2_core_audio_types::{
    kAudioFormatFlagIsFloat, kAudioFormatLinearPCM, AudioBufferList, AudioStreamBasicDescription,
    AudioTimeStamp,
};
use objc2_core_foundation::{CFArray, CFBoolean, CFDictionary, CFRetained, CFString, CFType};
use objc2_foundation::{NSArray, NSNumber};

use super::{
    describe_osstatus, is_process_tap_available, mix_interleaved_to_mono, mix_planar_to_mono,
    parse_macos_version, resampled_frame_count,
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
}

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
    buffer: Arc<Mutex<Vec<f32>>>,
    /// Tasa de muestreo nativa del tap (la que reporta
    /// `kAudioTapPropertyFormat`), no necesariamente 48 kHz.
    native_rate: u32,
    running: AtomicBool,
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
        })
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
        let ctx = Box::new(IoProcContext { tx: tx.clone() });
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

        let buffer = Arc::new(Mutex::new(Vec::<f32>::new()));
        let consumer_buffer = Arc::clone(&buffer);
        let consumer = std::thread::spawn(move || {
            while let Ok(msg) = rx.recv() {
                match msg {
                    Msg::Audio(samples) => {
                        consumer_buffer.lock().unwrap().extend(samples);
                    }
                    Msg::Barrier(ack) => {
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
        self.native_rate = sample_rate.round() as u32;
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

    pub fn stop(&self) -> Result<Vec<f32>, Box<dyn Error>> {
        let Some(device_id) = self.aggregate_device_id else {
            return Ok(Vec::new());
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
            if tx.send(Msg::Barrier(ack_tx)).is_ok() {
                let _ = ack_rx.recv_timeout(Duration::from_secs(2));
            }
        }

        let native_mono = {
            let mut buf = self.buffer.lock().unwrap();
            std::mem::take(&mut *buf)
        };

        if native_mono.is_empty() || self.native_rate == 0 {
            return Ok(Vec::new());
        }

        let mut resampler = FrameResampler::new(
            self.native_rate as usize,
            constants::WHISPER_SAMPLE_RATE as usize,
            Duration::from_millis(30),
        );
        let mut out = Vec::with_capacity(resampled_frame_count(
            native_mono.len(),
            self.native_rate,
            constants::WHISPER_SAMPLE_RATE,
        ));
        resampler.push(&native_mono, |frame| out.extend_from_slice(frame));
        resampler.finish(|frame| out.extend_from_slice(frame));
        Ok(out)
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
        Ok(())
    }
}

impl Drop for SystemAudioRecorder {
    fn drop(&mut self) {
        let _ = self.close();
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
/// vigente — ver el comentario sobre `client_data` en `finish_open_with_aggregate`).
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
    // SAFETY: ver el comentario de `mono_from_buffer_list`.
    let mono = unsafe { mono_from_buffer_list(list) };
    if !mono.is_empty() {
        let _ = ctx.tx.send(Msg::Audio(mono));
    }
    0
}

/// Extrae y mezcla a mono un `AudioBufferList` entregado por el IOProc.
///
/// # Safety
/// `list` debe ser un `AudioBufferList` real de CoreAudio: `mBuffers` está
/// declarado en el binding Rust como `[AudioBuffer; 1]` porque C no tiene
/// "flexible array member" tipado, pero la memoria real tiene
/// `mNumberBuffers` elementos contiguos — es el mismo truco de siempre para
/// este tipo de struct de la API C de CoreAudio. Cada `AudioBuffer.mData` no
/// nulo debe apuntar a `mDataByteSize` bytes de Float32 nativo (verificado en
/// `open()` contra `kAudioTapPropertyFormat` antes de registrar el IOProc).
unsafe fn mono_from_buffer_list(list: &AudioBufferList) -> Vec<f32> {
    let n = list.mNumberBuffers as usize;
    if n == 0 {
        return Vec::new();
    }
    // SAFETY: ver el comentario de la función.
    let buffers = unsafe { std::slice::from_raw_parts(list.mBuffers.as_ptr(), n) };

    if n == 1 {
        let buf = &buffers[0];
        let channels = buf.mNumberChannels as usize;
        if buf.mData.is_null() || channels == 0 {
            return Vec::new();
        }
        let sample_count = buf.mDataByteSize as usize / std::mem::size_of::<f32>();
        // SAFETY: ver el comentario de la función.
        let samples = unsafe { std::slice::from_raw_parts(buf.mData as *const f32, sample_count) };
        return mix_interleaved_to_mono(samples, channels);
    }

    let mut planar: Vec<&[f32]> = Vec::with_capacity(n);
    for buf in buffers {
        if buf.mData.is_null() {
            return Vec::new();
        }
        let sample_count = buf.mDataByteSize as usize / std::mem::size_of::<f32>();
        // SAFETY: ver el comentario de la función.
        let samples = unsafe { std::slice::from_raw_parts(buf.mData as *const f32, sample_count) };
        planar.push(samples);
    }
    mix_planar_to_mono(&planar)
}

// ---------------------------------------------------------------------------
// Glue de CoreAudio: construcción del diccionario del dispositivo agregado y
// consultas de propiedades. Nada acá es puro (todo habla con CoreAudio), así
// que no tiene tests unitarios — el test de hardware al final del archivo
// cubre esta parte end-to-end a mano.
// ---------------------------------------------------------------------------

fn key(cstr: &std::ffi::CStr) -> CFRetained<CFString> {
    CFString::from_str(cstr.to_str().expect("clave CoreAudio no es UTF-8 válido"))
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
        rec.start().expect("start()");
        std::thread::sleep(Duration::from_secs(3));
        let first = rec.stop().expect("stop()");
        assert!(
            !first.is_empty(),
            "no se capturó audio — ¿había algo sonando?"
        );

        // stop() seguido de start() no debe recrear el tap ni el
        // dispositivo agregado (requisito de la tarea): si acumulara
        // recursos, esta segunda vuelta fallaría o degradaría con el uso.
        rec.start().expect("segundo start() tras stop()");
        std::thread::sleep(Duration::from_secs(1));
        let second = rec.stop().expect("segundo stop()");
        assert!(!second.is_empty());

        rec.close().expect("close()");
    }
}

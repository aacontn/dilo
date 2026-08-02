//! Tauri commands for the meeting notetaker feature. `start_meeting` (T011)
//! is the first one — see `specs/001-meeting-notetaker/contracts/
//! tauri-commands.md` for the full contract this feature will grow into.
//! `stop_meeting` (T015) es el segundo. `list_meetings`/`get_meeting` (T035)
//! son los que por fin dejan leer lo que ya se graba y se guarda: hasta acá
//! ninguna pantalla podía mostrar una reunión pasada.

use crate::managers::meeting::{
    Meeting, MeetingAudioWarning, MeetingKind, MeetingManager, PaginatedMeetings,
    PendingMeetingAudioNotices,
};
use crate::settings::{get_settings, write_settings, MeetingAudioSource};
use std::sync::Arc;
use tauri::{AppHandle, Manager, State};

/// Start a new meeting recording: inserts a `meetings` row with
/// `status = "recording"`, abre el micrófono y devuelve el `id`.
///
/// T011 dejó este comando creando sólo la fila, porque la captura real
/// (T012) todavía no existía; T017 la enchufa acá, que es el único lugar
/// donde el usuario puede pedirla. Sin esto, apretar "grabar" creaba una
/// reunión que no escuchaba nada.
///
/// **Si abrir el micrófono falla, la fila se borra.** Los motivos típicos
/// son que el micrófono esté tomado por un dictado en curso o que falten
/// permisos — casos donde no se grabó ni un segundo de audio. Dejar la
/// reunión creada obligaría al usuario a lidiar con una reunión fantasma
/// vacía, y peor: bloquearía la siguiente con `recording_busy`.
#[tauri::command]
#[specta::specta]
pub async fn start_meeting(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    kind: String,
) -> Result<i64, String> {
    // Un solo parseo, reusado para las dos llamadas de abajo: la fila en
    // `meetings.kind` (texto crudo, sin cambios) y `start_capture` (que
    // necesita el tipo ya validado para decidir la fuente de audio real —
    // ver `resolve_meeting_audio_source`, M2 del reporte de cableado de
    // audio: antes `start_capture` no sabía el `kind` de la reunión y
    // resolvía la fuente contra un ajuste global aparte, que podía quedar
    // incoherente con lo que decía la interfaz).
    let parsed_kind =
        MeetingKind::parse(&kind).ok_or_else(|| format!("Invalid meeting kind: {}", kind))?;

    let meeting_id = meeting_manager
        .start_meeting(&kind)
        .map_err(|e| e.to_string())?;

    if let Err(e) = meeting_manager.start_capture(meeting_id, parsed_kind) {
        meeting_manager.discard_meeting(meeting_id);
        return Err(e.to_string());
    }

    Ok(meeting_id)
}

/// Detener una reunión en curso: `recording → processing` (contrato:
/// `tauri-commands.md#stop_meeting`, output `void` — el progreso llega por
/// evento).
///
/// El comando devuelve apenas la transición de estado está confirmada, y deja
/// el resto corriendo en background por dos razones:
///
/// 1. Detener la captura **bloquea**: `stop_capture` junta los hilos de
///    watchdog y transcripción, que antes de salir drenan la cola de turnos
///    pendientes (transcribir cada uno puede tardar segundos). Hacer eso en el
///    hilo del comando congelaría la UI justo cuando el usuario apretó
///    "detener".
/// 2. El contrato ya dice que el progreso viaja por eventos
///    (`meeting-progress`, `meeting-finished`, `meeting-error`), así que la
///    UI no necesita que el comando espere.
///
/// El estado se mueve a `processing` **antes** de devolver: si la app se cae
/// mientras se drena la cola, la reunión no queda como `recording` sin
/// `ended_at` y la recuperación de T021 no la confunde con una sesión
/// interrumpida de verdad.
#[tauri::command]
#[specta::specta]
pub async fn stop_meeting(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    meeting_id: i64,
) -> Result<(), String> {
    let transition = meeting_manager
        .stop_meeting(meeting_id)
        .map_err(|e| e.to_string());

    // El cierre se despacha **pase lo que pase** con la transición de
    // estado, sin `?` de por medio. Si la fila no estaba en `recording` (una
    // reunión recuperada como `interrupted`, un doble click), `stop_meeting`
    // falla — pero la captura y el micrófono siguen tomados igual, y
    // devolver acá los dejaba tomados hasta reiniciar la app.
    let manager = Arc::clone(&meeting_manager);
    let transition_ok = transition.is_ok();
    tauri::async_runtime::spawn_blocking(move || manager.finish_stop(meeting_id, transition_ok));

    transition
}

/// Ponerle nombre a un hablante detectado, o renombrarlo (FR-005). Mandar un
/// nombre vacío borra el nombre y deja la etiqueta automática `Hablante N`.
#[tauri::command]
#[specta::specta]
pub async fn assign_speaker_name(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    speaker_id: i64,
    display_name: String,
) -> Result<(), String> {
    meeting_manager
        .assign_speaker_name(speaker_id, &display_name)
        .map_err(|e| e.to_string())
}

/// Fusionar dos hablantes que el sistema separó de más (FR-005): todo lo de
/// `sourceSpeakerId` pasa a mostrarse bajo `targetSpeakerId`.
///
/// Es la contraparte necesaria de la atribución automática: el registro de
/// hablantes prefiere no asignar antes que adivinar (FR-004), pero cuando de
/// todos modos separa a una misma persona en dos, corregirlo es del usuario y
/// no de un re-clustering silencioso del transcript que ya vio.
#[tauri::command]
#[specta::specta]
pub async fn merge_speakers(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    meeting_id: i64,
    source_speaker_id: i64,
    target_speaker_id: i64,
) -> Result<(), String> {
    meeting_manager
        .merge_speakers(meeting_id, source_speaker_id, target_speaker_id)
        .map_err(|e| e.to_string())
}

/// Listado paginado de reuniones pasadas, de más reciente a más antigua
/// (contrato: `tauri-commands.md#list_meetings`). No implementa la búsqueda
/// de texto (`query`) del contrato — eso es Historia 5, ver
/// `specs/001-meeting-notetaker/tasks.md` T041; este comando cubre sólo el
/// listado simple que Historia 4 necesita.
#[tauri::command]
#[specta::specta]
pub async fn list_meetings(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    limit: i64,
    offset: i64,
) -> Result<PaginatedMeetings, String> {
    meeting_manager
        .list_meetings(limit, offset)
        .map_err(|e| e.to_string())
}

/// Reunión completa para leerla: datos, transcript en orden cronológico (con
/// los hablantes fusionados ya resueltos al destino) y la lista de hablantes
/// vigente. Alimenta las pestañas de Historia 3 (contrato:
/// `tauri-commands.md#get_meeting`).
#[tauri::command]
#[specta::specta]
pub async fn get_meeting(
    meeting_manager: State<'_, Arc<MeetingManager>>,
    meeting_id: i64,
) -> Result<Meeting, String> {
    meeting_manager
        .get_meeting(meeting_id)
        .map_err(|e| e.to_string())
}

/// Recuerda el tipo de reunión elegido la última vez, para preseleccionarlo
/// la próxima vez que se abra el selector (`RecordingControls.tsx`) —
/// **ya no determina la fuente de audio de ninguna reunión**: eso lo decide
/// `resolve_meeting_audio_source` a partir del `kind` de esa reunión en
/// particular (M2 del reporte de cableado). El nombre del comando y del
/// ajuste (`meeting_audio_source`, tipo `MeetingAudioSource`) se conservan
/// sin cambios a propósito — es sólo una etiqueta de recordatorio ahora,
/// pero renombrar el campo persistido rompería la compatibilidad con
/// `settings.json` ya guardados; ver el doc comment del campo en
/// `settings.rs` para el detalle completo de la reinterpretación.
///
/// M3 del reporte de seguimiento: un `source` que no sea exactamente
/// `"system_audio"` o `"microphone"` ahora **falla** en vez de caer en
/// silencio al default — antes un typo (por ejemplo, mandado a mano contra
/// el comando) cambiaba el ajuste sin que nadie se enterara.
#[tauri::command]
#[specta::specta]
pub fn change_meeting_audio_source_setting(app: AppHandle, source: String) -> Result<(), String> {
    let parsed = match source.as_str() {
        "system_audio" => MeetingAudioSource::SystemAudio,
        "microphone" => MeetingAudioSource::Microphone,
        other => return Err(format!("Invalid meeting audio source: {}", other)),
    };
    let mut settings = get_settings(&app);
    settings.meeting_audio_source = parsed;
    write_settings(&app, settings);
    Ok(())
}

/// Si esta máquina soporta la captura de audio del sistema (macOS 14.2+,
/// process taps de CoreAudio). El frontend lo consulta para no ofrecer una
/// opción que no va a funcionar — fuera de macOS, o en una versión anterior,
/// la fuente siempre resuelve a micrófono (ver
/// `managers::meeting::resolve_meeting_audio_source`).
#[tauri::command]
#[specta::specta]
pub fn is_system_audio_available() -> bool {
    crate::audio_toolkit::audio::system_audio_available()
}

/// Avisos de audio de reunión (falta el permiso, varios minutos sin
/// capturar nada real, cambió el dispositivo de salida, se cayó a
/// micrófono) que ocurrieron sin que la ventana de Reuniones estuviera a la
/// vista — I5 del reporte de seguimiento. El flujo esperado es grabar y
/// volver a la videollamada: `return_to_main_window` y el botón de cerrar de
/// esa ventana la esconden (`window.hide()`) en vez de destruirla, así que
/// el evento `meeting-audio-warning` en vivo llega a un webview que nadie
/// está mirando. `MeetingsWindow.tsx`/`useMeetings.ts` vacían esta cola al
/// montar y al recuperar el foco de la ventana, mismo patrón que
/// `take_pending_fallback_notices`/`take_pending_assistant_notices`.
#[tauri::command]
#[specta::specta]
pub fn take_pending_meeting_audio_notices(app: AppHandle) -> Vec<MeetingAudioWarning> {
    app.state::<PendingMeetingAudioNotices>().take_all()
}

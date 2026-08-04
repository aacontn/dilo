import type { MeetingAudioSource } from "@/bindings";
import type { MeetingKind } from "@/stores/meetingStore";

/**
 * `settings.meeting_audio_source` sólo recuerda la última elección de tipo
 * de reunión para preseleccionarla la próxima vez (ver su doc comment en
 * `settings.rs`) — estas dos funciones son el único lugar que la traduce
 * de/a un `MeetingKind`. Nacieron en `RecordingControls.tsx` (el selector
 * completo de la ventana de reuniones) y se extrajeron acá cuando
 * `PopoverBody` también necesitó la misma traducción para dejar de forzar
 * `"presencial"` sin mirar el ajuste (reporte del dueño, 2026-08-04): dos
 * copias de esta regla se hubieran separado solas con el tiempo, como ya
 * pasó una vez en este repo con `isPastMeeting`.
 */
export const kindFromPersistedSource = (
  source: MeetingAudioSource | undefined,
): MeetingKind => (source === "microphone" ? "presencial" : "virtual");

export const sourceFromKind = (kind: MeetingKind): MeetingAudioSource =>
  kind === "presencial" ? "microphone" : "system_audio";

/**
 * Deriva la fuente de audio que el backend va a usar REALMENTE, mismo
 * criterio que `managers::meeting::resolve_meeting_audio_source` en Rust
 * (I3 del reporte de cableado de audio: la interfaz tiene que mostrar lo que
 * de verdad va a grabar, no un ajuste que puede quedar incoherente).
 * `systemAudioAvailable === null` (todavía consultando) se trata como
 * disponible para no parpadear al primer render.
 */
export const resolveDisplayedAudioSource = (
  kind: MeetingKind,
  systemAudioAvailable: boolean | null,
): MeetingAudioSource =>
  kind === "virtual" && systemAudioAvailable !== false
    ? "system_audio"
    : "microphone";

/**
 * Clave de traducción para el indicador de tipo/fuente que se muestra junto
 * al botón de grabar. Tres combinaciones reales, no dos: una reunión online
 * en una máquina sin audio de sistema (Windows, Linux, macOS viejo) graba
 * con el micrófono igual que una presencial, pero SIGUE siendo una reunión
 * online — reusar el texto de "Presencial" ahí sería mentir sobre el tipo,
 * no sólo sobre la fuente.
 */
export const resolveIndicatorLabelKey = (
  kind: MeetingKind,
  displayedAudioSource: MeetingAudioSource,
): string => {
  if (kind === "presencial") return "meeting.controls.kindPresencial";
  return displayedAudioSource === "system_audio"
    ? "meeting.controls.kindOnlineSystemAudio"
    : "meeting.controls.kindOnlineMicrophoneFallback";
};

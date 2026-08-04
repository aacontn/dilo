/**
 * `start_meeting` falla con el string crudo `"recording_busy"` cuando ya hay
 * otra reunión en `recording` — el backend lo rechaza a propósito (no se
 * toca, ver el reporte del dueño). Antes ese string se mostraba tal cual en
 * el toast de error, sin decir qué significa ni qué hacer. Esta función es
 * el único lugar que reconoce ese caso, para que el popover y la ventana de
 * reuniones lo traten igual en vez de cada uno adivinar por su cuenta.
 */
export const isRecordingBusyError = (error: unknown): boolean =>
  error instanceof Error && error.message === "recording_busy";

/**
 * Detener cuando no hay ninguna reunión grabando — ni en esta ventana ni en
 * el backend. No es un error del backend: lo levanta `stopMeeting`
 * (`stores/meetingStore.ts`) para que apretar "detener" nunca vuelva a ser
 * un `return` mudo. El llamador lo reconoce con `isNoActiveMeetingError` y
 * muestra copia traducida en vez de este string.
 */
export const NO_ACTIVE_MEETING_ERROR = "meeting_no_active_session";

export const isNoActiveMeetingError = (error: unknown): boolean =>
  error instanceof Error && error.message === NO_ACTIVE_MEETING_ERROR;

/**
 * Prefijo del error que `start_capture` (Rust, `managers/meeting.rs`) manda
 * cuando el modelo resuelto para la reunión (propio o heredado del dictado)
 * no soporta reconocimiento en streaming — desde la Task 5 del plan
 * "reuniones en streaming" ese es el ÚNICO camino de texto de una reunión,
 * así que grabar con un modelo sin streaming no perdía turnos como antes:
 * no guardaba nada, en silencio. El id del modelo va después del prefijo
 * (`meeting_model_not_streaming:parakeet-tdt-0.6b-v3`, por ejemplo) para
 * poder nombrarlo en el toast sin adivinar cuál era.
 */
const MODEL_NOT_STREAMING_PREFIX = "meeting_model_not_streaming:";

/**
 * El otro rechazo del mismo chequeo: el modelo sí hace streaming, pero no
 * entrega marcas de tiempo **por token** (`capabilities.timestamps`). Sin
 * ellas no hay con qué cruzar el texto contra los tramos de hablante, así
 * que la reunión grabaría sin guardar un solo segmento — el mismo desenlace
 * que un modelo sin streaming, por otro motivo, y por eso se avisa distinto.
 */
const MODEL_NO_TIMESTAMPS_PREFIX = "meeting_model_no_timestamps:";

/**
 * Si `error` es el rechazo de arriba, devuelve el id del modelo que no
 * sirve; si no, `null`. El llamador lo cruza contra `useModelStore` para
 * mostrar el nombre visible en vez del id crudo.
 */
export const modelNotStreamingErrorModelId = (
  error: unknown,
): string | null => {
  if (!(error instanceof Error)) return null;
  if (!error.message.startsWith(MODEL_NOT_STREAMING_PREFIX)) return null;
  return error.message.slice(MODEL_NOT_STREAMING_PREFIX.length);
};

/** Igual que la anterior, para el rechazo por falta de marcas por token. */
export const modelNoTimestampsErrorModelId = (
  error: unknown,
): string | null => {
  if (!(error instanceof Error)) return null;
  if (!error.message.startsWith(MODEL_NO_TIMESTAMPS_PREFIX)) return null;
  return error.message.slice(MODEL_NO_TIMESTAMPS_PREFIX.length);
};

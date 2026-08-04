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

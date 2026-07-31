/**
 * Segundos -> `m:ss` o `h:mm:ss`. Igual criterio que `formatOffset` de
 * `TranscriptList` (sin palabras, sólo dígitos) para no sumar claves i18n
 * por algo que se lee sin ambigüedad en cualquier idioma.
 */
export const formatDuration = (seconds: number): string => {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;

  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  }
  return `${minutes}:${String(secs).padStart(2, "0")}`;
};

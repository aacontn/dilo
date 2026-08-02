import type { MeetingSummary } from "@/bindings";

/**
 * Cuántas reuniones muestra el popover de la barra. Número fijo y no "las que
 * quepan": así el popover no cambia de alto según lo que haya (§2 del diseño).
 */
export const RECENT_MEETINGS_LIMIT = 4;

/**
 * La reunión en curso viaja en el mismo listado que las pasadas —
 * `list_meetings` no la excluye—, así que quien muestre "reuniones pasadas"
 * tiene que filtrarla. Vive acá y no en un componente porque la usan dos: el
 * registro completo y el popover.
 */
export const isPastMeeting = (meeting: MeetingSummary): boolean =>
  meeting.status !== "recording";

/**
 * Anexa una página del listado a lo que ya se mostraba, salteando las
 * reuniones que ya están.
 *
 * `list_meetings` pagina por posición (`offset`), así que una reunión nueva
 * insertada arriba corre todas las demás una fila hacia abajo: "cargar más"
 * volvía a traer la última fila de la página anterior y aparecía dos veces
 * (con la misma `key` de React, además). Filtrar por id es barato y arregla
 * el síntoma; la paginación por cursor sería el arreglo de fondo.
 */
export const appendMeetingPage = (
  shown: MeetingSummary[],
  page: MeetingSummary[],
): MeetingSummary[] => {
  const known = new Set(shown.map((meeting) => meeting.id));
  return [...shown, ...page.filter((meeting) => !known.has(meeting.id))];
};

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

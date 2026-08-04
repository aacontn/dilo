import type { MeetingSegment, MeetingSummary } from "@/bindings";

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

/**
 * Agrupa segmentos consecutivos del mismo hablante en un solo bloque visual.
 *
 * Desde la Task 5 del plan "reuniones en streaming", el backend persiste una
 * fila por INTERVENCIÓN atribuida (`AttributedRun`, `align::attribute` en
 * Rust) — cambia de fila cuando cambia quién habla, no por ningún tope de
 * duración (el viejo corte cada `MAX_TURN_MS` de 8 s ya no existe). Aun así
 * una persona puede seguir hablando a través de más de una intervención si
 * hubo un hueco en la diarización de por medio; esto sigue agrupando esas
 * filas en un solo bloque visual para que no se vean como burbujas
 * separadas sin motivo. Cada segmento se sigue guardando como llega; esto
 * sólo cambia cómo se agrupan al mostrarlos.
 *
 * Regla: dos segmentos consecutivos se unen sólo si ambos tienen el mismo
 * `speaker_id` **no nulo**. `speaker_id === null` ("Sin identificar") es al
 * motor negándose a adivinar porque no hay tramo de hablante que cubra ese
 * tramo de texto (FR-004) — unir dos "sin identificar" seguidos amplificaría
 * esa duda como si fuera una sola, cuando son dos juicios inciertos
 * independientes. Nunca se unen, ni entre sí ni con un hablante identificado
 * vecino.
 *
 * `overlapped` viaja con la fusión, con OR, por si algún día vuelve a tener
 * una fuente real de datos (ver M9 del fix round 1 de la Task 5:
 * `StreamingDiarizer` no expone solapes, así que hoy siempre es `false` y
 * este OR es un no-op) — no hay motivo para tratarlo distinto del resto de
 * los campos con la fusión.
 *
 * Al unir, la marca de tiempo mostrada (`started_at_ms`) es la del primer
 * trozo del bloque — es la que ya usa `formatOffset` — y `ended_at_ms` pasa
 * a ser la del último, por si algún consumidor quiere la duración del
 * bloque completo.
 */
export const groupConsecutiveSegments = (
  segments: MeetingSegment[],
): MeetingSegment[] => {
  const grouped: MeetingSegment[] = [];

  for (const segment of segments) {
    const previous = grouped[grouped.length - 1];
    const sameKnownSpeaker =
      previous !== undefined &&
      previous.speaker_id !== null &&
      previous.speaker_id === segment.speaker_id;

    if (sameKnownSpeaker) {
      grouped[grouped.length - 1] = {
        ...previous,
        text: `${previous.text} ${segment.text}`,
        ended_at_ms: segment.ended_at_ms,
        overlapped: previous.overlapped || segment.overlapped,
      };
      continue;
    }

    grouped.push(segment);
  }

  return grouped;
};

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
 * El backend corta un turno cada `MAX_TURN_MS` (8 s, `meeting.rs`) aunque
 * quien habla siga hablando, porque el modelo de segmentación tiene una
 * ventana de 10 s — es un detalle interno de la captura, no una intervención
 * distinta. Sin esto, una persona hablando 20 s seguidos se ve en pantalla
 * como tres o cuatro burbujas separadas. Cada segmento se sigue guardando
 * como llega; esto sólo cambia cómo se agrupan al mostrarlos.
 *
 * Regla: dos segmentos consecutivos se unen sólo si ambos tienen el mismo
 * `speaker_id` **no nulo**. `speaker_id === null` ("Sin identificar") es al
 * motor negándose a adivinar porque la similitud cayó en su banda de duda
 * (FR-004) — unir dos "sin identificar" seguidos amplificaría esa duda como
 * si fuera una sola, cuando son dos juicios inciertos independientes. Nunca
 * se unen, ni entre sí ni con un hablante identificado vecino.
 *
 * `overlapped` (voces encimadas) sí viaja con la fusión, con OR: es una
 * marca de calidad de audio sobre CADA trozo, no una señal de que el trozo
 * sea una intervención aparte. Perderla al fusionar escondería que parte del
 * bloque venía de voz mezclada; con OR el aviso se conserva sin multiplicar
 * bloques.
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

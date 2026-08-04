import React from "react";
import { useTranslation } from "react-i18next";
import { HelpCircle } from "lucide-react";
import type { MeetingSegment } from "@/bindings";
import { Alert } from "../ui/Alert";
import { exceedsSpeakerCap, groupConsecutiveSegments } from "./meetingFormat";

/** Milisegundos -> `m:ss`, relativo al inicio de la reunión. */
export const formatOffset = (ms: number): string => {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
};

/**
 * Paleta de hablantes. Se elige por posición estable del id (no por el id
 * crudo) para que la primera persona que habla sea siempre mango, la segunda
 * menta, etc. — así el color no salta si la base arranca en otro id.
 */
const SPEAKER_TONES = [
  "bg-logo-primary/20 text-text",
  "bg-menta/20 text-success-text",
  "bg-text/[0.08] text-text",
  "bg-rojo/15 text-danger-text",
] as const;

interface SpeakerChipProps {
  segment: MeetingSegment;
  order: number | null;
  name: string | null;
}

const SpeakerChip: React.FC<SpeakerChipProps> = ({ segment, order, name }) => {
  const { t } = useTranslation();

  // FR-004: un segmento sin hablante NO se dibuja como si fuera de alguien.
  // Chip con borde punteado y signo de pregunta: se lee distinto de un
  // hablante identificado incluso de reojo.
  if (segment.speaker_id === null) {
    return (
      <span className="inline-flex shrink-0 items-center gap-1 rounded-full border border-dashed border-mid-gray/50 px-2 py-0.5 text-xs font-medium text-muted-text">
        <HelpCircle className="size-3" />
        {t("meeting.transcript.unknownSpeaker")}
      </span>
    );
  }

  const tone = SPEAKER_TONES[(order ?? 0) % SPEAKER_TONES.length];
  return (
    <span
      className={`inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-xs font-medium ${tone}`}
    >
      {name ??
        t("meeting.transcript.speakerLabel", { number: (order ?? 0) + 1 })}
    </span>
  );
};

interface TranscriptListProps {
  segments: MeetingSegment[];
  /** Nombre puesto por el usuario, por id de hablante (sólo los que lo tienen). */
  speakerNames: Record<number, string>;
  /**
   * `true` mientras la reunión sigue grabando: el diarizador no emite un
   * tramo hasta que el hablante se calla (diseño 2026-08-04), así que el
   * último bloque del listado puede seguir creciendo con la próxima
   * intervención de la misma persona. Ese bloque se distingue del resto —
   * igual que el overlay del dictado separa `tentative` de `committed` —
   * con un cursor parpadeante al final del texto en vez de aparecer como un
   * bloque más, ya cerrado.
   *
   * En una reunión guardada (`MeetingDetail`) no hay nada "en curso": se
   * deja en `false` (default) y todos los bloques se ven cerrados.
   */
  inProgress?: boolean;
}

/**
 * Cuerpo del transcript: un `<article>` por segmento, con su chip de
 * hablante.
 *
 * Extraído de `LiveTranscript` (T018) para que `MeetingDetail` (Historia 4)
 * lo reutilice sin duplicar la lógica de chips — mismo componente para el
 * transcript en vivo, el de una reunión ya guardada y el mini transcript del
 * popover. No trae wrapper propio (ni `divide-y` ni scroll): cada pantalla
 * decide su propio contenedor.
 *
 * Los `segments` que llegan son los que persiste el backend, uno por
 * intervención atribuida (ver el doc comment de `groupConsecutiveSegments`
 * para por qué igual se agrupan acá). Se agrupan en el único punto por el
 * que pasan las tres superficies, para que ninguna tenga que acordarse de
 * hacerlo por su cuenta.
 *
 * M9 del fix round 1 (Task 5, "reuniones en streaming"): la insignia de
 * "voces encimadas" que pintaba `segment.overlapped` se sacó — desde que la
 * diarización en vivo pasó a `StreamingDiarizer`, ese campo queda siempre
 * en `false` (Sortformer ya resuelve los solapes de hablantes ANTES de
 * devolver un tramo, ver `flatten_overlaps` en `sortformer.rs`; no hay
 * ninguna señal de solape que reponer). Dejar la insignia habría sido
 * mentirle al usuario con un "nunca se encimaron voces" que en realidad es
 * "ya no lo sabemos". El campo sigue en el contrato (`MeetingSegment.
 * overlapped`, base de datos incluida) sin cambios — esto es sólo la UI.
 */
export const TranscriptList: React.FC<TranscriptListProps> = ({
  segments,
  speakerNames,
  inProgress = false,
}) => {
  const { t } = useTranslation();
  const groupedSegments = groupConsecutiveSegments(segments);

  // Orden de aparición de cada hablante, para el color y la etiqueta.
  const speakerOrder = new Map<number, number>();
  for (const segment of groupedSegments) {
    if (segment.speaker_id !== null && !speakerOrder.has(segment.speaker_id)) {
      speakerOrder.set(segment.speaker_id, speakerOrder.size);
    }
  }

  // Sortformer degrada pasados los 4 hablantes (ver el doc comment de
  // `exceedsSpeakerCap`) — se calcula sobre TODOS los segmentos, no sólo los
  // agrupados, para no perder de vista a alguien que sólo intervino una vez
  // y quedó fusionado con un bloque vecino.
  const distinctSpeakerIds = segments
    .map((segment) => segment.speaker_id)
    .filter((id): id is number => id !== null);
  const speakerCapNotice = exceedsSpeakerCap(distinctSpeakerIds);

  // Sólo el último bloque puede seguir creciendo: es el único que todavía
  // podría recibir la próxima intervención de la misma persona.
  const lastIndex = groupedSegments.length - 1;

  return (
    <>
      {speakerCapNotice && (
        <Alert variant="info" contained>
          {t("meeting.transcript.speakerCapReached")}
        </Alert>
      )}
      {groupedSegments.map((segment, index) => {
        const open = inProgress && index === lastIndex;
        return (
          <article
            key={segment.id}
            className="flex items-start gap-3 px-4 py-3"
          >
            <time className="mt-0.5 shrink-0 font-mono text-xs text-muted-text tabular-nums">
              {formatOffset(segment.started_at_ms)}
            </time>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <SpeakerChip
                  segment={segment}
                  order={
                    segment.speaker_id === null
                      ? null
                      : (speakerOrder.get(segment.speaker_id) ?? 0)
                  }
                  name={
                    segment.speaker_id === null
                      ? null
                      : (speakerNames[segment.speaker_id] ?? null)
                  }
                />
              </div>
              <p className="mt-1 text-sm leading-relaxed text-text">
                {segment.text}
                {/* Bloque en curso: mismo cursor parpadeante que separa
                    `tentative` de `committed` en el overlay del dictado —
                    acá dice "esto todavía puede crecer", no "esto es
                    provisorio" (el texto ya está persistido). */}
                {open && (
                  <span
                    aria-hidden="true"
                    className="dilo-transcript-caret ml-0.5"
                  />
                )}
              </p>
            </div>
          </article>
        );
      })}
    </>
  );
};

import React from "react";
import { useTranslation } from "react-i18next";
import { HelpCircle } from "lucide-react";
import type { MeetingSegment } from "@/bindings";

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
}

/**
 * Cuerpo del transcript: un `<article>` por segmento, con su chip de
 * hablante y la marca de voces encimadas.
 *
 * Extraído de `LiveTranscript` (T018) para que `MeetingDetail` (Historia 4)
 * lo reutilice sin duplicar la lógica de chips — mismo componente para el
 * transcript en vivo y el de una reunión ya guardada. No trae wrapper propio
 * (ni `divide-y` ni scroll): cada pantalla decide su propio contenedor.
 */
export const TranscriptList: React.FC<TranscriptListProps> = ({
  segments,
  speakerNames,
}) => {
  const { t } = useTranslation();

  // Orden de aparición de cada hablante, para el color y la etiqueta.
  const speakerOrder = new Map<number, number>();
  for (const segment of segments) {
    if (segment.speaker_id !== null && !speakerOrder.has(segment.speaker_id)) {
      speakerOrder.set(segment.speaker_id, speakerOrder.size);
    }
  }

  return (
    <>
      {segments.map((segment) => (
        <article key={segment.id} className="flex items-start gap-3 px-4 py-3">
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
              {segment.overlapped && (
                <span className="text-xs text-muted-text">
                  {t("meeting.transcript.overlapped")}
                </span>
              )}
            </div>
            <p className="mt-1 text-sm leading-relaxed text-text">
              {segment.text}
            </p>
          </div>
        </article>
      ))}
    </>
  );
};

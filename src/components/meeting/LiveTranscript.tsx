import React, { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { HelpCircle, Users2 } from "lucide-react";
import type { MeetingSegment } from "@/bindings";
import { useMeetings } from "../../hooks/useMeetings";

/** Milisegundos -> `m:ss`, relativo al inicio de la reunión. */
const formatOffset = (ms: number): string => {
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

/**
 * Transcript en vivo (T018): los segmentos aparecen a medida que el backend
 * los transcribe y persiste, con su hablante o marcados como inciertos.
 */
export const LiveTranscript: React.FC = () => {
  const { t } = useTranslation();
  const { segments, speakerNames, isRecording, isProcessing } = useMeetings();
  const bottomRef = useRef<HTMLDivElement>(null);

  // Seguir el hilo mientras la reunión corre. Al terminar deja de auto
  // scrollear para no pelear con quien está releyendo.
  useEffect(() => {
    if (!isRecording && !isProcessing) return;
    bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [segments.length, isRecording, isProcessing]);

  // Orden de aparición de cada hablante, para el color y la etiqueta.
  const speakerOrder = new Map<number, number>();
  for (const segment of segments) {
    if (segment.speaker_id !== null && !speakerOrder.has(segment.speaker_id)) {
      speakerOrder.set(segment.speaker_id, speakerOrder.size);
    }
  }

  return (
    <section>
      <div className="mb-3 flex items-end justify-between">
        <div>
          <h2 className="font-semibold text-base text-text">
            {t("meeting.transcript.title")}
          </h2>
          <p className="text-xs text-muted-text">
            {t("meeting.transcript.subtitle")}
          </p>
        </div>
        {speakerOrder.size > 0 && (
          <span className="inline-flex items-center gap-1.5 text-xs text-muted-text">
            <Users2 className="size-4" />
            {t("meeting.transcript.speakerCount", { count: speakerOrder.size })}
          </span>
        )}
      </div>

      <div className="glass-surface max-h-[26rem] overflow-y-auto rounded-xl">
        {segments.length === 0 ? (
          <div className="px-4 py-8 text-center text-sm text-muted-text">
            {isRecording
              ? t("meeting.transcript.listening")
              : t("meeting.transcript.empty")}
          </div>
        ) : (
          <div className="divide-y divide-mid-gray/15">
            {segments.map((segment) => (
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
            <div ref={bottomRef} />
          </div>
        )}
      </div>
    </section>
  );
};

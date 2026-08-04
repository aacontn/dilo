import React, { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { Users2 } from "lucide-react";
import { useMeetings } from "../../hooks/useMeetings";
import { TranscriptList } from "./TranscriptList";

/**
 * Transcript en vivo (T018): los segmentos aparecen a medida que el backend
 * los transcribe y persiste, con su hablante o marcados como inciertos.
 *
 * El cuerpo del transcript (chips de hablante, offsets) vive en
 * `TranscriptList`, compartido con `MeetingDetail` (Historia 4) — acá sólo
 * queda lo propio de estar en vivo: auto scroll y los estados vacío/
 * escuchando.
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

  // Cuántos hablantes distintos llevan la cuenta, para el contador del
  // header (la propia lista recalcula el orden para pintar los chips).
  const speakerCount = new Set(
    segments
      .map((segment) => segment.speaker_id)
      .filter((id): id is number => id !== null),
  ).size;

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
        {speakerCount > 0 && (
          <span className="inline-flex items-center gap-1.5 text-xs text-muted-text">
            <Users2 className="size-4" />
            {t("meeting.transcript.speakerCount", { count: speakerCount })}
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
            <TranscriptList
              segments={segments}
              speakerNames={speakerNames}
              inProgress={isRecording}
            />
            <div ref={bottomRef} />
          </div>
        )}
      </div>
    </section>
  );
};

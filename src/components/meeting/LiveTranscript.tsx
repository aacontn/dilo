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
  const { segments, pendingSegments, speakerNames, isRecording, isProcessing } =
    useMeetings();
  const bottomRef = useRef<HTMLDivElement>(null);

  // Lo cerrado y lo que se está diciendo ahora, en un solo hilo: los
  // pendientes van siempre al final (son lo más reciente por construcción) y
  // se distinguen porque el último bloque lleva el cursor de "en curso".
  // Claves negativas para no chocar con los `id` reales de la base — los
  // pendientes todavía no tienen fila, así que llegan todos con `id: 0`.
  const shownSegments = React.useMemo(
    () => [
      ...segments,
      ...pendingSegments.map((segment, index) => ({
        ...segment,
        id: -1 - index,
      })),
    ],
    [segments, pendingSegments],
  );

  // Seguir el hilo mientras la reunión corre. Al terminar deja de auto
  // scrollear para no pelear con quien está releyendo.
  useEffect(() => {
    if (!isRecording && !isProcessing) return;
    bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [shownSegments.length, isRecording, isProcessing]);

  // Cuántos hablantes distintos llevan la cuenta, para el contador del
  // header (la propia lista recalcula el orden para pintar los chips).
  const speakerCount = new Set(
    shownSegments
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
        {shownSegments.length === 0 ? (
          <div className="px-4 py-8 text-center text-sm text-muted-text">
            {isRecording
              ? t("meeting.transcript.listening")
              : t("meeting.transcript.empty")}
          </div>
        ) : (
          <div className="divide-y divide-mid-gray/15">
            <TranscriptList
              segments={shownSegments}
              speakerNames={speakerNames}
              inProgress={pendingSegments.length > 0}
            />
            <div ref={bottomRef} />
          </div>
        )}
      </div>
    </section>
  );
};

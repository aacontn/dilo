import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { LockKeyhole, Mic, Square, Users } from "lucide-react";
import { toast } from "sonner";
import { Button } from "../ui/Button";
import { useMeetings } from "../../hooks/useMeetings";

/**
 * Controles de grabación de una reunión presencial (T017).
 *
 * Espeja el lenguaje de la tarjeta de estado del home: superficie de vidrio,
 * punto de color + etiqueta en versalitas, titular grande y una línea de
 * privacidad. La reunión virtual (Historia 2) todavía no existe, así que no
 * hay selector de tipo — agregarlo es T025, cuando la opción signifique algo.
 */
export const RecordingControls: React.FC = () => {
  const { t } = useTranslation();
  const {
    isRecording,
    isProcessing,
    isStarting,
    isStopping,
    segments,
    startMeeting,
    stopMeeting,
  } = useMeetings();
  const [elapsedLabel, setElapsedLabel] = useState<string | null>(null);

  // Cronómetro simple mientras graba: el tiempo lo marca el propio
  // transcript (último segmento recibido), no un timer propio — así lo que
  // se muestra es lo que de verdad quedó guardado.
  React.useEffect(() => {
    if (!isRecording && !isProcessing) {
      setElapsedLabel(null);
      return;
    }
    const last = segments[segments.length - 1];
    if (!last) {
      setElapsedLabel(null);
      return;
    }
    const totalSeconds = Math.floor(last.ended_at_ms / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    setElapsedLabel(`${minutes}:${String(seconds).padStart(2, "0")}`);
  }, [segments, isRecording, isProcessing]);

  const handleStart = async () => {
    try {
      await startMeeting("presencial");
    } catch (error) {
      toast.error(t("meeting.controls.startFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const handleStop = async () => {
    try {
      await stopMeeting();
    } catch (error) {
      toast.error(t("meeting.controls.stopFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const stateLabel = isRecording
    ? t("meeting.controls.stateRecording")
    : isProcessing
      ? t("meeting.controls.stateProcessing")
      : t("meeting.controls.stateIdle");

  return (
    <section className="glass-surface overflow-hidden rounded-xl">
      <div className="p-5">
        <div
          className={`flex items-center gap-2 ${
            isRecording ? "text-danger-text" : "text-success-text"
          }`}
        >
          <span
            className={`size-2 rounded-full ${
              isRecording ? "bg-rojo dilo-meeting-pulse" : "bg-menta"
            }`}
          />
          <span className="text-xs font-semibold uppercase tracking-[0.14em]">
            {stateLabel}
          </span>
          {elapsedLabel && (
            <span className="ml-auto font-mono text-xs text-muted-text tabular-nums">
              {elapsedLabel}
            </span>
          )}
        </div>

        <h2 className="mt-3 font-display text-2xl font-semibold text-text">
          {isRecording
            ? t("meeting.controls.recordingTitle")
            : isProcessing
              ? t("meeting.controls.processingTitle")
              : t("meeting.controls.idleTitle")}
        </h2>
        <p className="mt-1 max-w-xl text-sm text-text/60">
          {isRecording
            ? t("meeting.controls.recordingDescription")
            : isProcessing
              ? t("meeting.controls.processingDescription")
              : t("meeting.controls.idleDescription")}
        </p>

        <div className="mt-5 flex flex-wrap items-center gap-3">
          {isRecording || isProcessing ? (
            <Button
              variant="danger"
              size="lg"
              onClick={handleStop}
              disabled={isStopping || isProcessing}
              className="flex items-center gap-2"
            >
              <Square className="size-4" />
              {isProcessing
                ? t("meeting.controls.finishing")
                : t("meeting.controls.stop")}
            </Button>
          ) : (
            <Button
              variant="primary"
              size="lg"
              onClick={handleStart}
              disabled={isStarting}
              className="flex items-center gap-2"
            >
              <Mic className="size-4" />
              {isStarting
                ? t("meeting.controls.starting")
                : t("meeting.controls.start")}
            </Button>
          )}
          <span className="inline-flex items-center gap-2 text-xs text-muted-text">
            <Users className="size-4 shrink-0" />
            {t("meeting.controls.kindPresencial")}
          </span>
        </div>

        <div className="mt-5 flex items-center gap-2 text-xs text-muted-text">
          <LockKeyhole className="size-4 shrink-0" />
          {t("meeting.controls.privacy")}
        </div>
      </div>
    </section>
  );
};

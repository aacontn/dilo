import React, { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Cpu, LockKeyhole, Mic, MonitorSpeaker, Square } from "lucide-react";
import { toast } from "sonner";
import { Button } from "../ui/Button";
import { useMeetings } from "../../hooks/useMeetings";
import { useModelStore } from "../../stores/modelStore";
import { useSettings } from "../../hooks/useSettings";
import { commands, type MeetingAudioSource } from "@/bindings";

/**
 * Controles de grabación de una reunión presencial (T017).
 *
 * Espeja el lenguaje de la tarjeta de estado del home: superficie de vidrio,
 * punto de color + etiqueta en versalitas, titular grande y una línea de
 * privacidad. La reunión virtual (Historia 2) todavía no existe, así que no
 * hay selector de tipo — agregarlo es T025, cuando la opción signifique algo.
 *
 * **Cableado de audio de reuniones:** sí trae un selector — no de tipo de
 * reunión, sino de FUENTE de audio (audio de este equipo vs. micrófono, ver
 * `settings.meeting_audio_source` en el backend). Antes de grabar el usuario
 * tiene que ver cuál se va a usar y poder cambiarla; mientras graba queda
 * fijo, cambiarla a mitad de sesión no tiene efecto sobre la captura en
 * curso.
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
  const { settings, updateSetting } = useSettings();

  // Si esta máquina soporta el audio del computador (macOS 14.2+, ver
  // `is_system_audio_available` en Rust). `null` mientras se consulta: no
  // queremos parpadear la opción de "no disponible" en el primer render.
  // Fuera de macOS, o en una versión vieja, la interfaz no debe ofrecer una
  // opción que de todas formas va a resolver a micrófono en el backend
  // (`resolve_meeting_audio_source`) — se oculta en vez de mostrarla
  // deshabilitada, porque no hay nada que el usuario pueda hacer desde acá
  // para habilitarla.
  const [systemAudioAvailable, setSystemAudioAvailable] = useState<
    boolean | null
  >(null);
  useEffect(() => {
    let cancelled = false;
    void commands.isSystemAudioAvailable().then((available) => {
      if (!cancelled) setSystemAudioAvailable(available);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const audioSource: MeetingAudioSource =
    settings?.meeting_audio_source ?? "system_audio";
  const canChangeAudioSource = !isRecording && !isProcessing;
  const setAudioSource = (source: MeetingAudioSource) => {
    if (!canChangeAudioSource || source === audioSource) return;
    void updateSetting("meeting_audio_source", source);
  };

  // Qué modelo STT graba la reunión — mismo modelo que el dictado normal
  // (managers/meeting.rs reusa el TranscriptionManager compartido, no uno
  // propio de reuniones). Alfonso no sabía qué modelo estaba usando al
  // grabar; esto lo deja a la vista sin abrir Ajustes.
  const { currentModel, models } = useModelStore();
  const activeModelName = useMemo(
    () => models.find((model) => model.id === currentModel)?.name,
    [currentModel, models],
  );

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
            {audioSource === "system_audio" ? (
              <MonitorSpeaker className="size-4 shrink-0" />
            ) : (
              <Mic className="size-4 shrink-0" />
            )}
            {audioSource === "system_audio"
              ? t("meeting.controls.kindOnlineSystemAudio")
              : t("meeting.controls.kindPresencial")}
          </span>
        </div>

        <div className="mt-3 flex flex-col gap-1.5">
          <span className="text-xs font-medium text-muted-text">
            {t("meeting.controls.audioSourceHeading")}
          </span>
          <div className="flex flex-wrap items-center gap-2">
            {systemAudioAvailable !== false && (
              <Button
                type="button"
                variant={
                  audioSource === "system_audio" ? "primary-soft" : "ghost"
                }
                size="sm"
                disabled={!canChangeAudioSource}
                onClick={() => setAudioSource("system_audio")}
                className="flex items-center gap-1.5"
              >
                <MonitorSpeaker className="size-3.5" />
                {t("meeting.controls.audioSourceSystemOption")}
              </Button>
            )}
            <Button
              type="button"
              variant={audioSource === "microphone" ? "primary-soft" : "ghost"}
              size="sm"
              disabled={!canChangeAudioSource}
              onClick={() => setAudioSource("microphone")}
              className="flex items-center gap-1.5"
            >
              <Mic className="size-3.5" />
              {t("meeting.controls.audioSourceMicrophoneOption")}
            </Button>
          </div>
          {systemAudioAvailable === false && (
            <p className="text-xs text-muted-text/70">
              {t("meeting.controls.audioSourceUnavailable")}
            </p>
          )}
        </div>

        <div className="mt-2 flex items-center gap-2 text-xs text-muted-text">
          <Cpu className="size-4 shrink-0" />
          {activeModelName
            ? t("meeting.controls.model", { name: activeModelName })
            : t("meeting.controls.modelLoading")}
        </div>

        <div className="mt-5 flex items-center gap-2 text-xs text-muted-text">
          <LockKeyhole className="size-4 shrink-0" />
          {t("meeting.controls.privacy")}
        </div>
      </div>
    </section>
  );
};

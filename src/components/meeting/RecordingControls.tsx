import React, { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Cpu, LockKeyhole, Mic, MonitorSpeaker, Square } from "lucide-react";
import { toast } from "sonner";
import { Button } from "../ui/Button";
import { useMeetings } from "../../hooks/useMeetings";
import { useModelStore } from "../../stores/modelStore";
import { useSettings } from "../../hooks/useSettings";
import { commands, type MeetingAudioSource } from "@/bindings";
import type { MeetingKind } from "../../stores/meetingStore";

/**
 * Deriva la fuente de audio que el backend va a usar REALMENTE, mismo
 * criterio que `managers::meeting::resolve_meeting_audio_source` en Rust
 * (I3 del reporte de cableado de audio: la interfaz tiene que mostrar lo que
 * de verdad va a grabar, no un ajuste que puede quedar incoherente).
 * `systemAudioAvailable === null` (todavía consultando) se trata como
 * disponible para no parpadear al primer render — igual criterio que ya
 * usaba este componente para el botón de "audio de este equipo".
 */
const resolveDisplayedAudioSource = (
  kind: MeetingKind,
  systemAudioAvailable: boolean | null,
): MeetingAudioSource =>
  kind === "virtual" && systemAudioAvailable !== false
    ? "system_audio"
    : "microphone";

/** `settings.meeting_audio_source` sólo recuerda la última elección para
 * preseleccionarla (ver su doc comment en `settings.rs`) — este componente
 * es el único lugar que la traduce de/a un tipo de reunión. */
const kindFromPersistedSource = (
  source: MeetingAudioSource | undefined,
): MeetingKind => (source === "microphone" ? "presencial" : "virtual");
const sourceFromKind = (kind: MeetingKind): MeetingAudioSource =>
  kind === "presencial" ? "microphone" : "system_audio";

/**
 * Clave de traducción para el indicador de arriba (icono + texto junto al
 * botón de grabar). Tres combinaciones reales, no dos: una reunión online
 * en una máquina sin audio de sistema (Windows, Linux, macOS viejo) graba
 * con el micrófono igual que una presencial, pero SIGUE siendo una reunión
 * online — reusar el texto de "Presencial" ahí sería mentir sobre el tipo,
 * no sólo sobre la fuente. `audioSourceUnavailable` (más abajo, junto al
 * selector) ya explica el porqué del micrófono en ese caso.
 */
const resolveIndicatorLabelKey = (
  kind: MeetingKind,
  displayedAudioSource: MeetingAudioSource,
): string => {
  if (kind === "presencial") return "meeting.controls.kindPresencial";
  return displayedAudioSource === "system_audio"
    ? "meeting.controls.kindOnlineSystemAudio"
    : "meeting.controls.kindOnlineMicrophoneFallback";
};

/**
 * Controles de grabación de una reunión (T017; selector de tipo agregado
 * por el cableado de audio de reuniones).
 *
 * Espeja el lenguaje de la tarjeta de estado del home: superficie de vidrio,
 * punto de color + etiqueta en versalitas, titular grande y una línea de
 * privacidad.
 *
 * **Una sola perilla, no dos.** El selector es de TIPO de reunión
 * (presencial / online), no de fuente de audio — el mandato del dueño es
 * "por el audio del computador, no del micrófono; el micrófono sólo como
 * opción para presencial". La fuente real se deduce del tipo elegido
 * (`resolveDisplayedAudioSource`, espejo de `resolve_meeting_audio_source`
 * en Rust) y es lo que decide qué icono/copy se muestra arriba — no el
 * ajuste persistido crudo, que en una máquina sin audio de sistema
 * disponible puede seguir diciendo "online" aunque la grabación real vaya a
 * usar el micrófono. Antes de grabar el usuario tiene que ver cuál se va a
 * usar; mientras graba el selector queda fijo, cambiarlo a mitad de sesión
 * no tiene efecto sobre la captura en curso.
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
  // queremos parpadear el aviso de "no disponible" en el primer render.
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

  const meetingKind: MeetingKind = kindFromPersistedSource(
    settings?.meeting_audio_source,
  );
  const displayedAudioSource = resolveDisplayedAudioSource(
    meetingKind,
    systemAudioAvailable,
  );
  const canChangeMeetingKind = !isRecording && !isProcessing;
  const setMeetingKind = (kind: MeetingKind) => {
    if (!canChangeMeetingKind || kind === meetingKind) return;
    void updateSetting("meeting_audio_source", sourceFromKind(kind));
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
      // M2 del reporte de cableado de audio: se manda el `kind` que
      // realmente eligió el usuario en el selector de abajo — antes esto
      // estaba fijo en `"presencial"` sin importar lo que mostrara la
      // interfaz.
      await startMeeting(meetingKind);
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
            {displayedAudioSource === "system_audio" ? (
              <MonitorSpeaker className="size-4 shrink-0" />
            ) : (
              <Mic className="size-4 shrink-0" />
            )}
            {t(resolveIndicatorLabelKey(meetingKind, displayedAudioSource))}
          </span>
        </div>

        <div className="mt-3 flex flex-col gap-1.5">
          <span className="text-xs font-medium text-muted-text">
            {t("meeting.controls.audioSourceHeading")}
          </span>
          <div className="flex flex-wrap items-center gap-2">
            {/* I3 del reporte de cableado: las dos opciones son de TIPO de
                reunión, no de fuente — "Online" queda visible incluso donde
                el audio de sistema no existe (Windows, Linux, macOS viejo),
                porque sigue siendo un tipo de reunión válido; el aviso de
                abajo explica que ahí graba con el micrófono igual. */}
            <Button
              type="button"
              variant={meetingKind === "virtual" ? "primary-soft" : "ghost"}
              size="sm"
              disabled={!canChangeMeetingKind}
              onClick={() => setMeetingKind("virtual")}
              className="flex items-center gap-1.5"
            >
              <MonitorSpeaker className="size-3.5" />
              {t("meeting.controls.audioSourceSystemOption")}
            </Button>
            <Button
              type="button"
              variant={meetingKind === "presencial" ? "primary-soft" : "ghost"}
              size="sm"
              disabled={!canChangeMeetingKind}
              onClick={() => setMeetingKind("presencial")}
              className="flex items-center gap-1.5"
            >
              <Mic className="size-3.5" />
              {t("meeting.controls.audioSourceMicrophoneOption")}
            </Button>
          </div>
          {systemAudioAvailable === false && meetingKind === "virtual" && (
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

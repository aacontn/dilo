import React, { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Cpu, LockKeyhole, Mic, MonitorSpeaker, Square } from "lucide-react";
import { toast } from "sonner";
import { Button } from "../ui/Button";
import { useMeetings } from "../../hooks/useMeetings";
import { useModelStore } from "../../stores/modelStore";
import { useSettings } from "../../hooks/useSettings";
import { commands } from "@/bindings";
import {
  isNoActiveMeetingError,
  isRecordingBusyError,
  modelNoTimestampsErrorModelId,
  modelNotStreamingErrorModelId,
} from "@/lib/meetingErrors";
import {
  kindFromPersistedSource,
  resolveDisplayedAudioSource,
  resolveIndicatorLabelKey,
  sourceFromKind,
} from "@/lib/meetingKind";
import type { MeetingKind } from "../../stores/meetingStore";

/**
 * Qué modelo STT va a usar la reunión REALMENTE — mismo criterio que
 * `resolve_meeting_model_id` en `managers/meeting.rs`: el propio de
 * reuniones (`settings.meeting_model_id`) si el usuario eligió uno, si no
 * el del dictado. Vacío o sólo espacios cuenta como "sin elegir" y también
 * hereda, igual que en Rust.
 *
 * Antes esta pantalla mostraba directamente `currentModel` de
 * `useModelStore` — el modelo de DICTADO — sin mirar este ajuste para nada.
 * Ésa era, al menos en parte, la causa del reporte "cambio el modelo de la
 * reunión y no cambia en la reunión": la etiqueta mentía sobre cuál se iba
 * a usar de verdad.
 */
const resolveMeetingModelId = (
  meetingModelId: string | null | undefined,
  dictationModelId: string,
): string => {
  const trimmed = meetingModelId?.trim();
  return trimmed ? trimmed : dictationModelId;
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

  // Qué modelo STT va a grabar la reunión — el propio de reuniones si el
  // usuario eligió uno en la tarjeta del popover (`settings.meeting_model_id`),
  // si no el del dictado (ver `resolveMeetingModelId` arriba, espejo de
  // `resolve_meeting_model_id` en Rust). Alfonso no sabía qué modelo estaba
  // usando al grabar; esto lo deja a la vista sin abrir Ajustes.
  const { currentModel, models } = useModelStore();
  const meetingModelId = useMemo(
    () => resolveMeetingModelId(settings?.meeting_model_id, currentModel),
    [settings?.meeting_model_id, currentModel],
  );
  const activeModelName = useMemo(
    () => models.find((model) => model.id === meetingModelId)?.name,
    [meetingModelId, models],
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
      // `recording_busy` no debería llegar acá en el uso normal —
      // `useMeetingActiveSync` (montado en `MeetingSession`) ya adopta una
      // reunión en curso apenas la detecta, así que este botón debería
      // haber cambiado a "detener" antes. Queda como red de seguridad ante
      // una carrera (la otra ventana empezó una reunión un instante antes
      // de que se resolviera la sincronización acá) — mismo mensaje que usa
      // el popover para el mismo caso (`isRecordingBusyError`).
      if (isRecordingBusyError(error)) {
        toast.error(t("meeting.errors.recordingBusy"), {
          description: t("meeting.errors.recordingBusyDescription"),
        });
        return;
      }
      // El modelo resuelto para la reunión (propio o heredado del dictado,
      // ver `resolveMeetingModelId` arriba) no soporta streaming — desde la
      // Task 5 ese es el único camino de texto, así que grabar con uno así
      // no perdía turnos: no guardaba nada. El popover ya filtra el
      // selector de modelos de reunión a los que sirven, pero el heredado
      // del dictado puede seguir sin soportarlo, así que este chequeo
      // igual hace falta acá.
      const badModelId = modelNotStreamingErrorModelId(error);
      if (badModelId !== null) {
        const badModelName =
          models.find((model) => model.id === badModelId)?.name ?? badModelId;
        toast.error(t("meeting.errors.modelNotStreaming"), {
          description: t("meeting.errors.modelNotStreamingDescription", {
            name: badModelName,
          }),
        });
        return;
      }
      // El otro rechazo del mismo chequeo: hace streaming pero no entrega
      // marcas de tiempo por token, así que no hay con qué pegarle el texto
      // a cada hablante y la reunión no guardaría nada.
      const noTimestampsModelId = modelNoTimestampsErrorModelId(error);
      if (noTimestampsModelId !== null) {
        const badModelName =
          models.find((model) => model.id === noTimestampsModelId)?.name ??
          noTimestampsModelId;
        toast.error(t("meeting.errors.modelNotStreaming"), {
          description: t("meeting.errors.modelNoTimestampsDescription", {
            name: badModelName,
          }),
        });
        return;
      }
      toast.error(t("meeting.controls.startFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const handleStop = async () => {
    try {
      await stopMeeting();
    } catch (error) {
      // Apretar detener sin ninguna reunión viva (ni acá ni en el backend):
      // antes esto era un `return` mudo dentro del store y el botón no hacía
      // absolutamente nada, ni siquiera avisar. Ahora se dice.
      if (isNoActiveMeetingError(error)) {
        toast.error(t("meeting.controls.stopFailed"), {
          description: t("meeting.errors.noActiveMeeting"),
        });
        return;
      }
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

import { useCallback, useEffect } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { events, type MeetingSegment } from "@/bindings";
import { useMeetingStore, type MeetingKind } from "../stores/meetingStore";

interface UseMeetingsReturn {
  activeMeetingId: number | null;
  isRecording: boolean;
  isProcessing: boolean;
  isStarting: boolean;
  isStopping: boolean;
  segments: MeetingSegment[];
  speakerNames: Record<number, string>;

  startMeeting: (kind: MeetingKind) => Promise<void>;
  stopMeeting: () => Promise<void>;
  setSpeakerName: (speakerId: number, name: string) => void;
  reset: () => void;
}

/**
 * Suscripción a los eventos de reunión del backend.
 *
 * **Va en UN solo componente** (hoy `MeetingSession`), no en `useMeetings`:
 * si viviera en el hook de estado, cada componente que lo usa montaría su
 * propio listener y cada segmento entraría al transcript tantas veces como
 * componentes haya en pantalla. El transcript mostraba cada línea tres
 * veces por exactamente eso.
 *
 * El transcript llega por `meeting-segment` a medida que cada turno se
 * transcribe (FR-002), y los segmentos que quedaron en la cola siguen
 * llegando **después** de apretar detener, hasta que `meeting-finished`
 * cierra la sesión.
 */
export const useMeetingEvents = (): void => {
  const { t } = useTranslation();
  const appendSegment = useMeetingStore((state) => state.appendSegment);
  const markFinished = useMeetingStore((state) => state.markFinished);
  const markErrored = useMeetingStore((state) => state.markErrored);

  useEffect(() => {
    const unlistenSegment = events.meetingSegment.listen((event) => {
      appendSegment(event.payload);
    });
    const unlistenFinished = events.meetingFinished.listen(() => {
      markFinished();
    });
    // Un `meeting-error` era sólo un console.error: la pantalla quedaba en
    // "Cerrando…" para siempre y no se podía grabar otra reunión. Ahora se
    // dice lo que pasó y la sesión vuelve a estar disponible.
    //
    // Este evento significa que la sesión terminó: el backend sólo lo emite
    // cuando la captura ya no corre o se está cerrando. Por eso acá sí
    // corresponde limpiar la sesión.
    const unlistenError = events.meetingError.listen((event) => {
      console.error("Meeting error:", event.payload.error);
      toast.error(t("meeting.errors.sessionFailed"), {
        description: event.payload.error,
      });
      markErrored();
    });
    // Un turno perdido NO termina la reunión: se avisa y listo. Limpiar la
    // sesión acá le sacaba al usuario el botón de detener mientras el
    // micrófono seguía abierto, sin más salida que reiniciar la app.
    const unlistenTurnFailed = events.meetingTurnFailed.listen((event) => {
      console.error("Meeting turn failed:", event.payload.error);
      toast.warning(t("meeting.errors.turnFailed"), {
        description: event.payload.error,
      });
    });
    // Cableado de audio de reuniones: falta el permiso de audio del sistema,
    // o cambió el dispositivo de salida a mitad de reunión (ver
    // `MeetingAudioWarningKind` en Rust). Ninguno de los dos termina la
    // sesión — el backend ya avisa como máximo una vez por tipo y por
    // sesión, así que acá no hace falta deduplicar de nuevo.
    const unlistenAudioWarning = events.meetingAudioWarning.listen((event) => {
      console.warn("Meeting audio warning:", event.payload.kind);
      if (event.payload.kind === "missing_permission") {
        toast.warning(t("meeting.errors.audioMissingPermission"), {
          description: t("meeting.errors.audioMissingPermissionDescription"),
          duration: 15000,
        });
      } else {
        toast.warning(t("meeting.errors.audioOutputDeviceChanged"), {
          description: t("meeting.errors.audioOutputDeviceChangedDescription"),
        });
      }
    });

    return () => {
      void unlistenSegment.then((fn) => fn());
      void unlistenFinished.then((fn) => fn());
      void unlistenError.then((fn) => fn());
      void unlistenTurnFailed.then((fn) => fn());
      void unlistenAudioWarning.then((fn) => fn());
    };
  }, [appendSegment, markFinished, markErrored, t]);
};

/** Estado y acciones de la sesión en curso. No suscribe a nada. */
export const useMeetings = (): UseMeetingsReturn => {
  const {
    activeMeetingId,
    status,
    segments,
    speakerNames,
    isStarting,
    isStopping,
    startMeeting,
    stopMeeting,
    setSpeakerName,
    reset,
  } = useMeetingStore();

  const start = useCallback(
    (kind: MeetingKind) => startMeeting(kind),
    [startMeeting],
  );

  return {
    activeMeetingId,
    isRecording: status === "recording",
    isProcessing: status === "processing",
    isStarting,
    isStopping,
    segments,
    speakerNames,
    startMeeting: start,
    stopMeeting,
    setSpeakerName,
    reset,
  };
};

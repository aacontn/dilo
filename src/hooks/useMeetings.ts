import { useCallback, useEffect } from "react";
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
  const appendSegment = useMeetingStore((state) => state.appendSegment);
  const markFinished = useMeetingStore((state) => state.markFinished);

  useEffect(() => {
    const unlistenSegment = events.meetingSegment.listen((event) => {
      appendSegment(event.payload);
    });
    const unlistenFinished = events.meetingFinished.listen(() => {
      markFinished();
    });
    const unlistenError = events.meetingError.listen((event) => {
      console.error("Meeting error:", event.payload.error);
    });

    return () => {
      void unlistenSegment.then((fn) => fn());
      void unlistenFinished.then((fn) => fn());
      void unlistenError.then((fn) => fn());
    };
  }, [appendSegment, markFinished]);
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

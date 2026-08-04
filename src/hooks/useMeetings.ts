import { useCallback, useEffect } from "react";
import type { TFunction } from "i18next";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  commands,
  events,
  type MeetingAudioWarningKind,
  type MeetingSegment,
} from "@/bindings";
import { useActiveMeeting } from "@/lib/activeMeeting";
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
 * Un solo toast por tipo de aviso de audio de reunión — lo usan tanto el
 * listener en vivo (ventana de Reuniones a la vista) como el vaciado de la
 * cola de pendientes al montar/recuperar el foco (I5 del reporte de
 * seguimiento), así el aviso se ve igual llegue por el camino que llegue.
 * Mismo patrón que `showAssistantErrorToast` en `App.tsx`.
 */
const showAudioWarningToast = (
  t: TFunction,
  kind: MeetingAudioWarningKind,
): void => {
  console.warn("Meeting audio warning:", kind);
  switch (kind) {
    case "missing_permission":
      toast.warning(t("meeting.errors.audioMissingPermission"), {
        description: t("meeting.errors.audioMissingPermissionDescription"),
        duration: 15000,
      });
      break;
    case "output_device_changed":
      toast.warning(t("meeting.errors.audioOutputDeviceChanged"), {
        description: t("meeting.errors.audioOutputDeviceChangedDescription"),
      });
      break;
    case "no_audio_captured":
      toast.warning(t("meeting.errors.audioNoAudioCaptured"), {
        description: t("meeting.errors.audioNoAudioCapturedDescription"),
        duration: 15000,
      });
      break;
    case "fell_back_to_microphone":
      toast.warning(t("meeting.errors.audioFellBackToMicrophone"), {
        description: t("meeting.errors.audioFellBackToMicrophoneDescription"),
      });
      break;
  }
};

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
    // Cableado de audio de reuniones: falta el permiso, varios minutos sin
    // capturar nada real, cambió el dispositivo de salida, o se cayó a
    // micrófono al abrir (ver `MeetingAudioWarningKind` en Rust). Ninguno
    // termina la sesión — el backend ya avisa como máximo una vez por tipo
    // y por sesión, así que acá no hace falta deduplicar de nuevo.
    const unlistenAudioWarning = events.meetingAudioWarning.listen((event) => {
      showAudioWarningToast(t, event.payload.kind);
    });

    // I5 del reporte de seguimiento: el flujo esperado es grabar y volver a
    // la videollamada, y tanto `return_to_main_window` como el botón de
    // cerrar de esta ventana la ESCONDEN (`window.hide()`) en vez de
    // destruirla — el webview (y este listener) sigue vivo, pero un aviso
    // que llega mientras está escondida dibuja su toast en una ventana que
    // nadie mira, y como el backend lo emite una sola vez por tipo, se
    // pierde para siempre. `take_pending_meeting_audio_notices` es la cola
    // que lo sobrevive (mismo patrón que `PendingFallbackNotices`/
    // `PendingAssistantNotices` en `App.tsx`): se vacía al montar (cubre la
    // primera apertura) y cada vez que esta ventana recupera el foco (cubre
    // reabrir después de escondida) — a diferencia del popover, esta
    // ventana no se remonta al reabrir, así que "al montar" solo no
    // alcanza.
    const drainPendingAudioWarnings = () => {
      void commands.takePendingMeetingAudioNotices().then((pending) => {
        for (const notice of pending) {
          showAudioWarningToast(t, notice.kind);
        }
      });
    };
    drainPendingAudioWarnings();
    const win = getCurrentWindow();
    const unlistenFocus = win.onFocusChanged(({ payload: focused }) => {
      if (focused) drainPendingAudioWarnings();
    });

    return () => {
      void unlistenSegment.then((fn) => fn());
      void unlistenFinished.then((fn) => fn());
      void unlistenError.then((fn) => fn());
      void unlistenTurnFailed.then((fn) => fn());
      void unlistenAudioWarning.then((fn) => fn());
      void unlistenFocus.then((fn) => fn());
    };
  }, [appendSegment, markFinished, markErrored, t]);
};

/**
 * Adopta, si hace falta, una reunión que ya está grabando en el backend
 * pero que esta ventana todavía no conoce — la mitad que le faltaba a esta
 * ventana frente al popover (que ya resolvía esto para su propia tarjeta;
 * ver el doc comment de `PopoverBody` y de `useActiveMeeting`). Sin esto,
 * empezar una reunión desde el popover dejaba la ventana de reuniones
 * mostrando "listo para grabar" para siempre: su `useMeetingStore` es una
 * instancia de Zustand propia de este webview, y nada la actualizaba salvo
 * los propios `startMeeting`/`stopMeeting` de esta ventana.
 *
 * **Va en UN solo componente** (junto a `useMeetingEvents`, hoy
 * `MeetingSession`), no en `useMeetings`: si viviera en el hook de estado,
 * cada componente que lo usa (`RecordingControls`, `LiveTranscript`,
 * `SpeakerAssignment`) pediría su propio `get_meeting` de más.
 *
 * Sólo adopta cuando `activeMeetingId` acá es `null`: si esta ventana ya
 * tiene una sesión propia en curso —la empezó ella misma, o ya la adoptó
 * antes— lo que reporte el backend no debe pisarle el estado local, ni
 * siquiera a medio detener (`status === "processing"` sigue teniendo
 * `activeMeetingId` puesto hasta que llega `meeting-finished`).
 */
export const useMeetingActiveSync = (): void => {
  const { t } = useTranslation();
  const activeMeetingId = useMeetingStore((state) => state.activeMeetingId);
  const adoptActive = useMeetingStore((state) => state.adoptActive);

  const onError = useCallback(
    (error: unknown) => {
      console.error("No se pudo resolver la reunión activa:", error);
      toast.error(t("popover.loadFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    },
    [t],
  );
  const { activeMeeting } = useActiveMeeting(onError);

  useEffect(() => {
    if (activeMeeting === null || activeMeetingId !== null) return;
    let cancelled = false;
    void commands.getMeeting(activeMeeting.id).then((result) => {
      if (cancelled || result.status !== "ok") return;
      const speakerNames: Record<number, string> = {};
      for (const speaker of result.data.speakers) {
        if (speaker.display_name)
          speakerNames[speaker.id] = speaker.display_name;
      }
      adoptActive(activeMeeting.id, result.data.segments, speakerNames);
    });
    return () => {
      cancelled = true;
    };
  }, [activeMeeting, activeMeetingId, adoptActive]);
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

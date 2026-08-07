import { useEffect } from "react";
import type { TFunction } from "i18next";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { platform } from "@tauri-apps/plugin-os";
import type { RecordingErrorEvent } from "@/lib/types/events";

/**
 * El toast de un dictado que no pudo empezar.
 *
 * Vivía suelto dentro de `App.tsx` — o sea, sólo en la ventana de Ajustes—,
 * y abrir Reuniones **esconde** Ajustes (`open_meetings_window`). El
 * resultado real (reporte del dueño, 2026-08-04): cuatro dictados
 * rechazados seguidos mientras una reunión grababa, con los cuatro avisos
 * dibujados en una ventana que nadie estaba mirando. Desde acá el mismo
 * aviso se monta en las tres ventanas con interfaz (Ajustes, Reuniones y el
 * popover).
 *
 * **No se duplica.** Rust manda este evento a UNA sola ventana, la que el
 * usuario tiene delante (ver `utils::pick_notice_window`), y acá se escucha
 * acotado a esta ventana (`getCurrentWindow().listen`, no el `listen`
 * global, que recibiría los avisos dirigidos a las otras).
 */
export const showRecordingErrorToast = (
  t: TFunction,
  event: RecordingErrorEvent,
): void => {
  const { error_type, detail } = event;

  if (error_type === "microphone_permission_denied") {
    const currentPlatform = platform();
    const platformKey = `errors.micPermissionDenied.${currentPlatform}`;
    const description = t(platformKey, {
      defaultValue: t("errors.micPermissionDenied.generic"),
    });
    toast.error(t("errors.micPermissionDeniedTitle"), { description });
    return;
  }

  if (error_type === "no_input_device") {
    toast.error(t("errors.noInputDeviceTitle"), {
      description: t("errors.noInputDevice"),
    });
    return;
  }

  // La tecla de un modo se apretó con "Transformar" apagado (Ajustes ›
  // Avanzado). El backend no graba nada — mandar el dictado al proveedor
  // contradiría una preferencia explícita — así que la tecla se sentiría rota
  // sin este aviso. Ver `mode_shortcut_is_blocked` en `actions.rs`.
  if (error_type === "post_process_disabled") {
    toast.error(t("errors.postProcessDisabledTitle"), {
      description: t("errors.postProcessDisabled"),
    });
    return;
  }

  // Ni permisos ni dispositivo: hay una reunión grabando y Dilo graba una
  // cosa a la vez. El mensaje anterior era el string crudo del backend
  // ("El micrófono está en uso…"), que además mentía sobre la causa —
  // una reunión por audio del sistema jamás abre el micrófono (ver
  // `MicOwner::busy_error_message` en `managers/audio.rs`).
  if (error_type === "meeting_recording_active") {
    toast.error(t("errors.meetingRecordingActiveTitle"), {
      description: t("errors.meetingRecordingActive"),
    });
    return;
  }

  toast.error(
    t("errors.recordingFailed", { error: detail ?? "Unknown error" }),
  );
};

/** Monta el listener de `recording-error` en la ventana que lo llame. */
export const useRecordingErrorToast = (): void => {
  const { t } = useTranslation();

  useEffect(() => {
    const unlisten = getCurrentWindow().listen<RecordingErrorEvent>(
      "recording-error",
      (event) => {
        showRecordingErrorToast(t, event.payload);
      },
    );
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, [t]);
};

import { useCallback, useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { commands, events, type MeetingSummary } from "@/bindings";
import { useWindowShown } from "@/lib/windowShown";

/**
 * Pregunta al backend si hay una reunión grabando ahora mismo, y cuál.
 *
 * Es la fuente de verdad compartida entre el popover y la ventana de
 * reuniones (originalmente resuelta sólo en `PopoverBody`, extraída acá
 * cuando la ventana de reuniones necesitó la misma respuesta — reporte del
 * dueño, 2026-08-04): son dos webviews separados, cada uno con su propia
 * instancia de Zustand, así que ninguno puede confiar en lo que su propio
 * store recuerda sobre una sesión que pudo haber empezado o terminado en el
 * otro.
 *
 * `list_meetings(1, 0)` alcanza para responder: si algo está grabando, es
 * siempre la fila más reciente — el backend rechaza empezar una reunión
 * nueva mientras otra sigue en `recording` (`recording_busy`), así que
 * ninguna fila puede haberse insertado después de la que graba.
 */
export const resolveActiveMeeting =
  async (): Promise<MeetingSummary | null> => {
    const result = await commands.listMeetings(1, 0);
    if (result.status !== "ok") {
      throw new Error(result.error);
    }
    const [top] = result.data.meetings;
    return top?.status === "recording" ? top : null;
  };

interface UseActiveMeetingReturn {
  activeMeeting: MeetingSummary | null;
  /** Vuelve a preguntarle al backend ya mismo, sin esperar el próximo
   * evento o cambio de foco — por ejemplo, justo después de que empezar una
   * reunión falle con `recording_busy`, para que la interfaz refleje al
   * toque cuál es la que ya está grabando. */
  refresh: () => Promise<void>;
}

/**
 * Mantiene la respuesta de `resolveActiveMeeting` al día en esta ventana:
 * la vuelve a pedir al montar, cuando esta ventana **se muestra**
 * (`useWindowShown`), cuando recupera el foco (ni el popover ni la ventana
 * de reuniones se destruyen al esconderse — ver sus doc comments — así que
 * un `useEffect` de montaje no vuelve a correr solo cuando la sesión cambia
 * en la otra ventana mientras ésta estaba escondida) y cuando llegan los
 * eventos que sí cruzan ventanas y pueden cambiar la respuesta
 * (`meeting-finished`, `meeting-interrupted`).
 *
 * Mostrarse y tomar el foco no son lo mismo, y por eso están los dos: una
 * ventana puede mostrarse sin que el sistema reporte ningún cambio de foco
 * (si ya lo tenía), y ése es exactamente el agujero por el que la ventana de
 * reuniones mostró "no estoy grabando" con una reunión corriendo.
 *
 * No sabe nada de Zustand ni de ningún store local: sólo responde "¿hay
 * algo grabando, y qué reunión es". Cada ventana decide qué hacer con eso
 * (el popover arma su mini transcript en `PopoverBody`; la ventana de
 * reuniones adopta la sesión en `useMeetingStore` vía
 * `useMeetingActiveSync` en `hooks/useMeetings.ts`).
 */
export const useActiveMeeting = (
  onError?: (error: unknown) => void,
): UseActiveMeetingReturn => {
  const [activeMeeting, setActiveMeeting] = useState<MeetingSummary | null>(
    null,
  );
  // En un ref para que `refresh` (y los efectos que dependen de ella) no
  // cambien de identidad en cada render sólo porque quien llama pasó una
  // arrow function nueva.
  const onErrorRef = useRef(onError);
  onErrorRef.current = onError;

  const refresh = useCallback(async () => {
    try {
      setActiveMeeting(await resolveActiveMeeting());
    } catch (error) {
      onErrorRef.current?.(error);
    }
  }, []);

  // Carga inicial.
  useEffect(() => {
    void refresh();
  }, [refresh]);

  // El fin de una sesión —en curso mientras esta ventana estaba escondida,
  // o terminada en la otra ventana— sólo llega por evento.
  useEffect(() => {
    const unlistenFinished = events.meetingFinished.listen(
      () => void refresh(),
    );
    const unlistenInterrupted = events.meetingInterrupted.listen(
      () => void refresh(),
    );
    return () => {
      void unlistenFinished.then((fn) => fn());
      void unlistenInterrupted.then((fn) => fn());
    };
  }, [refresh]);

  // No hay evento de "empezó a grabar" en el backend; recuperar el foco es
  // el momento en que una reunión iniciada en la otra ventana mientras ésta
  // estaba escondida se refleja acá.
  useEffect(() => {
    const win = getCurrentWindow();
    const unlisten = win.onFocusChanged(({ payload: focused }) => {
      if (focused) void refresh();
    });
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, [refresh]);

  // Y **mostrarse** es el otro momento, el que faltaba: el foco no alcanza
  // cuando la ventana se muestra sin que el sistema reporte un cambio de
  // foco (ya estaba enfocada, o el popover se abrió encima sin quitárselo).
  // Ahí esta ventana se quedaba mostrando "listo para grabar" con la
  // reunión corriendo, y la única forma de sacarla de ese estado era
  // reiniciar la app (reporte del dueño, 2026-08-04). Ver `useWindowShown`
  // y `utils::emit_window_shown` en Rust.
  useWindowShown(() => {
    void refresh();
  });

  return { activeMeeting, refresh };
};

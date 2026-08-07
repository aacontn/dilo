import type { TFunction } from "i18next";
import { formatKeyCombination, type OSType } from "@/lib/utils/keyboard";
import type { ModeShortcutsClearedEvent } from "@/lib/types/events";

/**
 * El aviso de los atajos de modo que la actualización a la 0.2.3 retiró.
 *
 * La regla 2 de la migración (`settings.rs`) borra los atajos de modo que este
 * teclado no puede disparar — un `f17` pelado guardado por la captura vieja de
 * macOS, donde `fn` nunca llegaba al navegador. El borrado es correcto, pero
 * invisible: sin este aviso la persona se entera apretando la tecla, y "se me
 * rompió el atajo" es exactamente la lectura equivocada.
 *
 * **Por qué el aviso vive en el store y no en memoria:** la migración corre al
 * arrancar, cuando lo normal es que no haya ninguna ventana abierta — quien
 * dicta tiene Dilo en la bandeja. Rust deja el aviso guardado y lo reemite
 * cada vez que una ventana se muestra y cada vez que el frontend pide los
 * ajustes; acá se muestra **una vez por sesión** (`hasShownClearedNotice`), y
 * vuelve a aparecer en el siguiente arranque hasta que la persona asigne una
 * tecla de modo, momento en que `change_mode_shortcut` borra el aviso.
 */
export const MODE_SHORTCUTS_CLEARED_EVENT = "mode-shortcuts-cleared";

/**
 * Cuánto queda el aviso en pantalla. Los 4 s por defecto de sonner no alcanzan
 * para leer una lista de modos y entender qué hay que hacer; `Infinity` dejaría
 * un toast que no se va nunca en una ventana cuyos toasts van sin botón de
 * cerrar (`unstyled`). Si igual se pierde, vuelve en el próximo arranque.
 */
export const CLEARED_NOTICE_DURATION_MS = 20_000;

/**
 * Si hay algo que contar. Un evento sin modos es ruido —puede llegar si el
 * store quedó con un aviso vacío— y repetirlo dentro de la misma sesión
 * también: Rust lo reemite en cada `get_app_settings` y en cada ventana que se
 * muestra, a propósito, porque no puede saber si había alguien escuchando.
 */
export const shouldShowClearedNotice = (
  event: ModeShortcutsClearedEvent | null | undefined,
  alreadyShownThisSession: boolean,
): boolean => !alreadyShownThisSession && (event?.modes?.length ?? 0) > 0;

/**
 * La lista que se le muestra a la persona: nombre del modo y la tecla que
 * tenía, formateada como en el resto de la interfaz (`Correo (fn + F17)`).
 * Decir cuál era la tecla importa: es lo que la persona iba a apretar.
 */
export const buildClearedNoticeSummary = (
  event: ModeShortcutsClearedEvent,
  osType: OSType,
): string =>
  event.modes
    .map(
      (mode) =>
        `${mode.mode_name} (${formatKeyCombination(mode.shortcut, osType)})`,
    )
    .join(", ");

/** Texto listo del aviso (título y cuerpo), sin tocar la interfaz. */
export const buildClearedNoticeText = (
  event: ModeShortcutsClearedEvent,
  osType: OSType,
  t: TFunction,
): { title: string; description: string } => ({
  title: t("settings.postProcessing.modes.clearedNoticeTitle"),
  description: t("settings.postProcessing.modes.clearedNotice", {
    modes: buildClearedNoticeSummary(event, osType),
  }),
});

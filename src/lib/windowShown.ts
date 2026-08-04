import { useEffect, useRef } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";

/**
 * Espejo de `utils::WINDOW_SHOWN_EVENT` (Rust): el aviso de que ESTA ventana
 * acaba de mostrarse.
 *
 * Existe porque las ventanas que se esconden en vez de cerrarse —el popover
 * y la de reuniones, ver las notas de módulo de `popover.rs` y
 * `meeting_window.rs`— montan su React una sola vez en toda la vida del
 * proceso: un `useEffect` de montaje no vuelve a correr al reabrirlas.
 * Tauri no trae un evento de ventana para esto (`WindowEvent` no incluye
 * "shown") y el foco no siempre cambia al mostrarse, así que lo emite Rust
 * después de cada `show()`.
 */
export const WINDOW_SHOWN_EVENT = "window-shown";

/**
 * Corre `onShown` cada vez que esta ventana se muestra.
 *
 * Se escucha **acotado a esta ventana** (`getCurrentWindow().listen`, no el
 * `listen` global): Rust manda el aviso a la ventana que se mostró, y un
 * listener global lo recibiría igual desde cualquier otra — el popover
 * refrescaría cada vez que se abre la de reuniones.
 *
 * `onShown` se guarda en un ref para que pasar una arrow function nueva en
 * cada render no vuelva a suscribir el listener.
 */
export const useWindowShown = (onShown: () => void): void => {
  const onShownRef = useRef(onShown);
  onShownRef.current = onShown;

  useEffect(() => {
    const unlisten = getCurrentWindow().listen(WINDOW_SHOWN_EVENT, () => {
      onShownRef.current();
    });
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, []);
};

import React, { useEffect } from "react";
import { Toaster } from "sonner";
import { useTranslation } from "react-i18next";
import "@/App.css";
import { MeetingSession } from "@/components/meeting";
import { getLanguageDirection, initializeRTL } from "@/lib/utils/rtl";

/**
 * Raíz de la ventana de reuniones — separada de la ventana de ajustes (ver
 * docs/superpowers/specs/2026-07-31-notetaker-usable-design.md §1). Repite el
 * cascarón visual de `App.tsx` (fondo de vidrio, franja de arrastre nativa,
 * Toaster) pero sin sidebar ni footer: acá sólo vive el módulo de reuniones
 * completo — grabar, ver el transcript en vivo, nombrar hablantes y leer
 * reuniones pasadas.
 */
const MeetingsWindow: React.FC = () => {
  const { i18n } = useTranslation();
  const direction = getLanguageDirection(i18n.language);

  useEffect(() => {
    initializeRTL(i18n.language);
  }, [i18n.language]);

  return (
    <>
      {/* sonner se renderiza por portal, así que su posición en el árbol no
          afecta el layout — mismo patrón que App.tsx. */}
      <Toaster
        theme="system"
        toastOptions={{
          unstyled: true,
          classNames: {
            toast:
              "glass-toast rounded-xl px-4 py-3 flex items-center gap-3 text-sm",
            title: "font-medium",
            description: "text-muted-text",
          },
        }}
      />
      <div
        dir={direction}
        className="dilo-shell h-screen flex flex-col select-none cursor-default"
      >
        <div
          className="dilo-titlebar-drag-region"
          data-tauri-drag-region
          aria-hidden="true"
        />
        <div className="dilo-scroll flex-1 overflow-y-auto">
          <div className="dilo-page flex flex-col items-center gap-4">
            <MeetingSession />
          </div>
        </div>
      </div>
    </>
  );
};

export default MeetingsWindow;

import React, { useEffect } from "react";
import { Toaster, toast } from "sonner";
import { useTranslation } from "react-i18next";
import { ArrowLeft } from "lucide-react";
import "@/App.css";
import { commands } from "@/bindings";
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
  const { t, i18n } = useTranslation();
  const direction = getLanguageDirection(i18n.language);

  useEffect(() => {
    initializeRTL(i18n.language);
  }, [i18n.language]);

  // Abrir Reuniones esconde la ventana de Ajustes, así que sin esto la única
  // vuelta es la bandeja. El intercambio lo hace Rust (`return_to_main_window`),
  // igual que el de ida.
  const goBack = async () => {
    const result = await commands.returnToMainWindow();
    if (result.status === "error") {
      toast.error(t("meeting.backFailed"), { description: result.error });
    }
  };

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
            {/* Debajo de la franja de arrastre, no dentro: en macOS los
                semáforos nativos viven arriba a la izquierda y un botón ahí
                chocaría con ellos. */}
            <div className="w-full">
              <button
                type="button"
                onClick={() => void goBack()}
                className="flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm text-muted-text transition-colors hover:bg-white/10 hover:text-text"
              >
                <ArrowLeft className="size-4 shrink-0" />
                {t("meeting.backToDilo")}
              </button>
            </div>
            <MeetingSession />
          </div>
        </div>
      </div>
    </>
  );
};

export default MeetingsWindow;

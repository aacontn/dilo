import React from "react";
import { Toaster } from "sonner";
import "@/App.css";
import { PopoverBody } from "@/components/popover/PopoverBody";

/**
 * Cascarón del popover de la barra de menú, con las cuatro zonas montadas
 * adentro (§2 del diseño: el ícono sigue al sistema por legibilidad, el
 * popover sigue al ajuste de tema de la app — eso ya lo resuelve el arranque
 * de tema en `main.tsx`, acá sólo se monta el contenido).
 */
const PopoverWindow: React.FC = () => (
  <>
    <Toaster
      theme="system"
      toastOptions={{
        unstyled: true,
        classNames: {
          toast:
            "glass-toast rounded-xl px-4 py-3 flex items-center gap-3 text-sm",
          title: "font-medium",
          description: "text-muted-text",
          actionButton:
            "shrink-0 cursor-pointer rounded-lg bg-text/10 px-2 py-1 text-xs font-medium text-text transition-colors hover:bg-text/20",
        },
      }}
    />
    <div className="dilo-shell h-screen w-screen select-none cursor-default rounded-xl overflow-hidden p-3">
      <PopoverBody />
    </div>
  </>
);

export default PopoverWindow;

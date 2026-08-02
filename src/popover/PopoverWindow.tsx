import React from "react";
import "@/App.css";

/**
 * Cascarón del popover de la barra de menú. El contenido llega en la Task 4;
 * acá sólo el vidrio, que sigue el ajuste de tema de Dilo (ver §2 del diseño:
 * el ícono sigue al sistema por legibilidad, el popover sigue a la app).
 */
const PopoverWindow: React.FC = () => (
  <div className="dilo-shell h-screen w-screen select-none cursor-default p-3" />
);

export default PopoverWindow;

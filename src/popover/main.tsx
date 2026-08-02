import React from "react";
import ReactDOM from "react-dom/client";
import PopoverWindow from "./PopoverWindow";
import { syncThemeFromSettings } from "@/lib/utils/theme";
import "@/i18n";

syncThemeFromSettings();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <PopoverWindow />
  </React.StrictMode>,
);

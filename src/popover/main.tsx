import React from "react";
import ReactDOM from "react-dom/client";
import { platform } from "@tauri-apps/plugin-os";
import PopoverWindow from "./PopoverWindow";
import {
  applyTheme,
  getStoredTheme,
  syncThemeFromSettings,
} from "@/lib/utils/theme";
import { getAppAppearance } from "@/lib/utils/appearance";

// Mismo arranque que src/main.tsx y src/meetings/main.tsx: platform y tema
// antes de montar React, para que el CSS ya tenga
// data-platform/data-appearance/data-theme listos apenas pinta el primer
// frame — si esta ventana no hiciera esto se vería distinta al resto de la
// app (bug visual).
const currentPlatform = platform();
document.documentElement.dataset.platform = currentPlatform;
document.documentElement.dataset.appearance = getAppAppearance(currentPlatform);

applyTheme(getStoredTheme());
syncThemeFromSettings();

// Initialize i18n
import "@/i18n";

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <PopoverWindow />
  </React.StrictMode>,
);

import React from "react";
import ReactDOM from "react-dom/client";
import { platform } from "@tauri-apps/plugin-os";
import App from "./App";
import {
  applyTheme,
  getStoredTheme,
  syncThemeFromSettings,
} from "./lib/utils/theme";
import { getAppAppearance } from "./lib/utils/appearance";

// Set platform before render so CSS can scope per-platform (e.g. scrollbar styles)
const currentPlatform = platform();
document.documentElement.dataset.platform = currentPlatform;
document.documentElement.dataset.appearance = getAppAppearance(currentPlatform);

// Apply the last-known theme synchronously before render to avoid a flash of
// the wrong palette, then reconcile with the persisted setting once it loads.
applyTheme(getStoredTheme());
syncThemeFromSettings();

// Initialize i18n
import "./i18n";

// Initialize model store (loads models and sets up event listeners)
import { useModelStore } from "./stores/modelStore";
useModelStore.getState().initialize();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);

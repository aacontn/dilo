import React from "react";
import { useTranslation } from "react-i18next";
import { platform } from "@tauri-apps/plugin-os";
import { ToggleSwitch } from "../ui/ToggleSwitch";
import { useSettings } from "../../hooks/useSettings";

interface ShowDockIconProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
}

/**
 * Sólo macOS: el Dock es un concepto de macOS y `ActivationPolicy` no existe
 * en Windows ni Linux, así que en el resto no se muestra el ajuste.
 */
export const ShowDockIcon: React.FC<ShowDockIconProps> = React.memo(
  ({ descriptionMode = "tooltip", grouped = false }) => {
    const { t } = useTranslation();
    const { getSetting, updateSetting, isUpdating } = useSettings();

    if (platform() !== "macos") return null;

    const showDockIcon = getSetting("show_dock_icon") ?? true;

    return (
      <ToggleSwitch
        checked={showDockIcon}
        onChange={(enabled) => updateSetting("show_dock_icon", enabled)}
        isUpdating={isUpdating("show_dock_icon")}
        label={t("settings.advanced.showDockIcon.label")}
        description={t("settings.advanced.showDockIcon.description")}
        descriptionMode={descriptionMode}
        grouped={grouped}
        tooltipPosition="bottom"
      />
    );
  },
);

import React from "react";
import { useTranslation } from "react-i18next";
import { ToggleSwitch } from "../ui/ToggleSwitch";
import { useSettings } from "../../hooks/useSettings";

interface GeminiSmartToggleProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
}

/**
 * Modo "smart" de Gemini 3.5 Transcribe: el motor devuelve el dictado ya sin
 * muletillas ni repeticiones. Sólo se muestra cuando el modelo elegido es el
 * de Gemini (lo decide `ModelSettingsCard`), porque no hay ningún otro motor
 * al que le sirva. Apagarlo pide el dictado literal y devuelve el filtro local
 * de muletillas a su lugar (`should_skip_filler_filter` en el backend).
 */
export const GeminiSmartToggle: React.FC<GeminiSmartToggleProps> = React.memo(
  ({ descriptionMode = "tooltip", grouped = false }) => {
    const { t } = useTranslation();
    const { getSetting, updateSetting, isUpdating } = useSettings();
    const smartMode = getSetting("gemini_smart_mode") ?? true;

    return (
      <div className="flex flex-col">
        <ToggleSwitch
          checked={smartMode}
          onChange={(enabled) => updateSetting("gemini_smart_mode", enabled)}
          isUpdating={isUpdating("gemini_smart_mode")}
          label={t("gemini.smart_label")}
          description={t("gemini.smart_description")}
          descriptionMode={descriptionMode}
          grouped={grouped}
        />
      </div>
    );
  },
);

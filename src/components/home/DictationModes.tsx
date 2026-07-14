import {
  Check,
  Code2,
  Info,
  Mail,
  MessageCircle,
  Quote,
  Sparkles,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  DICTATION_MODE_PRESETS,
  getActiveDictationMode,
} from "@/lib/postProcessPresets";
import { useSettings } from "@/hooks/useSettings";

const ICONS = {
  "dilo-clean": Sparkles,
  "dilo-prompt": Quote,
  "dilo-message": MessageCircle,
  "dilo-email": Mail,
  "dilo-code": Code2,
} as const;

export const DictationModes = () => {
  const { t } = useTranslation();
  const { settings, updateSetting, isUpdating } = useSettings();
  if (!settings) return null;

  const activeMode = getActiveDictationMode(settings);
  const providerId = settings.post_process_provider_id || "openai";
  const providerModel = settings.post_process_models?.[providerId]?.trim();
  const providerApiKey = settings.post_process_api_keys?.[providerId]?.trim();
  const providerReady =
    Boolean(providerModel) &&
    (providerId === "apple_intelligence" ||
      providerId === "custom" ||
      Boolean(providerApiKey));
  const busy =
    isUpdating("post_process_enabled") ||
    isUpdating("post_process_selected_prompt_id");

  const chooseLiteral = async () => {
    await updateSetting("post_process_enabled", false);
  };

  const choosePreset = async (presetId: string) => {
    await updateSetting("post_process_selected_prompt_id", presetId);
    await updateSetting("post_process_enabled", true);
  };

  const modes = [
    {
      id: "literal",
      label: t("home.modes.literal.title"),
      description: t("home.modes.literal.description"),
      icon: Quote,
      onSelect: chooseLiteral,
    },
    ...DICTATION_MODE_PRESETS.map((preset) => ({
      id: preset.id,
      label: t(preset.labelKey),
      description: t(preset.descriptionKey),
      icon: ICONS[preset.id as keyof typeof ICONS] || Sparkles,
      onSelect: () => choosePreset(preset.id),
    })),
  ];

  return (
    <section className="dictation-modes-section">
      <div className="mb-3">
        <h2 className="font-semibold text-base text-text">
          {t("home.modes.title")}
        </h2>
        <p className="text-xs text-muted-text">{t("home.modes.subtitle")}</p>
      </div>
      <div className="glass-surface dictation-mode-segment overflow-hidden rounded-xl">
        <div className="dictation-modes-grid grid">
          {modes.map((mode) => {
            const Icon = mode.icon;
            const selected = activeMode === mode.id;
            return (
              <button
                type="button"
                key={mode.id}
                onClick={mode.onSelect}
                disabled={busy}
                aria-pressed={selected}
                className={`dictation-mode-card relative flex min-h-14 items-center justify-center gap-2 px-3 py-2 disabled:opacity-50 disabled:cursor-not-allowed ${
                  selected ? "dictation-mode-card--selected" : ""
                }`}
              >
                <Icon
                  className={`size-4 ${selected ? "text-accent-text" : "text-muted-text"}`}
                />
                <span className="text-sm font-medium text-text">
                  {mode.label}
                </span>
                {selected && <Check className="size-3.5 text-accent-text" />}
              </button>
            );
          })}
        </div>
        <p className="border-t border-mid-gray/15 px-4 py-2.5 text-sm text-text/60">
          {modes.find((mode) => mode.id === activeMode)?.description}
        </p>
      </div>
      {activeMode !== "literal" && !providerReady && (
        <div className="mt-3 flex items-center gap-2 px-0.5 text-xs text-muted-text">
          <Info className="size-4 shrink-0" />
          {t("home.modes.needsProvider")}
        </div>
      )}
    </section>
  );
};

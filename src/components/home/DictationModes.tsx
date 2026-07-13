import {
  AlertTriangle,
  Check,
  Code2,
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
    <section className="rounded-xl border border-mid-gray/20 p-4">
      <div className="mb-3">
        <h2 className="font-semibold text-sm text-text">
          {t("home.modes.title")}
        </h2>
        <p className="text-xs text-text/50">{t("home.modes.subtitle")}</p>
      </div>
      <div className="grid grid-cols-3 gap-2">
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
              className={`relative min-h-20 rounded-lg border p-3 text-left transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${
                selected
                  ? "border-logo-primary/60 bg-logo-primary/10"
                  : "border-mid-gray/15 hover:border-logo-primary/35 hover:bg-mid-gray/5"
              }`}
            >
              <div className="flex items-center gap-2">
                <Icon
                  className={`size-4 ${selected ? "text-logo-primary" : "text-text/45"}`}
                />
                <span className="text-sm font-semibold text-text">
                  {mode.label}
                </span>
                {selected && <Check className="ms-auto size-3.5 text-menta" />}
              </div>
              <p className="mt-1.5 text-[11px] leading-4 text-text/50">
                {mode.description}
              </p>
            </button>
          );
        })}
      </div>
      {activeMode !== "literal" && !providerReady && (
        <div className="mt-3 flex items-center gap-2 rounded-lg border border-amber-400/25 bg-amber-400/[0.06] px-3 py-2 text-xs text-amber-200/80">
          <AlertTriangle className="size-4 shrink-0" />
          {t("home.modes.needsProvider")}
        </div>
      )}
    </section>
  );
};

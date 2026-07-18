import {
  Check,
  Code2,
  Info,
  Mail,
  MessageCircle,
  Quote,
  Settings2,
  Sparkles,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  DICTATION_MODE_PRESETS,
  getActiveDictationMode,
} from "@/lib/postProcessPresets";
import { useSettings } from "@/hooks/useSettings";
import { ModeShortcutInput } from "@/components/settings/ModeShortcutInput";

const ICONS = {
  "dilo-clean": Sparkles,
  "dilo-prompt": Quote,
  "dilo-message": MessageCircle,
  "dilo-email": Mail,
  "dilo-code": Code2,
} as const;

const PRESET_IDS = new Set(DICTATION_MODE_PRESETS.map((preset) => preset.id));

interface DictationModesProps {
  onCustomize: () => void;
}

export const DictationModes = ({ onCustomize }: DictationModesProps) => {
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

  const prompts = settings.post_process_prompts || [];
  const shortcutFor = (id: string) =>
    prompts.find((prompt) => prompt.id === id)?.shortcut ?? null;

  const chooseLiteral = async () => {
    await updateSetting("post_process_enabled", false);
  };

  const chooseMode = async (promptId: string) => {
    await updateSetting("post_process_selected_prompt_id", promptId);
    await updateSetting("post_process_enabled", true);
  };

  // Presets first (with translated labels/icons), then any user-created prompts.
  const presetModes = DICTATION_MODE_PRESETS.map((preset) => ({
    id: preset.id,
    promptId: preset.id,
    label: t(preset.labelKey),
    description: t(preset.descriptionKey),
    icon: ICONS[preset.id as keyof typeof ICONS] || Sparkles,
  }));

  const customModes = prompts
    .filter((prompt) => !PRESET_IDS.has(prompt.id))
    .map((prompt) => ({
      id: prompt.id,
      promptId: prompt.id,
      label: prompt.name,
      description: prompt.prompt,
      icon: Sparkles,
    }));

  const modes = [
    {
      id: "literal",
      promptId: null as string | null,
      label: t("home.modes.literal.title"),
      description: t("home.modes.literal.description"),
      icon: Quote,
    },
    ...presetModes,
    ...customModes,
  ];

  return (
    <section className="dictation-modes-section">
      <div className="mb-3 flex items-end justify-between gap-3">
        <div>
          <h2 className="font-semibold text-base text-text">
            {t("home.modes.title")}
          </h2>
          <p className="text-xs text-muted-text">{t("home.modes.subtitle")}</p>
        </div>
        <button
          type="button"
          onClick={onCustomize}
          className="dictation-modes-customize flex shrink-0 items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium text-text"
        >
          <Settings2 className="size-4" />
          {t("home.modes.customize")}
        </button>
      </div>
      <div className="dictation-modes-grid grid gap-3">
        {modes.map((mode) => {
          const Icon = mode.icon;
          const selected = activeMode === mode.id;
          return (
            <div
              key={mode.id}
              className={`glass-surface dictation-mode-card flex flex-col rounded-xl ${
                selected ? "dictation-mode-card--selected" : ""
              }`}
            >
              <button
                type="button"
                onClick={
                  mode.promptId
                    ? () => chooseMode(mode.promptId as string)
                    : chooseLiteral
                }
                disabled={busy}
                aria-pressed={selected}
                className="dictation-mode-card-main flex flex-1 flex-col gap-1 p-3 text-start disabled:cursor-not-allowed disabled:opacity-50"
              >
                <span className="flex items-center gap-2">
                  <Icon
                    className={`size-4 shrink-0 ${
                      selected ? "text-accent-text" : "text-muted-text"
                    }`}
                  />
                  <span className="min-w-0 flex-1 truncate text-sm font-medium text-text">
                    {mode.label}
                  </span>
                  {selected && (
                    <Check className="size-3.5 shrink-0 text-accent-text" />
                  )}
                </span>
                <span className="dictation-mode-card-desc text-xs text-muted-text">
                  {mode.description}
                </span>
              </button>
              {mode.promptId && (
                <div className="dictation-mode-card-footer flex items-center px-3 py-2">
                  <ModeShortcutInput
                    compact
                    promptId={mode.promptId}
                    shortcut={shortcutFor(mode.promptId)}
                  />
                </div>
              )}
            </div>
          );
        })}
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

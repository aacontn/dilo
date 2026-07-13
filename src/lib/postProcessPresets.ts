export interface DictationModePreset {
  id: string;
  labelKey: string;
  descriptionKey: string;
}

export const DICTATION_MODE_PRESETS: DictationModePreset[] = [
  {
    id: "dilo-clean",
    labelKey: "home.modes.clean.title",
    descriptionKey: "home.modes.clean.description",
  },
  {
    id: "dilo-prompt",
    labelKey: "home.modes.prompt.title",
    descriptionKey: "home.modes.prompt.description",
  },
  {
    id: "dilo-message",
    labelKey: "home.modes.message.title",
    descriptionKey: "home.modes.message.description",
  },
  {
    id: "dilo-email",
    labelKey: "home.modes.email.title",
    descriptionKey: "home.modes.email.description",
  },
  {
    id: "dilo-code",
    labelKey: "home.modes.code.title",
    descriptionKey: "home.modes.code.description",
  },
];

export type DictationModeId = "literal" | string;

export const getActiveDictationMode = (settings: {
  post_process_enabled?: boolean;
  post_process_selected_prompt_id?: string | null;
}): DictationModeId => {
  if (!settings.post_process_enabled) return "literal";
  return settings.post_process_selected_prompt_id || "literal";
};

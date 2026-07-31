import type { LLMPrompt, PostProcessProvider } from "@/bindings";

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

/**
 * El proveedor que de verdad va a procesar un modo, con la misma regla que
 * `resolve_mode_provider` en `settings.rs`: si el modo no fija proveedor
 * propio, si ese proveedor ya no está en el catálogo (lo borraron), o si no
 * tiene ningún modelo utilizable (ni `prompt.model` ni el heredado de
 * `post_process_models[provider_id]`, contando "" como "no tiene"), el modo
 * hereda el proveedor general. Sin esto, la UI puede decir LOCAL mientras
 * cada dictado sale al proveedor general en la nube.
 */
export const resolveModeProviderId = (
  mode: Pick<LLMPrompt, "provider_id" | "model"> | undefined,
  settings: {
    post_process_provider_id?: string;
    post_process_providers?: PostProcessProvider[];
    post_process_models?: Partial<{ [key: string]: string }>;
  },
): string | undefined => {
  const generalId = settings.post_process_provider_id;
  const ownId = mode?.provider_id;
  if (!ownId) return generalId;

  const ownProvider = (settings.post_process_providers ?? []).find(
    (provider) => provider.id === ownId,
  );
  if (!ownProvider) return generalId;

  const ownModel = mode?.model?.trim();
  const inheritedModel = settings.post_process_models?.[ownId]?.trim();
  if (!ownModel && !inheritedModel) return generalId;

  return ownId;
};

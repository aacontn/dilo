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
/** El único proveedor que funciona sin clave: corre en el propio chip. */
export const KEYLESS_PROVIDER_ID = "apple_intelligence";

/**
 * El proveedor que hay que preseleccionar cuando un modo se mueve al lado
 * Local u Online del segmentado.
 *
 * Antes se tomaba el primero del catálogo de ese lado, que resulta ser OpenAI:
 * el dueño elegía "Online" con su proveedor configurado y con clave puesta, y
 * le aparecía igual el aviso de "falta la clave" porque el modo había quedado
 * apuntando a OpenAI (reporte del dueño, 2026-08-04). El orden correcto es:
 *
 * 1. el proveedor general, si es de ese lado — es el que la persona ya eligió;
 * 2. si no, el primero de ese lado que **tenga clave** (Apple Intelligence
 *    cuenta: no lleva clave);
 * 3. recién si ninguno tiene, el primero a secas.
 */
export const pickProviderForScope = (
  providers: PostProcessProvider[],
  scope: "local" | "online",
  settings: {
    post_process_provider_id?: string;
    post_process_api_keys?: Partial<{ [key: string]: string }>;
  },
): PostProcessProvider | null => {
  const wantsLocal = scope === "local";
  const candidates = providers.filter((p) => p.is_local === wantsLocal);
  if (candidates.length === 0) return null;

  const general = candidates.find(
    (p) => p.id === settings.post_process_provider_id,
  );
  if (general) return general;

  const hasKey = (provider: PostProcessProvider) =>
    provider.id === KEYLESS_PROVIDER_ID ||
    (settings.post_process_api_keys?.[provider.id] ?? "").trim().length > 0;

  return candidates.find(hasKey) ?? candidates[0];
};

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

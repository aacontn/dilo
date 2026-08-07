import type {
  LLMPrompt,
  PostProcessProvider,
  ShortcutBinding,
} from "@/bindings";

/**
 * `""`, `null` y `undefined` significan lo mismo para un atajo: no hay tecla
 * asignada. `ShortcutBinding.current_binding` usa `""` (ver `settings.rs`,
 * los bindings sin tecla de fábrica como `quick_note`); `LLMPrompt.shortcut`
 * usa `null`/`undefined`. Sin esto normalizado en un solo lugar, el
 * recordatorio de Inicio tendría que repetir el mismo `!value || !value.trim()`
 * en cada sitio que lee un atajo.
 */
export const normalizeShortcut = (
  value: string | null | undefined,
): string | null => (value && value.trim().length > 0 ? value : null);

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

/** `"local"`/`"online"` para la insignia de la fila; `null` cuando el proveedor
 * resuelto ya no está en el catálogo (se borró) — sin este caso la fila
 * mostraría una insignia mintiendo sobre dónde corre el modo. */
export type ModeProviderBadge = "local" | "online" | null;

/**
 * Insignia LOCAL/ONLINE que la lista de modos (pestaña "Modos" de
 * Transformar) muestra junto a cada fila. Mismo criterio que usa el
 * dashboard de Inicio (`DictationModes.tsx`, `providerBadgeFor`) para no
 * resolver el proveedor efectivo con dos reglas distintas en dos pantallas.
 */
export const resolveModeProviderBadge = (
  mode: Pick<LLMPrompt, "provider_id" | "model"> | undefined,
  settings: {
    post_process_provider_id?: string;
    post_process_providers?: PostProcessProvider[];
    post_process_models?: Partial<{ [key: string]: string }>;
  },
): ModeProviderBadge => {
  const providerId = resolveModeProviderId(mode, settings);
  const provider = (settings.post_process_providers ?? []).find(
    (candidate) => candidate.id === providerId,
  );
  if (!provider) return null;
  return provider.is_local ? "local" : "online";
};

/** Una fila de la lista de modos, ya con su insignia resuelta. */
export interface ModeListEntry {
  prompt: LLMPrompt;
  badge: ModeProviderBadge;
}

/**
 * Arma las filas de la lista de modos (pestaña "Modos"): cada prompt junto a
 * su insignia LOCAL/ONLINE ya resuelta.
 *
 * Existe para que el componente no tenga que componer
 * `resolveModeProviderBadge(prompt, settings ?? {})` por fila en el JSX. Esa
 * composición —trivial, pero viva en el sitio de la llamada— es exactamente
 * el tipo de wiring que una mutación puede romper (por ejemplo, pasar `{}`
 * en vez de `settings`) sin que ningún test lo note, porque
 * `resolveModeProviderBadge` en sí sigue estando bien probada: lo que fallaría
 * es *qué se le pasa*, no la función. Fusionar la composición acá adentro,
 * como ya hace `resolveShortcutConflict` en `shortcutConflicts.ts`, deja esa
 * misma composición cubierta por `postProcessPresets.test.ts` y el
 * componente sin nada que hacer salvo mapear el resultado.
 */
export const buildModeListEntries = (
  prompts: LLMPrompt[],
  settings:
    | {
        post_process_provider_id?: string;
        post_process_providers?: PostProcessProvider[];
        post_process_models?: Partial<{ [key: string]: string }>;
      }
    | null
    | undefined,
): ModeListEntry[] =>
  prompts.map((prompt) => ({
    prompt,
    badge: resolveModeProviderBadge(prompt, settings ?? {}),
  }));

/**
 * Si borrar el modo seleccionado dejaría `post_process_prompts` vacío: sin
 * ningún modo no hay con qué dictado transformar, así que el último modo no
 * se puede borrar. Vivía como `prompts.length <= 1` inline en el `disabled`
 * del botón "Eliminar" — una mutación a `<` (deja borrar el último y vaciar
 * la lista) pasaba todos los tests porque nada fuera del JSX ejercitaba esa
 * regla.
 */
export const isLastRemainingMode = (prompts: unknown[]): boolean =>
  prompts.length <= 1;

/**
 * Vista de la pestaña "Modos" en `PostProcessingSettings.tsx`: lista de
 * modos, o el detalle de uno (editar), o el formulario de creación. Ya no
 * hay "modo activo" que elegir (retirado en la Task 3) — esto es sólo
 * navegación de la pantalla, estado local del componente.
 */
export type ModesTabView =
  | { kind: "list" }
  | { kind: "detail"; promptId: string }
  | { kind: "create" };

/**
 * Si la vista pide el detalle de un modo que ya no existe (se borró desde
 * otro lugar, o quedó un id viejo en el estado), cae al listado en vez de
 * mostrar un formulario de detalle roto sin datos que mostrar.
 */
export const resolveModesView = (
  view: ModesTabView,
  prompts: Pick<LLMPrompt, "id">[],
): ModesTabView => {
  if (
    view.kind === "detail" &&
    !prompts.some((prompt) => prompt.id === view.promptId)
  ) {
    return { kind: "list" };
  }
  return view;
};

/**
 * Si el borrador de nombre + instrucciones difiere de lo guardado: decide
 * si el botón "Guardar cambios" del detalle de un modo está habilitado.
 * `null` (nada seleccionado, p. ej. en la vista de creación) nunca está
 * sucio — no hay contra qué comparar.
 */
export const isModeDraftDirty = (
  draft: { name: string; text: string },
  original: Pick<LLMPrompt, "name" | "prompt"> | null,
): boolean => {
  if (!original) return false;
  return (
    draft.name.trim() !== original.name ||
    draft.text.trim() !== original.prompt.trim()
  );
};

/**
 * Atajos generales que el recordatorio de Inicio muestra junto a los de
 * modo — los dos de `GeneralSettings.tsx` (`ShortcutInput shortcutId=...`).
 * `transcribe_with_post_process` queda afuera a propósito: es el atajo que
 * la Task 3 dejó vacío para todos y sin nada útil que hacer (ver nota en
 * `settings.rs` junto a `POST_PROCESS_BINDING_ID`); recordárselo al dueño
 * como si fuera una tecla real sería el mismo bug que tenía
 * `HomeDashboard.tsx` antes de este arreglo. `quick_note` y
 * `voice_assistant` también quedan afuera: son atajos de otras pantallas
 * (Notas, Asistente de voz), no de dictado/transformación.
 */
export const GENERAL_SHORTCUT_REMINDER_IDS = ["transcribe", "cancel"] as const;

export interface GeneralShortcutReminderEntry {
  id: (typeof GENERAL_SHORTCUT_REMINDER_IDS)[number];
  shortcut: string | null;
}

/**
 * Arma las filas de atajos generales del recordatorio de Inicio, leyendo
 * `settings.bindings` (el mismo mapa que usa `GeneralSettings.tsx`). Cada
 * label sale de la clave ya traducida en los 21 idiomas
 * `settings.general.shortcut.bindings.<id>.name` — no hace falta clave
 * nueva para esta parte del recordatorio.
 */
export const buildGeneralShortcutReminderEntries = (
  bindings:
    | Partial<{ [key: string]: Pick<ShortcutBinding, "current_binding"> }>
    | null
    | undefined,
): GeneralShortcutReminderEntry[] =>
  GENERAL_SHORTCUT_REMINDER_IDS.map((id) => ({
    id,
    shortcut: normalizeShortcut(bindings?.[id]?.current_binding),
  }));

/** Una fila del recordatorio de teclas de modo en Inicio, ya resuelta. */
export interface DictationModeReminderEntry {
  id: string;
  promptId: string;
  isPreset: boolean;
  /** Claves i18n del preset — `null` en un modo propio del usuario. */
  labelKey: string | null;
  descriptionKey: string | null;
  /** Nombre/instrucciones crudos de un modo propio — `null` en un preset. */
  name: string | null;
  description: string | null;
  shortcut: string | null;
  badge: ModeProviderBadge;
}

/**
 * Arma el recordatorio de teclas de modo que Inicio muestra bajo el
 * estado: presets primero, en el orden fijo de `DICTATION_MODE_PRESETS`,
 * y después cualquier modo propio del usuario en el orden en que aparece
 * en `post_process_prompts` (sin repetir un id que ya sea preset). Un modo
 * sin tecla asignada queda con `shortcut: null` — el llamador decide cómo
 * mostrar eso (`home.shortcuts.unassigned`), no se esconde de la lista.
 *
 * Antes esta mezcla (orden + normalización del atajo + insignia por fila)
 * vivía como tres pasos sueltos dentro de `DictationModes.tsx`
 * (`presetModes`/`customModes`/`providerBadgeFor`); fusionarlos acá sigue
 * el mismo patrón que `buildModeListEntries` para que una mutación al
 * cableado del componente —no sólo a estas funciones— la note un test.
 */
export const buildDictationModeEntries = (
  prompts: LLMPrompt[],
  settings:
    | {
        post_process_provider_id?: string;
        post_process_providers?: PostProcessProvider[];
        post_process_models?: Partial<{ [key: string]: string }>;
      }
    | null
    | undefined,
): DictationModeReminderEntry[] => {
  const presetIds = new Set(DICTATION_MODE_PRESETS.map((preset) => preset.id));
  const findPrompt = (id: string) => prompts.find((prompt) => prompt.id === id);

  const toEntry = (
    id: string,
    preset: DictationModePreset | null,
  ): DictationModeReminderEntry => {
    const prompt = findPrompt(id);
    return {
      id,
      promptId: id,
      isPreset: preset !== null,
      labelKey: preset?.labelKey ?? null,
      descriptionKey: preset?.descriptionKey ?? null,
      name: preset ? null : (prompt?.name ?? null),
      description: preset ? null : (prompt?.prompt ?? null),
      shortcut: normalizeShortcut(prompt?.shortcut),
      badge: resolveModeProviderBadge(prompt, settings ?? {}),
    };
  };

  const presetEntries = DICTATION_MODE_PRESETS.map((preset) =>
    toEntry(preset.id, preset),
  );
  const customEntries = prompts
    .filter((prompt) => !presetIds.has(prompt.id))
    .map((prompt) => toEntry(prompt.id, null));

  return [...presetEntries, ...customEntries];
};

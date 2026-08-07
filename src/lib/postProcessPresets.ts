import type { TFunction } from "i18next";
import type {
  LLMPrompt,
  PostProcessProvider,
  ShortcutBinding,
} from "@/bindings";
import { formatKeyCombination, type OSType } from "@/lib/utils/keyboard";

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

/**
 * ¿Este proveedor deja editar su URL base?
 *
 * Lo dice el propio proveedor (`allow_base_url_edit`, el mismo campo que
 * valida el backend en `change_post_process_base_url_setting`), no una lista
 * de ids en la UI: hay proveedores cuya URL sólo cambia en un tramo —la
 * región, por ejemplo— y no tendrían por qué tocar este archivo.
 *
 * El campo es opcional en el binding (`allow_base_url_edit?: boolean`), así
 * que ausente significa "no".
 */
export const canEditBaseUrl = (
  provider: Pick<PostProcessProvider, "allow_base_url_edit"> | undefined | null,
): boolean => provider?.allow_base_url_edit === true;

/**
 * ¿Este proveedor publica un catálogo de modelos que Dilo pueda pedir?
 *
 * `models_endpoint` en `null` significa que no hay lista que traer y que el id
 * del modelo se escribe a mano. Sin esta pregunta, Ajustes ofrece un botón de
 * "actualizar modelos" que sólo puede fallar, y el desplegable se queda vacío
 * sin explicar por qué.
 */
export const publishesModelCatalog = (
  provider: Pick<PostProcessProvider, "models_endpoint"> | undefined | null,
): boolean => Boolean(provider?.models_endpoint?.trim());

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

/** Por qué "Eliminar" está bloqueado, o `null` si el modo sí se puede borrar. */
export type ModeDeleteBlock = "factory-preset" | "last-remaining";

/**
 * Si "Eliminar" puede cumplir lo que promete para este modo.
 *
 * Los cinco modos de fábrica **no se pueden borrar**: `ensure_post_process_defaults`
 * (`settings.rs`) los vuelve a inyectar en cada lectura de los ajustes, así que
 * el borrado duraba hasta el siguiente `refreshSettings` y lo único que
 * quedaba borrado de verdad era su tecla — el preset volvía tal como sale de
 * `dilo_post_process_presets()`, que no trae ninguna. Con un atajo por modo eso
 * pasó de rareza cosmética a perder la tecla que la persona acababa de asignar.
 * Mientras la reinyección exista, la interfaz no promete un borrado que no
 * puede cumplir.
 *
 * `last-remaining` es la regla vieja (ver `isLastRemainingMode`) y se conserva
 * para los modos propios.
 */
export const modeDeleteBlock = (
  prompts: { id: string }[],
  promptId: string,
): ModeDeleteBlock | null => {
  if (DICTATION_MODE_PRESETS.some((preset) => preset.id === promptId)) {
    return "factory-preset";
  }
  if (isLastRemainingMode(prompts)) return "last-remaining";
  return null;
};

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

/**
 * Fila de atajo general ya lista para renderizar: nada que componer en el
 * componente, sólo mapear a JSX.
 */
export interface GeneralShortcutRow {
  id: string;
  label: string;
  shortcutText: string;
  hasShortcut: boolean;
}

/**
 * Arma las filas de atajos generales **con el texto ya traducido**, a
 * partir de `settings.bindings` crudo y la función `t` del componente.
 *
 * Esto existe porque la primera versión de este recordatorio dejaba dos
 * pasos sueltos en `DictationModes.tsx`: la llamada a
 * `buildGeneralShortcutReminderEntries(settings.bindings)` y, aparte, el
 * `t()`/`formatKeyCombination()` que convertía cada entrada en texto. Una
 * revisión mutó el argumento de esa llamada (`settings.bindings` →
 * `undefined`) y ningún test lo notó — la composición vivía en el JSX del
 * componente, no en código que `bun test` pueda ejercitar sin montar React.
 * Ahora **toda** esa composición (armar las entradas + traducir + formatear
 * la tecla) vive acá, así que el componente pasa `settings.bindings` tal
 * cual (sin transformarlo) y sólo mapea el resultado.
 */
export const buildGeneralShortcutRows = (
  bindings:
    | Partial<{ [key: string]: Pick<ShortcutBinding, "current_binding"> }>
    | null
    | undefined,
  osType: OSType,
  t: TFunction,
): GeneralShortcutRow[] =>
  buildGeneralShortcutReminderEntries(bindings).map((entry) => ({
    id: entry.id,
    label: t(`settings.general.shortcut.bindings.${entry.id}.name`),
    shortcutText: entry.shortcut
      ? formatKeyCombination(entry.shortcut, osType)
      : t("home.shortcuts.unassigned"),
    hasShortcut: entry.shortcut !== null,
  }));

/**
 * Fila de modo ya lista para renderizar: nada que componer en el
 * componente, sólo mapear a JSX (el ícono se elige por `id` ahí mismo, es
 * un lookup trivial en un mapa fijo, no una decisión).
 */
export interface DictationModeRow {
  id: string;
  promptId: string;
  label: string;
  description: string;
  shortcutText: string;
  hasShortcut: boolean;
  badgeText: string | null;
}

/**
 * Arma las filas de modo **con el texto ya traducido**, a partir de
 * `post_process_prompts` y `settings` crudos y la función `t` del
 * componente.
 *
 * Mismo motivo que `buildGeneralShortcutRows`: antes el componente hacía
 * `entry.isPreset ? t(entry.labelKey ?? "") : (entry.name ?? "")` (y su
 * espejo para `description` y para la insignia LOCAL/ONLINE) directamente
 * en el `.map()` del JSX. Una revisión invirtió ese ternario —presets sin
 * nombre, modos propios mostrando la clave i18n cruda— y `bun test` siguió
 * en verde porque nada fuera del componente ejercitaba esa rama. Con la
 * composición acá adentro, `buildDictationModeEntries(prompts, settings)`
 * ya resuelto pasa por `t` una sola vez, en un solo lugar cubierto por
 * `postProcessPresets.test.ts`, y el componente recibe la fila terminada.
 */
export const buildDictationModeRows = (
  prompts: LLMPrompt[],
  settings: Parameters<typeof buildDictationModeEntries>[1],
  osType: OSType,
  t: TFunction,
): DictationModeRow[] =>
  buildDictationModeEntries(prompts, settings).map((entry) => ({
    id: entry.id,
    promptId: entry.promptId,
    label: entry.isPreset ? t(entry.labelKey ?? "") : (entry.name ?? ""),
    description: entry.isPreset
      ? t(entry.descriptionKey ?? "")
      : (entry.description ?? ""),
    shortcutText: entry.shortcut
      ? formatKeyCombination(entry.shortcut, osType)
      : t("home.shortcuts.unassigned"),
    hasShortcut: entry.shortcut !== null,
    badgeText:
      entry.badge === "local"
        ? t("settings.postProcessing.modeProvider.badgeLocal")
        : entry.badge === "online"
          ? t("settings.postProcessing.modeProvider.badgeOnline")
          : null,
  }));

import { describe, expect, test } from "bun:test";
import {
  buildDictationModeEntries,
  buildGeneralShortcutReminderEntries,
  buildModeListEntries,
  DICTATION_MODE_PRESETS,
  GENERAL_SHORTCUT_REMINDER_IDS,
  isLastRemainingMode,
  isModeDraftDirty,
  normalizeShortcut,
  pickProviderForScope,
  resolveModeProviderBadge,
  resolveModeProviderId,
  resolveModesView,
} from "@/lib/postProcessPresets";
import type { LLMPrompt, PostProcessProvider } from "@/bindings";

describe("dictation modes", () => {
  test("ships five stable smart presets", () => {
    expect(DICTATION_MODE_PRESETS.map((preset) => preset.id)).toEqual([
      "dilo-clean",
      "dilo-prompt",
      "dilo-message",
      "dilo-email",
      "dilo-code",
    ]);
  });
});

describe("resolveModeProviderId", () => {
  const custom: PostProcessProvider = {
    id: "custom",
    label: "Custom",
    base_url: "http://localhost:11434/v1",
    is_local: true,
  };
  const openai: PostProcessProvider = {
    id: "openai",
    label: "OpenAI",
    base_url: "https://api.openai.com/v1",
    is_local: false,
  };
  const settings = {
    post_process_provider_id: "openai",
    post_process_providers: [custom, openai],
  };

  test("hereda el general cuando el modo no fija proveedor propio", () => {
    expect(
      resolveModeProviderId({ provider_id: null, model: null }, settings),
    ).toBe("openai");
  });

  test("hereda el general cuando el proveedor propio ya no está en el catálogo", () => {
    expect(
      resolveModeProviderId(
        { provider_id: "apple_intelligence", model: null },
        settings,
      ),
    ).toBe("openai");
  });

  // Regresión Critical 2 (review final): "Local → Custom" es alcanzable con
  // dos clics y Custom viene con modelo "" de fábrica (ver
  // `ensure_post_process_defaults` en settings.rs). Antes del arreglo, esta
  // función sólo miraba `provider_id` e ignoraba si el proveedor resolvía de
  // verdad, así que la tarjeta de Inicio decía LOCAL mientras el dictado
  // salía al proveedor general en la nube.
  test("hereda el general cuando el proveedor propio no tiene ningún modelo utilizable", () => {
    expect(
      resolveModeProviderId(
        { provider_id: "custom", model: null },
        { ...settings, post_process_models: { custom: "" } },
      ),
    ).toBe("openai");
  });

  test("usa el proveedor propio cuando el modo trae su propio modelo", () => {
    expect(
      resolveModeProviderId(
        { provider_id: "custom", model: "llama3.1" },
        settings,
      ),
    ).toBe("custom");
  });

  test("usa el proveedor propio cuando hereda un modelo configurado para ese proveedor", () => {
    expect(
      resolveModeProviderId(
        { provider_id: "custom", model: null },
        { ...settings, post_process_models: { custom: "llama3.1" } },
      ),
    ).toBe("custom");
  });
});

describe("pickProviderForScope", () => {
  // El catálogo real: OpenAI es el PRIMER proveedor online, y es justamente
  // el que el dueño no tiene configurado.
  const openai: PostProcessProvider = {
    id: "openai",
    label: "OpenAI",
    base_url: "https://api.openai.com/v1",
    is_local: false,
  };
  const bedrock: PostProcessProvider = {
    id: "bedrock_mantle",
    label: "AWS Bedrock (Mantle)",
    base_url: "https://mantle.example/v1",
    is_local: false,
  };
  const apple: PostProcessProvider = {
    id: "apple_intelligence",
    label: "Apple Intelligence",
    base_url: "",
    is_local: true,
  };
  const online = [openai, bedrock];

  test("al pasar a Online elige el proveedor general, no el primero del catálogo", () => {
    // El bug del dueño: elegía Online con Bedrock configurado arriba y le
    // aparecía "falta la clave" porque el modo se iba a OpenAI.
    expect(
      pickProviderForScope(online, "online", {
        post_process_provider_id: "bedrock_mantle",
        post_process_api_keys: { bedrock_mantle: "clave" },
      })?.id,
    ).toBe("bedrock_mantle");
  });

  test("si el general es del otro lado, elige el primero que tenga clave", () => {
    expect(
      pickProviderForScope(online, "online", {
        post_process_provider_id: "apple_intelligence",
        post_process_api_keys: { openai: "   ", bedrock_mantle: "clave" },
      })?.id,
    ).toBe("bedrock_mantle");
  });

  test("si ninguno tiene clave, cae al primero de ese lado", () => {
    expect(
      pickProviderForScope(online, "online", {
        post_process_provider_id: "apple_intelligence",
        post_process_api_keys: {},
      })?.id,
    ).toBe("openai");
  });

  test("Apple Intelligence cuenta como configurado: no lleva clave", () => {
    expect(
      pickProviderForScope([apple], "local", {
        post_process_provider_id: "openai",
        post_process_api_keys: {},
      })?.id,
    ).toBe("apple_intelligence");
  });

  test("un lado sin proveedores no devuelve nada", () => {
    expect(pickProviderForScope(online, "local", {})).toBeNull();
  });
});

describe("la ventana del prompt", () => {
  test("los modos usan la variante alta del textarea", async () => {
    // 600-900 caracteres no entran en los 100px del textarea por defecto
    // ("el prompt no se ve completo, se ve como una ventana muy chica").
    const textarea = await Bun.file("src/components/ui/Textarea.tsx").text();
    const promptVariant = textarea.match(/prompt:\s*"([^"]+)"/)?.[1];
    expect(promptVariant).toBeDefined();
    const minHeight = Number(promptVariant!.match(/min-h-\[(\d+)px\]/)?.[1]);
    expect(minHeight).toBeGreaterThanOrEqual(240);
    expect(textarea).toContain("resize-y");

    const settings = await Bun.file(
      "src/components/settings/post-processing/PostProcessingSettings.tsx",
    ).text();
    // Los dos textareas de instrucciones (editar y crear).
    expect(settings.split('variant="prompt"').length - 1).toBe(2);
  });
});

// Regresión de la revisión de la Task 3: `post_process_selected_prompt_id`
// desapareció de `AppSettings`, pero la pantalla seguía mostrando un
// `ShortcutInput shortcutId="transcribe_with_post_process"` sin ningún
// gate — un control que, tras la migración, queda vacío para todos y que si
// se asigna dispara la tecla muerta que la Task 3 vino a matar (post-proceso
// sin ningún modo). No se puede montar React en `bun test` (ver nota en
// CLAUDE.md), así que esto se verifica igual que el test de arriba: leyendo
// el archivo del componente directamente.
describe("atajo general de transformar (retirado)", () => {
  test("PostProcessingSettings ya no monta el atajo muerto de transcribe_with_post_process", async () => {
    const settings = await Bun.file(
      "src/components/settings/post-processing/PostProcessingSettings.tsx",
    ).text();
    expect(settings).not.toContain("transcribe_with_post_process");
  });
});

describe("resolveModeProviderBadge", () => {
  const local: PostProcessProvider = {
    id: "apple_intelligence",
    label: "Apple Intelligence",
    base_url: "",
    is_local: true,
  };
  const online: PostProcessProvider = {
    id: "openai",
    label: "OpenAI",
    base_url: "https://api.openai.com/v1",
    is_local: false,
  };
  const settings = {
    post_process_provider_id: "openai",
    post_process_providers: [local, online],
    post_process_models: { apple_intelligence: "on-device" },
  };

  test("LOCAL cuando el proveedor efectivo es local", () => {
    expect(
      resolveModeProviderBadge(
        { provider_id: "apple_intelligence", model: null },
        settings,
      ),
    ).toBe("local");
  });

  test("ONLINE cuando el modo hereda el proveedor general y éste no es local", () => {
    expect(
      resolveModeProviderBadge({ provider_id: null, model: null }, settings),
    ).toBe("online");
  });

  test("null cuando el proveedor resuelto ya no está en el catálogo", () => {
    expect(
      resolveModeProviderBadge(
        { provider_id: null, model: null },
        { post_process_provider_id: "borrado", post_process_providers: [] },
      ),
    ).toBeNull();
  });
});

describe("resolveModesView", () => {
  const prompts: Pick<LLMPrompt, "id">[] = [{ id: "dilo-clean" }];

  test("mantiene la vista de lista sin cambios", () => {
    expect(resolveModesView({ kind: "list" }, prompts)).toEqual({
      kind: "list",
    });
  });

  test("mantiene la vista de creación sin cambios", () => {
    expect(resolveModesView({ kind: "create" }, prompts)).toEqual({
      kind: "create",
    });
  });

  test("mantiene el detalle si el modo todavía existe", () => {
    expect(
      resolveModesView({ kind: "detail", promptId: "dilo-clean" }, prompts),
    ).toEqual({ kind: "detail", promptId: "dilo-clean" });
  });

  test("cae al listado si el modo del detalle ya no existe", () => {
    expect(
      resolveModesView({ kind: "detail", promptId: "borrado" }, prompts),
    ).toEqual({ kind: "list" });
  });
});

describe("isModeDraftDirty", () => {
  const original: Pick<LLMPrompt, "name" | "prompt"> = {
    name: "Limpio",
    prompt: "Mejora la gramática: ${output}",
  };

  test("no está sucio cuando el borrador es igual al original", () => {
    expect(
      isModeDraftDirty(
        { name: "Limpio", text: "Mejora la gramática: ${output}" },
        original,
      ),
    ).toBe(false);
  });

  test("está sucio cuando cambia el nombre", () => {
    expect(
      isModeDraftDirty(
        { name: "Limpio 2", text: "Mejora la gramática: ${output}" },
        original,
      ),
    ).toBe(true);
  });

  test("está sucio cuando cambian las instrucciones", () => {
    expect(
      isModeDraftDirty(
        { name: "Limpio", text: "Otra cosa: ${output}" },
        original,
      ),
    ).toBe(true);
  });

  test("ignora espacios sobrantes en los bordes", () => {
    expect(
      isModeDraftDirty(
        {
          name: "  Limpio  ",
          text: "  Mejora la gramática: ${output}  ",
        },
        original,
      ),
    ).toBe(false);
  });

  test("nunca está sucio sin un modo original (p. ej. creando uno nuevo)", () => {
    expect(isModeDraftDirty({ name: "algo", text: "algo" }, null)).toBe(false);
  });
});

describe("normalizeShortcut", () => {
  test("una tecla real pasa tal cual", () => {
    expect(normalizeShortcut("fn+f17")).toBe("fn+f17");
  });

  test("string vacío cuenta como sin tecla (bindings sin tecla de fábrica)", () => {
    expect(normalizeShortcut("")).toBeNull();
  });

  test("sólo espacios también cuenta como sin tecla", () => {
    expect(normalizeShortcut("   ")).toBeNull();
  });

  test("null y undefined son sin tecla", () => {
    expect(normalizeShortcut(null)).toBeNull();
    expect(normalizeShortcut(undefined)).toBeNull();
  });
});

// Regresión: `HomeDashboard.tsx` leía `bindings.transcribe_with_post_process`
// y caía a "option+shift+space" cuando venía vacío — mostrando al dueño una
// tecla que ya no existe para nada (la Task 3 dejó ese binding vacío para
// todos). No se puede montar React en `bun test`, así que esto se verifica
// igual que la regresión equivalente de `PostProcessingSettings.tsx`: leyendo
// el archivo del componente como texto.
describe("atajo general muerto en Inicio (retirado)", () => {
  test("HomeDashboard ya no lee transcribe_with_post_process", async () => {
    const home = await Bun.file("src/components/home/HomeDashboard.tsx").text();
    expect(home).not.toContain("transcribe_with_post_process");
  });

  test("DictationModes ya no monta un ModeShortcutInput editable", async () => {
    const dictationModes = await Bun.file(
      "src/components/home/DictationModes.tsx",
    ).text();
    // Inicio deja de editar atajos de modo — eso vive sólo en Transformar
    // (`PostProcessingSettings.tsx`, que sí sigue usando `ModeShortcutInput`).
    expect(dictationModes).not.toContain("ModeShortcutInput");
  });
});

describe("GENERAL_SHORTCUT_REMINDER_IDS", () => {
  test("son sólo dictar y cancelar, en ese orden", () => {
    expect(GENERAL_SHORTCUT_REMINDER_IDS).toEqual(["transcribe", "cancel"]);
  });
});

describe("buildGeneralShortcutReminderEntries", () => {
  test("lee la tecla actual de cada binding general", () => {
    expect(
      buildGeneralShortcutReminderEntries({
        transcribe: { current_binding: "option+space" },
        cancel: { current_binding: "escape" },
      }),
    ).toEqual([
      { id: "transcribe", shortcut: "option+space" },
      { id: "cancel", shortcut: "escape" },
    ]);
  });

  test("un binding sin tecla (string vacío) queda null, no el string vacío", () => {
    expect(
      buildGeneralShortcutReminderEntries({
        transcribe: { current_binding: "" },
      }),
    ).toEqual([
      { id: "transcribe", shortcut: null },
      { id: "cancel", shortcut: null },
    ]);
  });

  test("sin bindings (null/undefined), todo sale sin tecla", () => {
    expect(buildGeneralShortcutReminderEntries(null)).toEqual([
      { id: "transcribe", shortcut: null },
      { id: "cancel", shortcut: null },
    ]);
    expect(buildGeneralShortcutReminderEntries(undefined)).toEqual([
      { id: "transcribe", shortcut: null },
      { id: "cancel", shortcut: null },
    ]);
  });
});

describe("buildDictationModeEntries", () => {
  const local: PostProcessProvider = {
    id: "apple_intelligence",
    label: "Apple Intelligence",
    base_url: "",
    is_local: true,
  };
  const online: PostProcessProvider = {
    id: "openai",
    label: "OpenAI",
    base_url: "https://api.openai.com/v1",
    is_local: false,
  };
  const settings = {
    post_process_provider_id: "openai",
    post_process_providers: [local, online],
    post_process_models: { apple_intelligence: "on-device" },
  };

  const clean: LLMPrompt = {
    id: "dilo-clean",
    name: "Limpio",
    prompt: "Mejora la gramática: ${output}",
    shortcut: "fn+f17",
    provider_id: "apple_intelligence",
    model: null,
  };
  const email: LLMPrompt = {
    id: "dilo-email",
    name: "Email",
    prompt: "Convierte en correo: ${output}",
    shortcut: null,
    provider_id: null,
    model: null,
  };
  const custom: LLMPrompt = {
    id: "mi-modo",
    name: "Mi modo",
    prompt: "Instrucciones propias: ${output}",
    shortcut: "",
    provider_id: null,
    model: null,
  };

  test("los cinco presets van primero, en el orden fijo de DICTATION_MODE_PRESETS", () => {
    const entries = buildDictationModeEntries([clean, email], settings);
    expect(entries.map((entry) => entry.id)).toEqual([
      "dilo-clean",
      "dilo-prompt",
      "dilo-message",
      "dilo-email",
      "dilo-code",
    ]);
    expect(entries.every((entry) => entry.isPreset)).toBe(true);
  });

  test("un modo propio del usuario aparece después de los presets, en el orden de post_process_prompts", () => {
    const entries = buildDictationModeEntries([clean, custom, email], settings);
    expect(entries.map((entry) => entry.id)).toEqual([
      "dilo-clean",
      "dilo-prompt",
      "dilo-message",
      "dilo-email",
      "dilo-code",
      "mi-modo",
    ]);
    const customEntry = entries.find((entry) => entry.id === "mi-modo");
    expect(customEntry).toEqual({
      id: "mi-modo",
      promptId: "mi-modo",
      isPreset: false,
      labelKey: null,
      descriptionKey: null,
      name: "Mi modo",
      description: "Instrucciones propias: ${output}",
      shortcut: null, // "" normalizado a null
      badge: resolveModeProviderBadge(custom, settings),
    });
  });

  test("un prompt con el mismo id que un preset no se repite como modo propio", () => {
    const entries = buildDictationModeEntries([clean, email], settings);
    expect(entries.filter((entry) => entry.id === "dilo-clean")).toHaveLength(
      1,
    );
  });

  test("un preset sin tecla asignada queda con shortcut null, no se esconde de la lista", () => {
    const entries = buildDictationModeEntries([clean, email], settings);
    const emailEntry = entries.find((entry) => entry.id === "dilo-email");
    expect(emailEntry?.shortcut).toBeNull();
  });

  test("un preset con tecla trae la tecla normalizada", () => {
    const entries = buildDictationModeEntries([clean, email], settings);
    const cleanEntry = entries.find((entry) => entry.id === "dilo-clean");
    expect(cleanEntry?.shortcut).toBe("fn+f17");
  });

  test("la insignia de cada fila usa la configuración real, no un objeto vacío", () => {
    const entries = buildDictationModeEntries([clean, email], settings);
    const cleanEntry = entries.find((entry) => entry.id === "dilo-clean");
    const emailEntry = entries.find((entry) => entry.id === "dilo-email");
    expect(cleanEntry?.badge).toBe("local");
    expect(emailEntry?.badge).toBe("online");
  });

  test("sin settings (null/undefined), ninguna fila muestra insignia", () => {
    const entries = buildDictationModeEntries([clean, email], null);
    expect(entries.every((entry) => entry.badge === null)).toBe(true);
  });

  test("un preset sin prompt correspondiente igual aparece, sin tecla", () => {
    // Sin prompt propio, `resolveModeProviderBadge` hereda el proveedor
    // general (mismo comportamiento que un modo que no fija `provider_id`) —
    // no es "sin insignia", es la insignia del proveedor general.
    const entries = buildDictationModeEntries([], settings);
    expect(entries).toHaveLength(5);
    expect(entries.every((entry) => entry.shortcut === null)).toBe(true);
    expect(entries.every((entry) => entry.badge === "online")).toBe(true);
  });
});

describe("isLastRemainingMode", () => {
  test("no se puede borrar cuando es el único modo", () => {
    expect(isLastRemainingMode([{ id: "dilo-clean" }])).toBe(true);
  });

  test("se puede borrar cuando hay más de uno", () => {
    expect(
      isLastRemainingMode([{ id: "dilo-clean" }, { id: "dilo-email" }]),
    ).toBe(false);
  });

  test("no hay nada que borrar en una lista vacía", () => {
    expect(isLastRemainingMode([])).toBe(true);
  });
});

describe("buildModeListEntries", () => {
  // Regresión: el componente componía `resolveModeProviderBadge(prompt,
  // settings ?? {})` por fila directamente en el JSX. Esta prueba fija esa
  // composición completa (prompts + settings crudos, incluido `null`) para
  // que una mutación al sitio de la llamada —por ejemplo pasar `{}` en vez
  // de `settings`— la note un test, no sólo la función interna.
  const local: PostProcessProvider = {
    id: "apple_intelligence",
    label: "Apple Intelligence",
    base_url: "",
    is_local: true,
  };
  const online: PostProcessProvider = {
    id: "openai",
    label: "OpenAI",
    base_url: "https://api.openai.com/v1",
    is_local: false,
  };
  const clean: LLMPrompt = {
    id: "dilo-clean",
    name: "Limpio",
    prompt: "Mejora la gramática: ${output}",
    shortcut: null,
    provider_id: "apple_intelligence",
    model: null,
  };
  const email: LLMPrompt = {
    id: "dilo-email",
    name: "Email",
    prompt: "Convierte en correo: ${output}",
    shortcut: null,
    provider_id: null,
    model: null,
  };

  test("resuelve la insignia de cada modo contra la configuración real", () => {
    const settings = {
      post_process_provider_id: "openai",
      post_process_providers: [local, online],
      post_process_models: { apple_intelligence: "on-device" },
    };

    expect(buildModeListEntries([clean, email], settings)).toEqual([
      { prompt: clean, badge: "local" },
      { prompt: email, badge: "online" },
    ]);
  });

  test("sin settings (null/undefined), ninguna fila muestra insignia", () => {
    expect(buildModeListEntries([clean, email], null)).toEqual([
      { prompt: clean, badge: null },
      { prompt: email, badge: null },
    ]);
    expect(buildModeListEntries([clean, email], undefined)).toEqual([
      { prompt: clean, badge: null },
      { prompt: email, badge: null },
    ]);
  });

  test("lista vacía de prompts da lista vacía de filas", () => {
    expect(
      buildModeListEntries([], { post_process_provider_id: "openai" }),
    ).toEqual([]);
  });
});

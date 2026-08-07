import { describe, expect, test } from "bun:test";
import {
  DICTATION_MODE_PRESETS,
  pickProviderForScope,
  resolveModeProviderId,
} from "@/lib/postProcessPresets";
import type { PostProcessProvider } from "@/bindings";

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

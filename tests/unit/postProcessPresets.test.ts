import { describe, expect, test } from "bun:test";
import {
  DICTATION_MODE_PRESETS,
  getActiveDictationMode,
  resolveModeProviderId,
} from "@/lib/postProcessPresets";
import type { PostProcessProvider } from "@/bindings";

describe("dictation modes", () => {
  test("uses literal mode when post-processing is disabled", () => {
    expect(
      getActiveDictationMode({
        post_process_enabled: false,
        post_process_selected_prompt_id: "dilo-prompt",
      }),
    ).toBe("literal");
  });

  test("resolves a selected built-in preset", () => {
    expect(
      getActiveDictationMode({
        post_process_enabled: true,
        post_process_selected_prompt_id: "dilo-code",
      }),
    ).toBe("dilo-code");
  });

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

import { describe, expect, test } from "bun:test";
import {
  DICTATION_MODE_PRESETS,
  getActiveDictationMode,
} from "@/lib/postProcessPresets";

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

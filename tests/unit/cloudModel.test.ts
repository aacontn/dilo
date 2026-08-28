import { describe, expect, test } from "bun:test";
import type { ModelInfo } from "@/bindings";
import {
  hasGoogleApiKey,
  isCloudModel,
  isGeminiModel,
} from "@/lib/utils/cloudModel";

const gemini = {
  id: "gemini-3.5-transcribe",
  source: "Cloud",
  engine_type: "GeminiTranscribe",
} as unknown as ModelInfo;

const localGguf = {
  id: "parakeet-tdt-0.6b-v3",
  source: {
    HuggingFace: { repo_id: "handy-computer/parakeet", revision: "m" },
  },
  engine_type: "TranscribeCpp",
} as unknown as ModelInfo;

const legacyUrl = {
  id: "whisper-small",
  source: { Url: { url: "https://blob/small.bin", sha256: null } },
  engine_type: "TranscribeCpp",
} as unknown as ModelInfo;

describe("isCloudModel", () => {
  test("la variante Cloud llega como el string pelado", () => {
    expect(isCloudModel(gemini)).toBe(true);
  });

  test("los modelos con archivo no son en línea", () => {
    expect(isCloudModel(localGguf)).toBe(false);
    expect(isCloudModel(legacyUrl)).toBe(false);
    expect(isCloudModel({ source: "Local" } as unknown as ModelInfo)).toBe(
      false,
    );
  });
});

describe("isGeminiModel", () => {
  test("reconoce el motor, no el id", () => {
    expect(isGeminiModel(gemini)).toBe(true);
    expect(
      isGeminiModel({
        engine_type: "GeminiTranscribe",
        id: "otro-gemini",
      } as unknown as ModelInfo),
    ).toBe(true);
  });

  test("un motor local nunca es Gemini", () => {
    expect(isGeminiModel(localGguf)).toBe(false);
  });
});

describe("hasGoogleApiKey", () => {
  test("hay key cuando el proveedor google trae algo escrito", () => {
    expect(
      hasGoogleApiKey({ post_process_api_keys: { google: "AIza..." } }),
    ).toBe(true);
  });

  test("una key en blanco o sólo espacios no cuenta", () => {
    expect(hasGoogleApiKey({ post_process_api_keys: { google: "" } })).toBe(
      false,
    );
    expect(hasGoogleApiKey({ post_process_api_keys: { google: "   " } })).toBe(
      false,
    );
  });

  test("la key de otro proveedor no sirve para Gemini", () => {
    expect(hasGoogleApiKey({ post_process_api_keys: { openai: "sk-1" } })).toBe(
      false,
    );
  });

  test("sin settings cargados todavía, no hay key", () => {
    expect(hasGoogleApiKey(null)).toBe(false);
    expect(hasGoogleApiKey({})).toBe(false);
  });
});

import { describe, expect, test } from "bun:test";
import type { ModelInfo } from "@/bindings";
import { prioritizeRecommendedModels } from "@/lib/utils/onboarding";

const model = (id: string, filename: string, repoId: string): ModelInfo =>
  ({
    id,
    filename,
    source: { HuggingFace: { repo_id: repoId, revision: "main" } },
  }) as ModelInfo;

const nemotron = model(
  "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf",
  "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf",
  "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf",
);
const canary = model(
  "handy-computer/canary-180m-flash-gguf/canary-180m-flash-Q8_0.gguf",
  "canary-180m-flash-Q8_0.gguf",
  "handy-computer/canary-180m-flash-gguf",
);

describe("prioritizeRecommendedModels", () => {
  test("puts Canary first on machines with 8 GB or less", () => {
    expect(prioritizeRecommendedModels([nemotron, canary], 8)).toEqual([
      canary,
      nemotron,
    ]);
  });

  test("keeps editorial order on machines with more than 8 GB", () => {
    expect(prioritizeRecommendedModels([nemotron, canary], 16)).toEqual([
      nemotron,
      canary,
    ]);
  });

  test("keeps editorial order when RAM cannot be detected", () => {
    expect(prioritizeRecommendedModels([nemotron, canary], null)).toEqual([
      nemotron,
      canary,
    ]);
  });
});

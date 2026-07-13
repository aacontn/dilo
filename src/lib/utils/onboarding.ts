import type { ModelInfo } from "@/bindings";

const LOW_RAM_GB = 8;
const CANARY_REPO_ID = "handy-computer/canary-180m-flash-gguf";

const isLowRamPick = (model: ModelInfo): boolean => {
  if (
    typeof model.source === "object" &&
    "HuggingFace" in model.source &&
    model.source.HuggingFace.repo_id === CANARY_REPO_ID
  ) {
    return true;
  }

  return model.filename.startsWith("canary-180m-flash-");
};

export const prioritizeRecommendedModels = (
  models: ModelInfo[],
  ramGb: number | null,
): ModelInfo[] => {
  if (ramGb === null || ramGb > LOW_RAM_GB) return models;

  return [...models].sort(
    (a, b) => Number(isLowRamPick(b)) - Number(isLowRamPick(a)),
  );
};

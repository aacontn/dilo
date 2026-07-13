export type OnboardingStep = "accessibility" | "model" | "test" | "done";
export type OnboardingEvent =
  | "permissions-complete"
  | "model-selected"
  | "test-complete";

export const getNextOnboardingStep = (
  event: OnboardingEvent,
  returningUser: boolean,
): OnboardingStep => {
  if (event === "permissions-complete") {
    return returningUser ? "done" : "model";
  }
  if (event === "model-selected") return "test";
  return "done";
};

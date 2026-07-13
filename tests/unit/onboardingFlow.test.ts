import { describe, expect, test } from "bun:test";
import { getNextOnboardingStep } from "@/lib/utils/onboardingFlow";

describe("onboarding flow", () => {
  test("new users complete permissions, model selection and a real test", () => {
    expect(getNextOnboardingStep("permissions-complete", false)).toBe("model");
    expect(getNextOnboardingStep("model-selected", false)).toBe("test");
    expect(getNextOnboardingStep("test-complete", false)).toBe("done");
  });

  test("returning users only repair permissions", () => {
    expect(getNextOnboardingStep("permissions-complete", true)).toBe("done");
  });
});

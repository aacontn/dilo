import { describe, expect, test } from "bun:test";
import { getAppAppearance } from "../../src/lib/utils/appearance";

describe("Dilo visual appearance", () => {
  test.each(["macos", "windows", "linux"])(
    "uses Liquid Glass on %s",
    (platform) => {
      expect(getAppAppearance(platform)).toBe("liquid-glass");
    },
  );
});

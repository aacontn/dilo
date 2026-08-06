import { describe, expect, it } from "bun:test";
import { comboFromHandyKeysEvent } from "@/lib/utils/keyboard";

describe("captura de atajos de modo", () => {
  it("conserva fn, que el navegador nunca reporta en macOS", () => {
    expect(comboFromHandyKeysEvent({ modifiers: ["fn"], key: "F17" })).toBe(
      "fn+f17",
    );
  });

  it("una tecla sin modificadores queda sola", () => {
    expect(comboFromHandyKeysEvent({ modifiers: [], key: "F17" })).toBe("f17");
  });
});

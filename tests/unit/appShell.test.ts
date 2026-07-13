import { describe, expect, test } from "bun:test";

describe("Dilo product shell", () => {
  test("opens on the status-first home", async () => {
    const source = await Bun.file("src/App.tsx").text();
    expect(source).toContain('useState<SidebarSection>("home")');
    expect(source).toContain("DictationTestOnboarding");
  });

  test("keeps the personal dictionary in first-level settings", async () => {
    const source = await Bun.file(
      "src/components/settings/general/GeneralSettings.tsx",
    ).text();
    expect(source).toContain("<CustomWords");
  });
});

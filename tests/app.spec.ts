import { test, expect } from "@playwright/test";

test.describe("Dilo App", () => {
  test("serves the branded application shell", async ({ page }) => {
    const response = await page.goto("/");
    expect(response?.status()).toBe(200);
    await expect(page).toHaveTitle("Dilo");
    await expect(page.locator("html")).toHaveAttribute(
      "lang",
      /^[a-z]{2}(?:-[A-Z]{2})?$/,
    );
    await expect(page.locator("#root")).toBeAttached();
  });
});

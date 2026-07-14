import { describe, expect, test } from "bun:test";

const readHexToken = (source: string, token: string): string | null => {
  const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return (
    source.match(new RegExp(`${escaped}:\\s*(#[0-9a-fA-F]{6})`))?.[1] ?? null
  );
};

const relativeLuminance = (hex: string): number => {
  const channels = hex
    .slice(1)
    .match(/.{2}/g)!
    .map((channel) => Number.parseInt(channel, 16) / 255)
    .map((channel) =>
      channel <= 0.04045
        ? channel / 12.92
        : Math.pow((channel + 0.055) / 1.055, 2.4),
    );

  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
};

const contrastRatio = (foreground: string, background: string): number => {
  const lighter = Math.max(
    relativeLuminance(foreground),
    relativeLuminance(background),
  );
  const darker = Math.min(
    relativeLuminance(foreground),
    relativeLuminance(background),
  );
  return (lighter + 0.05) / (darker + 0.05);
};

describe("Dilo semantic text colors", () => {
  const semanticTokens = [
    "accent",
    "success",
    "danger",
    "warning",
    "info",
    "muted",
  ];

  for (const token of semanticTokens) {
    test(`${token} meets WCAG AA contrast on the light paper background`, async () => {
      const theme = await Bun.file("src/styles/theme.css").text();
      const brand = await Bun.file("src/styles/brand.css").text();
      const foreground = readHexToken(theme, `--light-color-${token}-text`);
      const background = readHexToken(brand, "--dilo-papel");

      expect(foreground).not.toBeNull();
      expect(background).not.toBeNull();
      if (!foreground || !background) return;

      expect(contrastRatio(foreground, background)).toBeGreaterThanOrEqual(4.5);
    });

    test(`${token} meets WCAG AA contrast on the dark ink background`, async () => {
      const theme = await Bun.file("src/styles/theme.css").text();
      const brand = await Bun.file("src/styles/brand.css").text();
      const foreground = readHexToken(theme, `--dark-color-${token}-text`);
      const background = readHexToken(brand, "--dilo-ink");

      expect(foreground).not.toBeNull();
      expect(background).not.toBeNull();
      if (!foreground || !background) return;

      expect(contrastRatio(foreground, background)).toBeGreaterThanOrEqual(4.5);
    });
  }
});

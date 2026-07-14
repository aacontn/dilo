export const APP_APPEARANCE = "liquid-glass" as const;

/**
 * Dilo uses the same visual identity on every desktop platform. Keeping the
 * platform argument makes the contract explicit and leaves room for native
 * window-chrome differences without fragmenting the app surfaces themselves.
 */
export const getAppAppearance = (_platform: string) => APP_APPEARANCE;

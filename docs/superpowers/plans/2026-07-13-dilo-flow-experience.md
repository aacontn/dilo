# Dilo Flow Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dilo feel as immediate as Wispr Flow while preserving its local-first, Spanish-first identity.

**Architecture:** Add a status-first home screen and a real final onboarding test using existing settings, model, history, and shortcut APIs. Keep literal dictation as the default; expose post-processing as named presets backed by stable built-in prompts. Isolate recommendation and mode-selection rules in pure TypeScript helpers so Bun can test them without a Tauri runtime.

**Tech Stack:** React 18, TypeScript, Zustand, i18next, Tauri 2, Rust, Bun test.

## Global Constraints

- Spanish user-facing copy uses tuteo, direct language, and no corporate filler.
- Audio and transcription remain local unless the user explicitly enables a post-processing provider.
- Existing advanced settings and all upstream-compatible model behavior remain available.
- No new runtime dependency.
- Work in the current checkout because the user explicitly requested the implementation in this workspace.

---

### Task 1: Recommendation and public-claim corrections

**Files:**

- Create: `src/lib/utils/onboarding.ts`
- Create: `tests/unit/onboarding.test.ts`
- Modify: `src/components/onboarding/Onboarding.tsx`
- Modify: `../dilo-landing/index.html`

**Interfaces:**

- Produces: `prioritizeRecommendedModels(models: ModelInfo[], ramGb: number | null): ModelInfo[]`.

- [ ] **Step 1: Write a failing Bun test** proving an 8 GB machine moves the Canary GGUF descriptor ahead of Nemotron while a 16 GB machine preserves editorial order.
- [ ] **Step 2: Run `bun test tests/unit/onboarding.test.ts`** and confirm failure because the helper does not exist.
- [ ] **Step 3: Implement the helper** by matching Canary through its stable Hugging Face repo id or filename, then use it in onboarding.
- [ ] **Step 4: Run the test again** and confirm both cases pass.
- [ ] **Step 5: Update landing claims** to distinguish initial RAM from post-first-dictation RAM and correct Superwhisper platform support.

### Task 2: Status-first home

**Files:**

- Create: `src/components/home/HomeDashboard.tsx`
- Create: `src/components/home/index.ts`
- Modify: `src/components/Sidebar.tsx`
- Modify: `src/App.tsx`
- Modify: `src/components/settings/index.ts`
- Modify: `src/i18n/locales/en/translation.json`
- Modify: `src/i18n/locales/es/translation.json`

**Interfaces:**

- Consumes: `useSettings()`, `useModelStore()`, `commands.getHistoryEntries()`.
- Produces: a no-prop `HomeDashboard` section rendered as the default sidebar destination.

- [ ] **Step 1: Add failing source-level UI assertions** for the home translation keys and default `home` route.
- [ ] **Step 2: Run the focused test** and verify the new expectations fail.
- [ ] **Step 3: Implement the dashboard** with ready state, primary shortcut, active model, local privacy message, latest three dictations, and visible secondary smart-dictation shortcut.
- [ ] **Step 4: Add Home to sidebar and make it the default section.**
- [ ] **Step 5: Run the focused test and TypeScript build.**

### Task 3: Human-readable dictation modes

**Files:**

- Create: `src/lib/postProcessPresets.ts`
- Create: `tests/unit/postProcessPresets.test.ts`
- Create: `src/components/home/DictationModes.tsx`
- Modify: `src/components/home/HomeDashboard.tsx`
- Modify: `src-tauri/src/settings.rs`
- Modify: `src/i18n/locales/en/translation.json`
- Modify: `src/i18n/locales/es/translation.json`

**Interfaces:**

- Produces: stable preset ids `dilo-clean`, `dilo-prompt`, `dilo-message`, `dilo-email`, and `dilo-code` plus `getActiveDictationMode(settings)`.

- [ ] **Step 1: Write failing TypeScript tests** for literal mode and selected preset resolution.
- [ ] **Step 2: Write a failing Rust test** proving stored settings gain missing Dilo presets without deleting custom prompts.
- [ ] **Step 3: Run both tests and verify the expected failures.**
- [ ] **Step 4: Implement stable built-in prompt definitions and migration seeding.**
- [ ] **Step 5: Implement mode cards** where Literal disables post-processing and another mode selects its prompt and enables post-processing.
- [ ] **Step 6: Run both focused suites and verify they pass.**

### Task 4: Real final onboarding test

**Files:**

- Create: `src/components/onboarding/DictationTestOnboarding.tsx`
- Create: `src/lib/utils/onboardingFlow.ts`
- Create: `tests/unit/onboardingFlow.test.ts`
- Modify: `src/components/onboarding/index.ts`
- Modify: `src/App.tsx`
- Modify: `src/i18n/locales/en/translation.json`
- Modify: `src/i18n/locales/es/translation.json`

**Interfaces:**

- Produces: onboarding step `test`; `nextOnboardingStep(event, returningUser)` pure transition helper.

- [ ] **Step 1: Write failing transition tests** proving new users go permissions → model → test → done and returning users go permissions → done.
- [ ] **Step 2: Run the focused test and confirm failure.**
- [ ] **Step 3: Implement the transition helper and test screen** with an autofocus textarea that receives Dilo's real paste output, success state, retry/skip, and shortcut guidance.
- [ ] **Step 4: Wire the new step into App.**
- [ ] **Step 5: Run the focused test and TypeScript build.**

### Task 5: Dictionary prominence and verification

**Files:**

- Modify: `src/components/settings/general/GeneralSettings.tsx`
- Modify: `src/i18n/locales/en/translation.json`
- Modify: `src/i18n/locales/es/translation.json`
- Modify: `tests/app.spec.ts`

**Interfaces:**

- Consumes: existing `CustomWords` component.
- Produces: first-level “Tu diccionario” group in General settings and stronger browser smoke assertions.

- [ ] **Step 1: Write a failing UI source assertion** for the dictionary group and meaningful app shell labels.
- [ ] **Step 2: Run it and confirm failure.**
- [ ] **Step 3: Surface `CustomWords` in General** and update copy from technical “custom words” language to “Tu diccionario”.
- [ ] **Step 4: Replace HTML-only Playwright checks** with assertions that the built shell and brand load; keep Tauri-dependent flows covered by pure and Rust tests.
- [ ] **Step 5: Run `bun run lint`, `bun run check:translations`, `bun run build`, `bun test`, `bun run test:playwright`, and `cargo test --manifest-path src-tauri/Cargo.toml --lib`.**

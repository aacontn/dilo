/**
 * Conflict detection for per-mode and global keyboard shortcuts.
 *
 * Before this module, assigning an already-used key silently produced a dead
 * shortcut: two owners (a general binding and/or a post-process mode) could
 * end up pointing at the same combo, and whichever lost the race at dispatch
 * time never fired — with no warning to the user. As modes multiply (each
 * with its own optional shortcut, see `LLMPrompt.shortcut` in
 * `src/bindings.ts`), collisions with the general bindings (`settings.bindings`)
 * become far more likely than they were with a single fixed set of hotkeys.
 *
 * This is advisory, not a hard block: `findShortcutConflict` only reports who
 * already owns a combo. Callers decide whether to refuse the save (that's
 * what `ModeShortcutInput.tsx` does today).
 */

import { normalizeKey } from "./keyboard";
import type { AppSettings } from "@/bindings";

/** A thing that can own a keyboard shortcut combo. */
export interface ShortcutOwner {
  /** `"binding"` for entries in `settings.bindings`, `"mode"` for a post-process prompt's own shortcut. */
  kind: "binding" | "mode";
  /** Stable id: the binding id (e.g. `"transcribe"`) or the mode/prompt id (e.g. `"dilo-email"`). */
  id: string;
  /** Display name shown to the user in the conflict warning. */
  name: string;
  /** Raw combo string, e.g. `"fn+f19"` or `"option_left+shift+space"`. */
  combo: string;
}

/**
 * Normalize a combo string for comparison: lowercase each key part, collapse
 * left/right modifier variants via the same `normalizeKey` the capture paths
 * already use (see `keyboard.ts`), and sort the parts so modifier order
 * (`"shift+fn"` vs `"fn+shift"`) doesn't produce a false "no conflict".
 * Comparing raw strings would miss both of these.
 */
const normalizeCombo = (combo: string): string =>
  combo
    .split("+")
    .map((part) => normalizeKey(part.trim().toLowerCase()))
    .filter((part) => part.length > 0)
    .sort()
    .join("+");

/**
 * Find the owner (if any) that already holds `combo`, other than `selfId`
 * itself — so reassigning a mode's own current shortcut to itself is never
 * reported as a conflict. Returns `null` when the combo is free or empty.
 */
export function findShortcutConflict(
  combo: string,
  owners: ShortcutOwner[],
  selfId: string,
): ShortcutOwner | null {
  const normalized = normalizeCombo(combo);
  if (!normalized) return null;

  for (const owner of owners) {
    if (owner.id === selfId) continue;
    if (!owner.combo) continue;
    if (normalizeCombo(owner.combo) === normalized) {
      return owner;
    }
  }

  return null;
}

/**
 * Build the full list of shortcut owners from app settings: the general
 * bindings (`settings.bindings`, keyed by binding id) plus every
 * post-process mode that has its own shortcut assigned
 * (`settings.post_process_prompts[].shortcut`). Modes without a shortcut are
 * skipped — an unset shortcut can't conflict with anything.
 *
 * Pulled out as its own pure function (rather than inlined in
 * `ModeShortcutInput.tsx`) so the conflict-detection wiring — not just
 * `findShortcutConflict` in isolation — has a unit-testable surface. See the
 * Task 1 follow-up note: covering the pure comparison alone missed a
 * regression at the call site because nothing exercised how the component
 * assembles its inputs.
 */
export function buildShortcutOwners(
  settings:
    | Pick<AppSettings, "bindings" | "post_process_prompts">
    | null
    | undefined,
): ShortcutOwner[] {
  if (!settings) return [];

  const bindingOwners: ShortcutOwner[] = Object.values(settings.bindings ?? {})
    .filter((binding): binding is NonNullable<typeof binding> =>
      Boolean(binding),
    )
    .map((binding) => ({
      kind: "binding" as const,
      id: binding.id,
      name: binding.name,
      combo: binding.current_binding,
    }));

  const modeOwners: ShortcutOwner[] = (settings.post_process_prompts ?? [])
    .filter((prompt) => Boolean(prompt.shortcut))
    .map((prompt) => ({
      kind: "mode" as const,
      id: prompt.id,
      name: prompt.name,
      combo: prompt.shortcut as string,
    }));

  return [...bindingOwners, ...modeOwners];
}

/**
 * Fuse `buildShortcutOwners` + `findShortcutConflict` into the single call
 * `ModeShortcutInput.tsx` makes when committing a newly recorded combo. The
 * component call site was already down to one line, but a two-call
 * composition (`findShortcutConflict(combo, buildShortcutOwners(settings),
 * selfId)`) is still exactly the shape that let the Task 1 regression slip
 * past its tests: a call site can't be mounted in `bun test` (no React), so
 * a mutation to *how the pieces are wired together* — wrong argument order,
 * the wrong settings object, a dropped `selfId` — would pass every existing
 * unit test even though the app is broken. Folding both calls into one pure
 * function means that composition itself is exercised directly by
 * `shortcutConflicts.test.ts`, leaving the component with nothing left to
 * get wrong beyond "call this and branch on the result".
 */
export function resolveShortcutConflict(
  combo: string,
  settings:
    | Pick<AppSettings, "bindings" | "post_process_prompts">
    | null
    | undefined,
  selfId: string,
): ShortcutOwner | null {
  return findShortcutConflict(combo, buildShortcutOwners(settings), selfId);
}

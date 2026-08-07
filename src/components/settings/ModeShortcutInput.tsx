import React, { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { listen } from "@tauri-apps/api/event";
import { X } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import {
  attachOrDiscardListener,
  comboFromHandyKeysEvent,
  formatKeyCombination,
  getKeyName,
  normalizeKey,
} from "../../lib/utils/keyboard";
import { resolveShortcutConflict } from "../../lib/utils/shortcutConflicts";
import { useOsType } from "../../hooks/useOsType";
import { useSettings } from "../../hooks/useSettings";

interface ModeShortcutInputProps {
  promptId: string;
  shortcut: string | null | undefined;
  /**
   * Compact variant for embedding inside cards: hides the label and hint and
   * uses tighter paddings. Clicks are also kept from bubbling so a surrounding
   * clickable card doesn't react to shortcut edits.
   */
  compact?: boolean;
}

/**
 * Mirrors the `HandyKeysEvent` payload emitted by the backend (see
 * `HandyKeysShortcutInput.tsx`). Declared locally rather than shared because
 * that component is a reference implementation we don't touch.
 */
interface HandyKeysEvent {
  modifiers: string[];
  key: string | null;
  is_key_down: boolean;
  hotkey_string: string;
}

const MODIFIERS = [
  "ctrl",
  "control",
  "shift",
  "alt",
  "option",
  "meta",
  "command",
  "cmd",
  "super",
  "win",
  "windows",
];

/**
 * Shortcut capture input for per-mode shortcuts. Mode shortcuts live inside
 * each LLMPrompt (not in the bindings map), so this commits through
 * `change_mode_shortcut` instead of the regular binding commands.
 */
export const ModeShortcutInput: React.FC<ModeShortcutInputProps> = ({
  promptId,
  shortcut,
  compact = false,
}) => {
  const { t } = useTranslation();
  const { getSetting, refreshSettings, settings } = useSettings();
  const osType = useOsType();
  // Mode shortcuts must be captured the same way general shortcuts are for
  // the active keyboard implementation (see `ShortcutInput.tsx`): the native
  // handy-keys recorder when it's active — it's the only one that sees `fn`
  // on macOS — and the browser-event capture otherwise (e.g. Linux, whose
  // default implementation is "tauri").
  const usesHandyKeys = getSetting("keyboard_implementation") === "handy_keys";
  const [editing, setEditing] = useState(false);
  const [keyPressed, setKeyPressed] = useState<string[]>([]);
  const [recordedKeys, setRecordedKeys] = useState<string[]>([]);
  const originalRef = useRef<string>("");
  const containerRef = useRef<HTMLDivElement | null>(null);
  const unlistenRef = useRef<(() => void) | null>(null);
  // Tracks the latest native combo for the key-up handler (avoids stale closures).
  const currentComboRef = useRef<string>("");

  const applyShortcut = async (value: string) => {
    const result = await commands.changeModeShortcut(promptId, value);
    if (result.status === "error") {
      throw new Error(result.error);
    }
    await refreshSettings();
  };

  const restoreOriginal = async () => {
    if (!originalRef.current) return;
    try {
      await applyShortcut(originalRef.current);
    } catch (restoreError) {
      console.error("Failed to restore mode shortcut:", restoreError);
    }
  };

  /**
   * Commit a freshly recorded combo, but only after checking it isn't
   * already claimed by a general binding or another mode (see
   * `shortcutConflicts.ts`). This is advisory-but-blocking: on conflict we
   * warn and restore the original shortcut instead of silently creating a
   * dead hotkey where one of the two owners never fires.
   */
  const commitShortcut = async (combo: string) => {
    const conflict = resolveShortcutConflict(combo, settings, promptId);
    if (conflict) {
      toast.error(t("settings.shortcuts.conflict", { name: conflict.name }));
      await restoreOriginal();
      return;
    }

    try {
      await applyShortcut(combo);
    } catch (error) {
      toast.error(String(error));
      await restoreOriginal();
    }
  };

  const stopEditing = () => {
    setEditing(false);
    setKeyPressed([]);
    setRecordedKeys([]);
    currentComboRef.current = "";
  };

  const startEditing = async () => {
    if (editing) return;
    originalRef.current = shortcut ?? "";
    // Free the current combo so pressing it while recording doesn't dictate.
    try {
      await applyShortcut("");
    } catch (error) {
      console.error("Failed to release mode shortcut:", error);
    }

    if (usesHandyKeys) {
      try {
        await commands.startHandyKeysRecording(promptId);
      } catch (error) {
        console.error("Failed to start mode shortcut recording:", error);
        toast.error(
          t("settings.general.shortcut.errors.set", {
            error: String(error),
          }),
        );
        await restoreOriginal();
        return;
      }
    }

    setEditing(true);
    setKeyPressed([]);
    setRecordedKeys([]);
    currentComboRef.current = "";
  };

  const cancelEditing = async () => {
    if (usesHandyKeys) {
      if (unlistenRef.current) {
        unlistenRef.current();
        unlistenRef.current = null;
      }
      await commands.stopHandyKeysRecording().catch(console.error);
    }
    stopEditing();
    await restoreOriginal();
  };

  const clearShortcut = async () => {
    try {
      await applyShortcut("");
    } catch (error) {
      toast.error(String(error));
    }
  };

  // Native (handy-keys) capture — the only path that sees `fn` on macOS.
  useEffect(() => {
    if (!editing || !usesHandyKeys) return;
    let cleanup = false;

    const setupListener = async () => {
      const unlisten = await listen<HandyKeysEvent>(
        "handy-keys-event",
        async (event) => {
          if (cleanup) return;
          const { modifiers, key, is_key_down } = event.payload;

          if (is_key_down) {
            const combo = comboFromHandyKeysEvent({ modifiers, key });
            if (combo) {
              currentComboRef.current = combo;
              setRecordedKeys(combo.split("+"));
            }
          } else if (!is_key_down && currentComboRef.current) {
            // Key released - commit the shortcut using the ref value.
            const comboToCommit = currentComboRef.current;

            if (unlistenRef.current) {
              unlistenRef.current();
              unlistenRef.current = null;
            }
            await commands.stopHandyKeysRecording().catch(console.error);
            stopEditing();

            await commitShortcut(comboToCommit);
          }
        },
      );

      // `cleanup` may already be true here if the effect's cleanup ran
      // before this promise settled (cancel, commit, or unmount raced
      // ahead of `listen()`). In that case `unlistenRef` was never touched
      // by the cleanup below, so store nothing — unsubscribe immediately
      // instead, or this listener would live for the rest of the app.
      attachOrDiscardListener(unlisten, cleanup, (fn) => {
        unlistenRef.current = fn;
      });
    };

    setupListener();

    return () => {
      cleanup = true;
      if (unlistenRef.current) {
        unlistenRef.current();
        unlistenRef.current = null;
      }
      // Stop backend recording on unmount to prevent orphaned recording loops.
      commands.stopHandyKeysRecording().catch(console.error);
    };
  }, [editing, usesHandyKeys, promptId]);

  // Browser-event capture — fallback for the "tauri" keyboard implementation,
  // which has no native recorder to fall back on (same limitation as
  // `GlobalShortcutInput.tsx`: `fn` won't be seen on macOS there either).
  useEffect(() => {
    if (!editing || usesHandyKeys) return;
    let cleanup = false;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (cleanup || e.repeat) return;
      e.preventDefault();
      const key = normalizeKey(getKeyName(e, osType));
      setKeyPressed((prev) => (prev.includes(key) ? prev : [...prev, key]));
      setRecordedKeys((prev) => (prev.includes(key) ? prev : [...prev, key]));
    };

    const handleKeyUp = async (e: KeyboardEvent) => {
      if (cleanup) return;
      e.preventDefault();
      const key = normalizeKey(getKeyName(e, osType));
      const remaining = keyPressed.filter((k) => k !== key);
      setKeyPressed(remaining);

      if (remaining.length === 0 && recordedKeys.length > 0) {
        const sorted = [...recordedKeys].sort((a, b) => {
          const aMod = MODIFIERS.includes(a.toLowerCase());
          const bMod = MODIFIERS.includes(b.toLowerCase());
          if (aMod && !bMod) return -1;
          if (!aMod && bMod) return 1;
          return 0;
        });
        stopEditing();
        await commitShortcut(sorted.join("+"));
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("keyup", handleKeyUp);
    return () => {
      cleanup = true;
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("keyup", handleKeyUp);
    };
  }, [editing, usesHandyKeys, keyPressed, recordedKeys, osType]);

  // Click outside — shared by both capture paths.
  useEffect(() => {
    if (!editing) return;
    let cleanup = false;

    const handleClickOutside = (e: MouseEvent) => {
      if (cleanup) return;
      const el = containerRef.current;
      if (el && !el.contains(e.target as Node)) {
        void cancelEditing();
      }
    };

    window.addEventListener("click", handleClickOutside);
    return () => {
      cleanup = true;
      window.removeEventListener("click", handleClickOutside);
    };
  }, [editing]);

  const display = editing
    ? recordedKeys.length > 0
      ? formatKeyCombination(recordedKeys.join("+"), osType)
      : t("settings.general.shortcut.pressKeys")
    : shortcut
      ? formatKeyCombination(shortcut, osType)
      : t("settings.postProcessing.prompts.modeShortcutEmpty");

  return (
    <div
      ref={containerRef}
      onClick={compact ? (e) => e.stopPropagation() : undefined}
      className={
        compact ? "flex items-center gap-2" : "space-y-2 flex flex-col"
      }
    >
      {!compact && (
        <label className="text-sm font-semibold">
          {t("settings.postProcessing.prompts.modeShortcut")}
        </label>
      )}
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => void startEditing()}
          className={`rounded-md border font-mono cursor-pointer transition-colors ${
            compact ? "px-2 py-1 text-xs" : "px-3 py-1.5 text-sm"
          } ${
            editing
              ? "border-logo-primary bg-logo-primary/10"
              : "border-mid-gray/40 bg-mid-gray/5 hover:border-mid-gray/70"
          }`}
        >
          {display}
        </button>
        {!editing && shortcut && (
          <button
            type="button"
            onClick={() => void clearShortcut()}
            aria-label={t("settings.postProcessing.prompts.modeShortcutClear")}
            title={t("settings.postProcessing.prompts.modeShortcutClear")}
            className="p-1.5 rounded-md text-muted-text hover:text-text hover:bg-mid-gray/10 cursor-pointer"
          >
            <X className="w-4 h-4" />
          </button>
        )}
      </div>
      {!compact && (
        <p className="text-xs text-muted-text">
          {t("settings.postProcessing.prompts.modeShortcutHint")}
        </p>
      )}
    </div>
  );
};

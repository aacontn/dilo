import React, { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { X } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import {
  formatKeyCombination,
  getKeyName,
  normalizeKey,
} from "../../lib/utils/keyboard";
import { useOsType } from "../../hooks/useOsType";
import { useSettings } from "../../hooks/useSettings";

interface ModeShortcutInputProps {
  promptId: string;
  shortcut: string | null | undefined;
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
}) => {
  const { t } = useTranslation();
  const { refreshSettings } = useSettings();
  const osType = useOsType();
  const [editing, setEditing] = useState(false);
  const [keyPressed, setKeyPressed] = useState<string[]>([]);
  const [recordedKeys, setRecordedKeys] = useState<string[]>([]);
  const originalRef = useRef<string>("");
  const containerRef = useRef<HTMLDivElement | null>(null);

  const applyShortcut = async (value: string) => {
    const result = await commands.changeModeShortcut(promptId, value);
    if (result.status === "error") {
      throw new Error(result.error);
    }
    await refreshSettings();
  };

  const stopEditing = () => {
    setEditing(false);
    setKeyPressed([]);
    setRecordedKeys([]);
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
    setEditing(true);
    setKeyPressed([]);
    setRecordedKeys([]);
  };

  const cancelEditing = async () => {
    stopEditing();
    if (originalRef.current) {
      try {
        await applyShortcut(originalRef.current);
      } catch (error) {
        console.error("Failed to restore mode shortcut:", error);
      }
    }
  };

  const clearShortcut = async () => {
    try {
      await applyShortcut("");
    } catch (error) {
      toast.error(String(error));
    }
  };

  useEffect(() => {
    if (!editing) return;
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
        try {
          await applyShortcut(sorted.join("+"));
        } catch (error) {
          toast.error(String(error));
          if (originalRef.current) {
            try {
              await applyShortcut(originalRef.current);
            } catch (restoreError) {
              console.error("Failed to restore mode shortcut:", restoreError);
            }
          }
        }
      }
    };

    const handleClickOutside = (e: MouseEvent) => {
      if (cleanup) return;
      const el = containerRef.current;
      if (el && !el.contains(e.target as Node)) {
        void cancelEditing();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("keyup", handleKeyUp);
    window.addEventListener("click", handleClickOutside);
    return () => {
      cleanup = true;
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("keyup", handleKeyUp);
      window.removeEventListener("click", handleClickOutside);
    };
  }, [editing, keyPressed, recordedKeys, osType]);

  const display = editing
    ? recordedKeys.length > 0
      ? formatKeyCombination(recordedKeys.join("+"), osType)
      : t("settings.general.shortcut.pressKeys")
    : shortcut
      ? formatKeyCombination(shortcut, osType)
      : t("settings.postProcessing.prompts.modeShortcutEmpty");

  return (
    <div ref={containerRef} className="space-y-2 flex flex-col">
      <label className="text-sm font-semibold">
        {t("settings.postProcessing.prompts.modeShortcut")}
      </label>
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => void startEditing()}
          className={`px-3 py-1.5 rounded-md border text-sm font-mono cursor-pointer transition-colors ${
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
      <p className="text-xs text-muted-text">
        {t("settings.postProcessing.prompts.modeShortcutHint")}
      </p>
    </div>
  );
};

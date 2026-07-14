import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Check,
  Copy,
  Cpu,
  Keyboard,
  LockKeyhole,
  Sparkles,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  commands,
  events,
  type HistoryEntry,
  type HistoryUpdatePayload,
} from "@/bindings";
import { formatKeyCombination } from "@/lib/utils/keyboard";
import { useOsType } from "@/hooks/useOsType";
import { useSettings } from "@/hooks/useSettings";
import { useModelStore } from "@/stores/modelStore";
import { formatRelativeTime } from "@/utils/dateFormat";
import { Button } from "../ui/Button";
import { DictationModes } from "./DictationModes";

const ShortcutBadge = ({ binding }: { binding: string }) => {
  const osType = useOsType();
  return (
    <kbd className="dilo-keycap font-mono text-xs rounded-md px-2 py-1 text-text whitespace-nowrap">
      {formatKeyCombination(binding, osType)}
    </kbd>
  );
};

export const HomeDashboard = () => {
  const { t, i18n } = useTranslation();
  const { settings } = useSettings();
  const { currentModel, models } = useModelStore();
  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [copiedId, setCopiedId] = useState<number | null>(null);

  const activeModel = useMemo(
    () => models.find((model) => model.id === currentModel),
    [currentModel, models],
  );
  const primaryShortcut =
    settings?.bindings?.transcribe?.current_binding || "option+space";
  const smartShortcut =
    settings?.bindings?.transcribe_with_post_process?.current_binding ||
    "option+shift+space";

  const loadRecent = useCallback(async () => {
    const result = await commands.getHistoryEntries(null, 3);
    if (result.status === "ok") setEntries(result.data.entries);
  }, []);

  useEffect(() => {
    loadRecent().catch((error) =>
      console.warn("Failed to load dashboard history:", error),
    );
  }, [loadRecent]);

  useEffect(() => {
    const unlisten = events.historyUpdatePayload.listen((event) => {
      const payload: HistoryUpdatePayload = event.payload;
      if (payload.action === "added") {
        setEntries((current) => [payload.entry, ...current].slice(0, 3));
      } else if (payload.action === "updated") {
        setEntries((current) =>
          current.map((entry) =>
            entry.id === payload.entry.id ? payload.entry : entry,
          ),
        );
      }
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const copyEntry = async (entry: HistoryEntry) => {
    const text = entry.post_processed_text || entry.transcription_text;
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(entry.id);
      window.setTimeout(() => setCopiedId(null), 1400);
    } catch (error) {
      console.warn("Failed to copy dashboard entry:", error);
    }
  };

  return (
    <div className="home-dashboard max-w-3xl w-full mx-auto space-y-4">
      <section className="glass-surface glass-surface--hero rounded-2xl p-5">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-2 text-menta mb-2">
              <span className="size-2 rounded-full bg-menta shadow-[0_0_0_5px_color-mix(in_srgb,var(--dilo-menta)_14%,transparent)]" />
              <span className="text-xs font-semibold uppercase tracking-[0.14em]">
                {t("home.status.label")}
              </span>
            </div>
            <h1 className="font-display text-2xl font-semibold text-text">
              {t("home.status.title")}
            </h1>
            <p className="mt-1 text-sm text-text/65">
              {t("home.status.description")}
            </p>
          </div>
          <ShortcutBadge binding={primaryShortcut} />
        </div>
        <div className="glass-inset mt-4 flex items-center gap-2 rounded-xl px-3 py-2 text-xs text-text/65">
          <LockKeyhole className="size-4 shrink-0 text-menta" />
          {t("home.status.privacy")}
        </div>
      </section>

      <div className="home-metric-grid grid grid-cols-2 gap-3">
        <section className="glass-surface rounded-xl p-4">
          <div className="flex items-center gap-2 text-text/55">
            <Cpu className="size-4" />
            <span className="text-xs font-medium uppercase tracking-wide">
              {t("home.model.label")}
            </span>
          </div>
          <p className="mt-2 truncate font-semibold text-text">
            {activeModel?.name || t("home.model.loading")}
          </p>
          <p className="mt-0.5 text-xs text-text/50">
            {activeModel?.supports_streaming
              ? t("home.model.streaming")
              : t("home.model.local")}
          </p>
        </section>

        <section className="glass-surface rounded-xl p-4">
          <div className="flex items-center gap-2 text-text/55">
            {settings?.post_process_enabled ? (
              <Sparkles className="size-4 text-logo-primary" />
            ) : (
              <Keyboard className="size-4" />
            )}
            <span className="text-xs font-medium uppercase tracking-wide">
              {t("home.smart.label")}
            </span>
          </div>
          <p className="mt-2 font-semibold text-text">
            {settings?.post_process_enabled
              ? t("home.smart.enabled")
              : t("home.smart.disabled")}
          </p>
          <div className="mt-1">
            <ShortcutBadge binding={smartShortcut} />
          </div>
        </section>
      </div>

      <DictationModes />

      <section className="glass-surface rounded-xl overflow-hidden">
        <div className="flex items-center justify-between px-4 py-3 border-b border-mid-gray/15">
          <div>
            <h2 className="font-semibold text-sm text-text">
              {t("home.history.title")}
            </h2>
            <p className="text-xs text-text/50">{t("home.history.subtitle")}</p>
          </div>
        </div>
        {entries.length === 0 ? (
          <div className="px-4 py-6 text-center text-sm text-text/50">
            {t("home.history.empty")}
          </div>
        ) : (
          <div className="divide-y divide-mid-gray/15">
            {entries.map((entry) => {
              const text =
                entry.post_processed_text || entry.transcription_text;
              return (
                <div
                  key={entry.id}
                  className="flex items-center gap-3 px-4 py-3"
                >
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm text-text">{text}</p>
                    <p className="text-[11px] text-text/45">
                      {formatRelativeTime(
                        String(entry.timestamp),
                        i18n.language,
                      )}
                    </p>
                  </div>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => copyEntry(entry)}
                    aria-label={t("home.history.copy")}
                    title={t("home.history.copy")}
                    className="size-8 !p-0 flex items-center justify-center shrink-0"
                  >
                    {copiedId === entry.id ? (
                      <Check className="size-4 text-menta" />
                    ) : (
                      <Copy className="size-4" />
                    )}
                  </Button>
                </div>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
};

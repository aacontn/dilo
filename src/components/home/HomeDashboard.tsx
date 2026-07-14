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
    <div className="home-dashboard w-full mx-auto space-y-6">
      <header className="dilo-page-header">
        <h1 className="font-display text-2xl font-semibold tracking-tight text-text">
          {t("sidebar.home")}
        </h1>
      </header>

      <section className="glass-surface home-status-surface overflow-hidden rounded-xl">
        <div className="home-status-primary p-5">
          <div className="flex items-center gap-2 text-success-text">
            <span className="size-2 rounded-full bg-menta" />
            <span className="text-xs font-semibold uppercase tracking-[0.14em]">
              {t("home.status.label")}
            </span>
          </div>
          <h2 className="mt-3 font-display text-2xl font-semibold text-text">
            {t("home.status.title")}
          </h2>
          <p className="mt-1 text-sm text-text/60">
            {t("home.status.description")}
          </p>
          <div className="mt-4">
            <ShortcutBadge binding={primaryShortcut} />
          </div>
          <div className="mt-5 flex items-center gap-2 text-xs text-muted-text">
            <LockKeyhole className="size-4 shrink-0" />
            {t("home.status.privacy")}
          </div>
        </div>

        <div className="home-status-meta">
          <div className="home-status-meta-item">
            <div className="flex items-center gap-2 text-muted-text">
              <Cpu className="size-4" />
              <span className="text-xs font-medium uppercase tracking-wide">
                {t("home.model.label")}
              </span>
            </div>
            <p className="mt-2 truncate font-semibold text-text">
              {activeModel?.name || t("home.model.loading")}
            </p>
            <p className="mt-0.5 text-xs text-muted-text">
              {activeModel?.supports_streaming
                ? t("home.model.streaming")
                : t("home.model.local")}
            </p>
          </div>

          <div className="home-status-meta-item">
            <div className="flex items-center gap-2 text-muted-text">
              {settings?.post_process_enabled ? (
                <Sparkles className="size-4" />
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
            <div className="mt-2">
              <ShortcutBadge binding={smartShortcut} />
            </div>
          </div>
        </div>
      </section>

      <DictationModes />

      <section className="home-history-section">
        <div className="mb-3 flex items-end justify-between">
          <div>
            <h2 className="font-semibold text-base text-text">
              {t("home.history.title")}
            </h2>
            <p className="text-xs text-muted-text">
              {t("home.history.subtitle")}
            </p>
          </div>
        </div>
        <div className="glass-surface rounded-xl overflow-hidden">
          {entries.length === 0 ? (
            <div className="px-4 py-6 text-center text-sm text-muted-text">
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
                    className="home-history-row flex items-center gap-3 px-4"
                  >
                    <p className="min-w-0 flex-1 truncate text-sm text-text">
                      {text}
                    </p>
                    <time className="shrink-0 text-xs text-muted-text">
                      {formatRelativeTime(
                        String(entry.timestamp),
                        i18n.language,
                      )}
                    </time>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => copyEntry(entry)}
                      aria-label={t("home.history.copy")}
                      title={t("home.history.copy")}
                      className="size-8 !p-0 flex items-center justify-center shrink-0"
                    >
                      {copiedId === entry.id ? (
                        <Check className="size-4 text-success-text" />
                      ) : (
                        <Copy className="size-4" />
                      )}
                    </Button>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </section>
    </div>
  );
};

import React, { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { ArrowUpRight, Settings2 } from "lucide-react";
import { commands, type MeetingSummary } from "@/bindings";
import { useMeetingStore } from "@/stores/meetingStore";
import {
  isPastMeeting,
  RECENT_MEETINGS_LIMIT,
} from "@/components/meeting/meetingFormat";

/**
 * Las cuatro zonas del popover (§2 del diseño). La primera queda vacía a
 * propósito: es donde el proyecto de detección de reuniones pondrá su aviso,
 * y dejarla declarada evita rediseñar el popover entero cuando llegue.
 */
export const PopoverBody: React.FC = () => {
  const { t } = useTranslation();
  const activeMeetingId = useMeetingStore((s) => s.activeMeetingId);
  const [recent, setRecent] = useState<MeetingSummary[]>([]);

  // Una fila de más: `list_meetings` incluye la que está grabando, y sin el
  // +1 el filtro dejaría sólo 3.
  useEffect(() => {
    void (async () => {
      const result = await commands.listMeetings(RECENT_MEETINGS_LIMIT + 1, 0);
      if (result.status === "ok") {
        setRecent(
          result.data.meetings
            .filter(isPastMeeting)
            .slice(0, RECENT_MEETINGS_LIMIT),
        );
      } else {
        toast.error(t("popover.loadFailed"), { description: result.error });
      }
    })();
  }, [activeMeetingId, t]);

  const open = async (which: "transcript" | "dilo") => {
    const result =
      which === "transcript"
        ? await commands.openMeetingsWindow()
        : await commands.returnToMainWindow();
    if (result.status === "error") {
      toast.error(t("popover.openFailed"), { description: result.error });
    }
  };

  return (
    <div className="flex h-full flex-col gap-3">
      {/* 1 · Ranura de avisos — vacía hasta que exista la detección. */}
      <div data-testid="popover-notice-slot" />

      {/* 2 · La sesión en curso. */}
      <section className="glass-surface rounded-xl p-3">
        <p className="text-sm text-muted-text">
          {activeMeetingId ? t("popover.recording") : t("popover.idle")}
        </p>
      </section>

      {/* 3 · Las últimas reuniones. */}
      <section className="flex-1 overflow-y-auto">
        <h2 className="mb-2 text-xs uppercase tracking-wide text-muted-text">
          {t("popover.recentTitle")}
        </h2>
        {recent.length === 0 ? (
          <p className="text-sm text-muted-text">{t("popover.recentEmpty")}</p>
        ) : (
          <ul className="flex flex-col gap-1">
            {recent.map((m) => (
              <li key={m.id} className="truncate text-sm">
                {m.title}
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* 4 · Las dos puertas. */}
      <footer className="flex gap-2">
        <button
          type="button"
          onClick={() => void open("transcript")}
          className="flex flex-1 items-center justify-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-muted-text transition-colors hover:bg-white/10 hover:text-text"
        >
          <ArrowUpRight className="size-4 shrink-0" />
          {t("popover.openTranscript")}
        </button>
        <button
          type="button"
          onClick={() => void open("dilo")}
          className="flex flex-1 items-center justify-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-muted-text transition-colors hover:bg-white/10 hover:text-text"
        >
          <Settings2 className="size-4 shrink-0" />
          {t("popover.openDilo")}
        </button>
      </footer>
    </div>
  );
};

import React, { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { ArrowUpRight, Settings2, Square } from "lucide-react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { commands, events, type MeetingSummary } from "@/bindings";
import { formatRelativeTime } from "@/utils/dateFormat";
import {
  formatDuration,
  isPastMeeting,
  RECENT_MEETINGS_LIMIT,
} from "@/components/meeting/meetingFormat";

/**
 * Las cuatro zonas del popover (§2 del diseño). La primera queda vacía a
 * propósito: es donde el proyecto de detección de reuniones pondrá su aviso,
 * y dejarla declarada evita rediseñar el popover entero cuando llegue.
 *
 * **Por qué este componente lee todo de `listMeetings` y no del
 * `meetingStore`.** El popover se esconde, nunca se destruye (`popover.rs`),
 * así que su webview monta una sola vez en toda la vida del proceso — y aun
 * si montara de nuevo, `useMeetingStore` es una instancia de Zustand propia
 * de *esta* ventana: `startMeeting` corre en el runtime de la ventana de
 * reuniones, así que `activeMeetingId` acá es `null` para siempre. La verdad
 * de qué hay grabando vive en el backend, no en un store de ventana, y
 * `list_meetings` ya la expone — la fila en curso viene con
 * `status === "recording"`, la misma que `isPastMeeting` filtra para el
 * listado de pasadas. Por eso este componente recarga el listado entero
 * (eventos de fin de sesión + foco de ventana) y deriva la sesión en curso
 * de ahí, en vez de leer un store que nunca se entera.
 */
export const PopoverBody: React.FC = () => {
  const { t, i18n } = useTranslation();
  // `null` = todavía no resolvió el primer fetch (M10): sin esto, "Todavía
  // no grabas ninguna" se pintaba antes de saber si es cierto.
  const [meetings, setMeetings] = useState<MeetingSummary[] | null>(null);
  const [starting, setStarting] = useState(false);
  const [stopping, setStopping] = useState(false);

  // Una fila de más: `list_meetings` incluye la que está grabando, y sin el
  // +1 el filtro de recientes dejaría sólo 3.
  const load = useCallback(async () => {
    try {
      const result = await commands.listMeetings(RECENT_MEETINGS_LIMIT + 1, 0);
      if (result.status === "ok") {
        setMeetings(result.data.meetings);
      } else {
        toast.error(t("popover.loadFailed"), { description: result.error });
      }
    } catch (error) {
      toast.error(t("popover.loadFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    }
  }, [t]);

  // Carga inicial.
  useEffect(() => {
    void load();
  }, [load]);

  // El popover no se destruye al esconderse (ver nota de arriba), así que el
  // fin de una sesión —en curso mientras estaba escondido, o iniciada en la
  // ventana de reuniones mientras tanto— sólo llega por evento.
  useEffect(() => {
    const unlistenFinished = events.meetingFinished.listen(() => void load());
    const unlistenInterrupted = events.meetingInterrupted.listen(() =>
      void load(),
    );
    return () => {
      void unlistenFinished.then((fn) => fn());
      void unlistenInterrupted.then((fn) => fn());
    };
  }, [load]);

  // El popover se muestra volviendo a tomar foco tras estar escondido — ese
  // es el momento de reabrir, así que es también el momento de refrescar. No
  // hay evento de "empezó a grabar" en el backend; este es el mecanismo por
  // el que una reunión iniciada en otra ventana aparece acá como en curso.
  useEffect(() => {
    const win = getCurrentWindow();
    const unlisten = win.onFocusChanged(({ payload: focused }) => {
      if (focused) void load();
    });
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, [load]);

  const recording = meetings?.find((m) => m.status === "recording") ?? null;
  const recent = meetings
    ? meetings.filter(isPastMeeting).slice(0, RECENT_MEETINGS_LIMIT)
    : [];

  const handleStart = async () => {
    setStarting(true);
    try {
      const result = await commands.startMeeting("presencial");
      if (result.status === "error") throw new Error(result.error);
      await load();
    } catch (error) {
      toast.error(t("meeting.controls.startFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setStarting(false);
    }
  };

  const handleStop = async (meetingId: number) => {
    setStopping(true);
    try {
      const result = await commands.stopMeeting(meetingId);
      if (result.status === "error") throw new Error(result.error);
      await load();
    } catch (error) {
      toast.error(t("meeting.controls.stopFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setStopping(false);
    }
  };

  // NOTA para quien revise el reporte de este arreglo: no existe un comando
  // para abrir la ventana de reuniones ya posicionada en una reunión
  // concreta (`open_meetings_window` no toma id). Un clic en una reciente
  // abre la ventana a secas, igual que las dos puertas del pie.
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

      {/* 2 · La sesión en curso: cronómetro y botón de detener, o el botón
          de empezar sin sesión (§2 del diseño). El transcript vivo queda
          fuera a propósito — el plan lo excluye explícitamente. */}
      <section className="glass-surface rounded-xl p-3">
        {recording ? (
          <div className="flex items-center justify-between gap-2">
            <div className="flex min-w-0 items-center gap-2">
              <span className="size-2 shrink-0 rounded-full bg-rojo dilo-meeting-pulse" />
              <span className="truncate text-sm text-text">
                {t("popover.recording")}
              </span>
              <Timer startedAt={recording.started_at} />
            </div>
            <button
              type="button"
              onClick={() => void handleStop(recording.id)}
              disabled={stopping}
              className="flex shrink-0 items-center gap-1 rounded-lg bg-rojo/15 px-2 py-1 text-xs font-medium text-danger-text transition-colors hover:bg-rojo/25 disabled:opacity-60"
            >
              <Square className="size-3" />
              {stopping
                ? t("meeting.controls.finishing")
                : t("meeting.controls.stop")}
            </button>
          </div>
        ) : (
          <div className="flex items-center justify-between gap-2">
            <p className="truncate text-sm text-muted-text">
              {t("popover.idle")}
            </p>
            <button
              type="button"
              onClick={() => void handleStart()}
              disabled={starting}
              className="flex shrink-0 items-center gap-1 rounded-lg bg-text/10 px-2 py-1 text-xs font-medium text-text transition-colors hover:bg-text/15 disabled:opacity-60"
            >
              {starting
                ? t("meeting.controls.starting")
                : t("meeting.controls.start")}
            </button>
          </div>
        )}
      </section>

      {/* 3 · Las últimas reuniones, con fecha y duración, clickeables. */}
      <section className="flex-1 overflow-y-auto">
        <h2 className="mb-2 text-xs uppercase tracking-wide text-muted-text">
          {t("popover.recentTitle")}
        </h2>
        {meetings === null ? (
          <p className="text-sm text-muted-text">{t("meeting.list.loading")}</p>
        ) : recent.length === 0 ? (
          <p className="text-sm text-muted-text">{t("popover.recentEmpty")}</p>
        ) : (
          <ul className="flex flex-col gap-0.5">
            {recent.map((m) => (
              <li key={m.id}>
                <button
                  type="button"
                  onClick={() => void open("transcript")}
                  className="flex w-full items-center gap-2 rounded-lg px-1.5 py-1.5 text-left transition-colors hover:bg-white/10"
                >
                  <span className="min-w-0 flex-1 truncate text-sm text-text">
                    {m.title}
                  </span>
                  <span className="shrink-0 text-xs text-muted-text">
                    {formatRelativeTime(String(m.started_at), i18n.language)}
                    {m.ended_at !== null &&
                      ` · ${formatDuration(m.ended_at - m.started_at)}`}
                  </span>
                </button>
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

/**
 * Cronómetro de la sesión en curso. `started_at` es un timestamp Unix en
 * segundos (mismo contrato que `formatRelativeTime`); el reloj corre en
 * cliente, comparado contra la hora local, así que no depende de que el
 * backend empuje nada mientras el popover está abierto.
 */
const Timer: React.FC<{ startedAt: number }> = ({ startedAt }) => {
  const [nowMs, setNowMs] = useState(() => Date.now());

  useEffect(() => {
    const id = setInterval(() => setNowMs(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  return (
    <span className="shrink-0 font-mono text-xs text-muted-text tabular-nums">
      {formatDuration(nowMs / 1000 - startedAt)}
    </span>
  );
};

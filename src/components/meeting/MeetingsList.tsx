import React, { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { AlertTriangle, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { commands, events, type MeetingSummary } from "@/bindings";
import { formatRelativeTime } from "@/utils/dateFormat";
import { Button } from "../ui/Button";
import { formatDuration } from "./meetingFormat";

const PAGE_SIZE = 10;

/**
 * Mientras hay una reunión grabando, esa fila vive en los controles de
 * arriba, no acá (decisión de producto) — el backend no filtra por estado
 * en `list_meetings`, así que lo hacemos en la UI. Sólo puede existir una
 * fila `recording` a la vez (el backend rechaza una segunda grabación con
 * `recording_busy`), así que filtrarla siempre saca como máximo el primer
 * ítem de la primera página.
 */
const isPastMeeting = (meeting: MeetingSummary): boolean =>
  meeting.status !== "recording";

interface StatusBadgeProps {
  status: string;
}

/**
 * `interrupted` (la app murió grabando, el transcript puede estar
 * incompleto) tiene que distinguirse a simple vista del resto — borde
 * punteado + ícono de alerta, igual criterio visual que el chip de hablante
 * sin identificar en `TranscriptList`. `ready` no lleva insignia: es el
 * estado esperado y no hace falta remarcarlo en cada fila.
 */
const StatusBadge: React.FC<StatusBadgeProps> = ({ status }) => {
  const { t } = useTranslation();

  if (status === "interrupted") {
    return (
      <span className="inline-flex shrink-0 items-center gap-1 rounded-full border border-dashed border-rojo/50 px-2 py-0.5 text-xs font-medium text-danger-text">
        <AlertTriangle className="size-3" />
        {t("meeting.list.status.interrupted")}
      </span>
    );
  }
  if (status === "processing") {
    return (
      <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-text/[0.08] px-2 py-0.5 text-xs font-medium text-muted-text">
        <Loader2 className="size-3 animate-spin" />
        {t("meeting.list.status.processing")}
      </span>
    );
  }
  // Defensivo: en teoría nunca llega filtrada, pero si algún día se muestra
  // que se lea como grabando y no como una reunión pasada más.
  if (status === "recording") {
    return (
      <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-rojo/15 px-2 py-0.5 text-xs font-medium text-danger-text">
        <span className="size-1.5 rounded-full bg-rojo dilo-meeting-pulse" />
        {t("meeting.list.status.recording")}
      </span>
    );
  }
  return null;
};

interface MeetingsListProps {
  onSelect: (meetingId: number) => void;
}

/**
 * Registro de reuniones pasadas (Historia 4): listado paginado que alimenta
 * el detalle. Paginación con botón "cargar más" a propósito — el spec pide
 * nada de scroll infinito, a diferencia de `HistorySettings`.
 */
export const MeetingsList: React.FC<MeetingsListProps> = ({ onSelect }) => {
  const { t, i18n } = useTranslation();
  const [entries, setEntries] = useState<MeetingSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  // Cuántas filas crudas (sin filtrar) ya se pidieron al backend — el
  // offset de la próxima página se calcula sobre esto, no sobre
  // `entries.length`, porque la fila `recording` filtrada corre el conteo.
  const [rawCount, setRawCount] = useState(0);
  const rawCountRef = useRef(0);

  useEffect(() => {
    rawCountRef.current = rawCount;
  }, [rawCount]);

  /** Reemplaza el listado desde el principio, pidiendo `count` filas. */
  const load = useCallback(
    async (count: number, showSpinner: boolean) => {
      if (showSpinner) setLoading(true);
      try {
        const result = await commands.listMeetings(count, 0);
        if (result.status === "ok") {
          setEntries(result.data.meetings.filter(isPastMeeting));
          setRawCount(result.data.meetings.length);
          setHasMore(result.data.has_more);
        } else {
          toast.error(t("meeting.list.loadFailed"), {
            description: result.error,
          });
        }
      } catch (error) {
        toast.error(t("meeting.list.loadFailed"), {
          description: error instanceof Error ? error.message : String(error),
        });
      } finally {
        if (showSpinner) setLoading(false);
      }
    },
    [t],
  );

  // Carga inicial.
  useEffect(() => {
    load(PAGE_SIZE, true);
  }, [load]);

  // Cuando termina (o se interrumpe) una grabación, la fila pasa a existir
  // en el backend — recargar para que aparezca sin tener que reabrir la
  // app (FR de la Historia 4).
  useEffect(() => {
    const reload = () => load(Math.max(rawCountRef.current, PAGE_SIZE), false);
    const unlistenFinished = events.meetingFinished.listen(reload);
    const unlistenInterrupted = events.meetingInterrupted.listen(reload);
    return () => {
      void unlistenFinished.then((fn) => fn());
      void unlistenInterrupted.then((fn) => fn());
    };
  }, [load]);

  const handleLoadMore = async () => {
    setLoadingMore(true);
    try {
      const result = await commands.listMeetings(PAGE_SIZE, rawCount);
      if (result.status === "ok") {
        setEntries((prev) => [
          ...prev,
          ...result.data.meetings.filter(isPastMeeting),
        ]);
        setRawCount((prev) => prev + result.data.meetings.length);
        setHasMore(result.data.has_more);
      } else {
        toast.error(t("meeting.list.loadFailed"), {
          description: result.error,
        });
      }
    } catch (error) {
      toast.error(t("meeting.list.loadFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setLoadingMore(false);
    }
  };

  return (
    <section>
      <div className="mb-3">
        <h2 className="font-semibold text-base text-text">
          {t("meeting.list.title")}
        </h2>
        <p className="text-xs text-muted-text">{t("meeting.list.subtitle")}</p>
      </div>

      <div className="glass-surface rounded-xl overflow-hidden">
        {loading ? (
          <div className="px-4 py-8 text-center text-sm text-muted-text">
            {t("meeting.list.loading")}
          </div>
        ) : entries.length === 0 ? (
          <div className="px-4 py-8 text-center text-sm text-muted-text">
            {t("meeting.list.empty")}
          </div>
        ) : (
          <div className="divide-y divide-mid-gray/15">
            {entries.map((meeting) => (
              <button
                key={meeting.id}
                type="button"
                onClick={() => onSelect(meeting.id)}
                className="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-text/[0.04] cursor-pointer"
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-text">
                    {meeting.title}
                  </p>
                  <p className="mt-0.5 text-xs text-muted-text">
                    {formatRelativeTime(
                      String(meeting.started_at),
                      i18n.language,
                    )}
                    {meeting.ended_at !== null &&
                      ` · ${formatDuration(meeting.ended_at - meeting.started_at)}`}
                  </p>
                </div>
                <StatusBadge status={meeting.status} />
              </button>
            ))}
          </div>
        )}
      </div>

      {!loading && hasMore && (
        <div className="mt-3 flex justify-center">
          <Button
            variant="secondary"
            size="sm"
            onClick={() => void handleLoadMore()}
            disabled={loadingMore}
          >
            {loadingMore
              ? t("meeting.list.loadingMore")
              : t("meeting.list.loadMore")}
          </Button>
        </div>
      )}
    </section>
  );
};

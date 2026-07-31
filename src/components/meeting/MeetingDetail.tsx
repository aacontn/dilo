import React, { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { ArrowLeft } from "lucide-react";
import { toast } from "sonner";
import { commands, type Meeting } from "@/bindings";
import { formatDateTime } from "@/utils/dateFormat";
import { Alert } from "../ui/Alert";
import { TranscriptList } from "./TranscriptList";
import { formatDuration } from "./meetingFormat";

interface MeetingDetailProps {
  meetingId: number;
  onBack: () => void;
}

/**
 * Detalle de una reunión guardada: sus datos y el transcript completo, en
 * los mismos chips que usa el transcript en vivo (`TranscriptList`).
 *
 * Si `getMeeting` falla, no deja la pantalla rota: avisa con un toast y
 * vuelve sola al listado (decisión de producto de la Historia 4) — la lista
 * sigue siendo utilizable aunque una reunión puntual no cargue.
 */
export const MeetingDetail: React.FC<MeetingDetailProps> = ({
  meetingId,
  onBack,
}) => {
  const { t, i18n } = useTranslation();
  const [meeting, setMeeting] = useState<Meeting | null>(null);

  useEffect(() => {
    let cancelled = false;
    setMeeting(null);

    commands
      .getMeeting(meetingId)
      .then((result) => {
        if (cancelled) return;
        if (result.status === "ok") {
          setMeeting(result.data);
        } else {
          toast.error(t("meeting.detail.loadFailed"), {
            description: result.error,
          });
          onBack();
        }
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        toast.error(t("meeting.detail.loadFailed"), {
          description: error instanceof Error ? error.message : String(error),
        });
        onBack();
      });

    return () => {
      cancelled = true;
    };
    // Sólo `meetingId` dispara una nueva carga — no hay linter de hooks en
    // este repo (ver eslint.config.js) que exija `onBack`/`t` en las deps.
  }, [meetingId]);

  // Nombres puestos por el usuario, por id de hablante — el backend ya
  // resolvió las fusiones (`get_meeting`), así que acá sólo queda filtrar
  // los que no tienen nombre.
  const speakerNames = useMemo(() => {
    const names: Record<number, string> = {};
    for (const speaker of meeting?.speakers ?? []) {
      if (speaker.display_name) names[speaker.id] = speaker.display_name;
    }
    return names;
  }, [meeting]);

  const backButton = (
    <button
      type="button"
      onClick={onBack}
      className="inline-flex items-center gap-1.5 text-sm text-muted-text transition-colors hover:text-text cursor-pointer"
    >
      <ArrowLeft className="size-4" />
      {t("meeting.detail.back")}
    </button>
  );

  if (meeting === null) {
    return (
      <section className="space-y-3">
        {backButton}
        <div className="glass-surface rounded-xl px-4 py-8 text-center text-sm text-muted-text">
          {t("meeting.detail.loading")}
        </div>
      </section>
    );
  }

  const duration =
    meeting.ended_at !== null
      ? formatDuration(meeting.ended_at - meeting.started_at)
      : null;

  return (
    <section className="space-y-3">
      {backButton}

      <div>
        <h2 className="font-display text-xl font-semibold text-text">
          {meeting.title}
        </h2>
        <p className="mt-1 text-xs text-muted-text">
          {formatDateTime(String(meeting.started_at), i18n.language)}
          {duration && ` · ${duration}`}
        </p>
      </div>

      {meeting.status === "interrupted" && (
        <Alert variant="warning">{t("meeting.detail.interruptedBanner")}</Alert>
      )}

      <div className="glass-surface max-h-[32rem] overflow-y-auto rounded-xl">
        {meeting.segments.length === 0 ? (
          <div className="px-4 py-8 text-center text-sm text-muted-text">
            {t("meeting.detail.emptyTranscript")}
          </div>
        ) : (
          <div className="divide-y divide-mid-gray/15">
            <TranscriptList
              segments={meeting.segments}
              speakerNames={speakerNames}
            />
          </div>
        )}
      </div>
    </section>
  );
};

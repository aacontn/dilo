import React, { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Merge, UserRoundPen } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import { Button } from "../ui/Button";
import { Input } from "../ui/Input";
import { Select } from "../ui/Select";
import { useMeetings } from "../../hooks/useMeetings";

/**
 * Nombres y fusión de hablantes (T019), la contraparte visible de FR-005.
 *
 * Los hablantes salen del propio transcript en vivo, no de un comando de
 * listado: `get_meeting` es T035 y hasta entonces los segmentos que ya
 * llegaron son la única fuente de verdad disponible en la ventana. La
 * consecuencia es honesta — sólo aparece quien ya habló, que es exactamente
 * a quien tiene sentido nombrar.
 */
export const SpeakerAssignment: React.FC = () => {
  const { t } = useTranslation();
  const { activeMeetingId, segments, speakerNames, setSpeakerName } =
    useMeetings();
  const [drafts, setDrafts] = useState<Record<number, string>>({});
  const [mergeSource, setMergeSource] = useState<string>("");
  const [mergeTarget, setMergeTarget] = useState<string>("");
  const [isMerging, setIsMerging] = useState(false);

  // Hablantes en orden de aparición, con cuántas intervenciones lleva cada
  // uno: ayuda a decidir cuál fusionar en cuál (el que más habló suele ser
  // el "principal").
  const speakers = useMemo(() => {
    const seen = new Map<number, number>();
    for (const segment of segments) {
      if (segment.speaker_id === null) continue;
      seen.set(segment.speaker_id, (seen.get(segment.speaker_id) ?? 0) + 1);
    }
    return Array.from(seen.entries()).map(([id, count], index) => ({
      id,
      count,
      order: index,
    }));
  }, [segments]);

  const labelFor = (id: number, order: number) =>
    speakerNames[id] ??
    t("meeting.transcript.speakerLabel", { number: order + 1 });

  const handleSaveName = async (speakerId: number) => {
    const value = drafts[speakerId] ?? speakerNames[speakerId] ?? "";
    const result = await commands.assignSpeakerName(speakerId, value);
    if (result.status === "error") {
      toast.error(t("meeting.speakers.nameFailed"), {
        description: result.error,
      });
      return;
    }
    setSpeakerName(speakerId, value);
    setDrafts((current) => {
      const next = { ...current };
      delete next[speakerId];
      return next;
    });
  };

  const handleMerge = async () => {
    if (activeMeetingId === null || mergeSource === "" || mergeTarget === "") {
      return;
    }
    setIsMerging(true);
    try {
      const result = await commands.mergeSpeakers(
        activeMeetingId,
        Number(mergeSource),
        Number(mergeTarget),
      );
      if (result.status === "error") {
        toast.error(t("meeting.speakers.mergeFailed"), {
          description: result.error,
        });
        return;
      }
      toast.success(t("meeting.speakers.mergeDone"));
      setMergeSource("");
      setMergeTarget("");
    } finally {
      setIsMerging(false);
    }
  };

  if (speakers.length === 0) {
    return null;
  }

  const speakerOptions = speakers.map(({ id, order }) => ({
    value: String(id),
    label: labelFor(id, order),
  }));

  return (
    <section>
      <div className="mb-3">
        <h2 className="font-semibold text-base text-text">
          {t("meeting.speakers.title")}
        </h2>
        <p className="text-xs text-muted-text">
          {t("meeting.speakers.subtitle")}
        </p>
      </div>

      <div className="glass-surface rounded-xl overflow-hidden">
        <div className="divide-y divide-mid-gray/15">
          {speakers.map(({ id, count, order }) => (
            <div key={id} className="flex items-center gap-3 px-4 py-3">
              <UserRoundPen className="size-4 shrink-0 text-muted-text" />
              <div className="min-w-0 flex-1">
                <Input
                  value={drafts[id] ?? speakerNames[id] ?? ""}
                  className="w-full"
                  placeholder={t("meeting.transcript.speakerLabel", {
                    number: order + 1,
                  })}
                  onChange={(event) =>
                    setDrafts((current) => ({
                      ...current,
                      [id]: event.target.value,
                    }))
                  }
                  onKeyDown={(event) => {
                    if (event.key === "Enter") void handleSaveName(id);
                  }}
                />
              </div>
              <span className="shrink-0 text-xs text-muted-text">
                {t("meeting.speakers.interventions", { count })}
              </span>
              <Button
                variant="secondary"
                size="sm"
                onClick={() => void handleSaveName(id)}
                disabled={drafts[id] === undefined}
              >
                {t("meeting.speakers.save")}
              </Button>
            </div>
          ))}
        </div>

        {speakers.length > 1 && (
          <div className="border-t border-mid-gray/15 px-4 py-3">
            <div className="flex items-center gap-2 text-muted-text">
              <Merge className="size-4" />
              <span className="text-xs font-medium uppercase tracking-wide">
                {t("meeting.speakers.mergeLabel")}
              </span>
            </div>
            <p className="mt-1 text-xs text-muted-text">
              {t("meeting.speakers.mergeHelp")}
            </p>
            <div className="mt-3 flex flex-wrap items-center gap-2">
              <Select
                value={mergeSource}
                onChange={(value) => setMergeSource(value ?? "")}
                options={speakerOptions}
                placeholder={t("meeting.speakers.mergeSource")}
                className="min-w-[10rem]"
              />
              <span className="text-xs text-muted-text">
                {t("meeting.speakers.mergeInto")}
              </span>
              <Select
                value={mergeTarget}
                onChange={(value) => setMergeTarget(value ?? "")}
                options={speakerOptions.filter(
                  (option) => option.value !== mergeSource,
                )}
                placeholder={t("meeting.speakers.mergeTarget")}
                className="min-w-[10rem]"
              />
              <Button
                variant="secondary"
                size="sm"
                onClick={() => void handleMerge()}
                disabled={
                  isMerging ||
                  mergeSource === "" ||
                  mergeTarget === "" ||
                  mergeSource === mergeTarget
                }
              >
                {t("meeting.speakers.mergeAction")}
              </Button>
            </div>
          </div>
        )}
      </div>
    </section>
  );
};

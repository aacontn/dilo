import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import {
  ArrowUpRight,
  Copy,
  Cpu,
  Loader2,
  LogOut,
  Mic,
  Settings2,
  Square,
  Video,
  Volume2,
  Wand2,
} from "lucide-react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  commands,
  events,
  type MeetingSegment,
  type MeetingSummary,
  type TrayIconState,
  type TtsVoiceInfo,
} from "@/bindings";
import { formatDuration } from "@/components/meeting/meetingFormat";
import { TranscriptList } from "@/components/meeting";
import { useModelStore } from "@/stores/modelStore";
import { useSettingsStore } from "@/stores/settingsStore";

/**
 * Rediseño 2026-08-03, según la especificación de Alfonso (ver el reporte en
 * `.superpowers/sdd/tarjeta-y-modelo-reunion-report.md`): **un solo clic**
 * (los dos botones abren esto — el menú nativo se va de macOS, ver
 * `popover.rs`/`tray.rs`), sin lista de reuniones recientes ("es una
 * tontera"), coherente con un menú de barra de macOS — ítems compactos,
 * separadores, sin botones grandes de formulario.
 *
 * **Dos estados, contenido excluyente, no acumulado:**
 * - Sin reunión grabando: versión, estado del dictado, copiar lo último,
 *   elegir modelo (dictado/reuniones/transformar/voz), la pastilla de
 *   grabar, las dos puertas (transcript/Dilo) y Salir al pie.
 * - Con una reunión grabando: eso desaparece entero y en su lugar sale un
 *   mini transcript en vivo — cronómetro, detener, y las últimas
 *   intervenciones con su hablante. El transcript completo sigue viviendo en
 *   la ventana de reuniones; acá es sólo un vistazo.
 *
 * **Por qué este componente lee todo de `listMeetings`/eventos y no del
 * `meetingStore`.** El popover se esconde, nunca se destruye (`popover.rs`),
 * así que su webview monta una sola vez en toda la vida del proceso — y aun
 * si montara de nuevo, `useMeetingStore` es una instancia de Zustand propia
 * de *esta* ventana: `startMeeting` corre en el runtime de la ventana de
 * reuniones, así que `activeMeetingId` acá sería `null` para siempre. La
 * verdad de qué hay grabando vive en el backend. `list_meetings(1, 0)`
 * alcanza para saberlo: si algo está grabando, es siempre la fila más
 * reciente — no se puede empezar una reunión nueva mientras otra sigue en
 * `recording` (el backend lo rechaza), así que ninguna fila puede haberse
 * insertado después de la que está grabando.
 *
 * Los eventos de Tauri (`meeting-segment`, etc.) sí llegan directo a esta
 * ventana como a cualquier otra — lo que no cruza ventanas es el *store*, no
 * el evento — así que el mini transcript se arma escuchándolos acá mismo,
 * sembrado con `get_meeting` cuando se detecta una sesión ya en curso (por
 * ejemplo, si se abrió después de que la reunión ya había empezado).
 */
export const PopoverBody: React.FC = () => {
  const { t } = useTranslation();

  const [recording, setRecording] = useState<MeetingSummary | null>(null);
  const [starting, setStarting] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [copying, setCopying] = useState(false);
  const [version, setVersion] = useState("");
  const [voices, setVoices] = useState<TtsVoiceInfo[]>([]);
  // `null` = todavía no resolvió el primer fetch — el estado real llega
  // enseguida por `getTrayIconState`, y de ahí en más por el evento.
  const [dictationState, setDictationState] = useState<TrayIconState | null>(
    null,
  );
  const [liveSegments, setLiveSegments] = useState<MeetingSegment[]>([]);
  const [speakerNames, setSpeakerNames] = useState<Record<number, string>>({});
  const bottomRef = useRef<HTMLDivElement>(null);

  const models = useModelStore((state) => state.models);
  const currentModel = useModelStore((state) => state.currentModel);
  const selectModel = useModelStore((state) => state.selectModel);
  const initializeModels = useModelStore((state) => state.initialize);

  const settings = useSettingsStore((state) => state.settings);
  const refreshSettings = useSettingsStore((state) => state.refreshSettings);
  const setPostProcessProvider = useSettingsStore(
    (state) => state.setPostProcessProvider,
  );
  const updateSetting = useSettingsStore((state) => state.updateSetting);

  // Si hay algo grabando, es siempre la fila más reciente — ver el doc
  // comment de arriba.
  const load = useCallback(async () => {
    try {
      const result = await commands.listMeetings(1, 0);
      if (result.status === "ok") {
        const [top] = result.data.meetings;
        setRecording(top?.status === "recording" ? top : null);
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
    void initializeModels();
    void refreshSettings();
    void commands.getAppVersion().then(setVersion);
    void commands.ttsListVoices().then(setVoices);
  }, [load, initializeModels, refreshSettings]);

  // El estado del dictado (reposo/grabando/transcribiendo) no vive en
  // ningún store de esta ventana — se pregunta al montar y de ahí en más se
  // sigue por el mismo evento que actualiza el ícono de la bandeja. No se
  // usan los eventos del overlay (`show-overlay`/`hide-overlay`) a propósito:
  // esos no se emiten si el usuario apagó el overlay del dictado
  // (`overlay_style: "none"`), y este indicador debe seguir funcionando
  // igual para quien lo desactivó.
  useEffect(() => {
    void commands.getTrayIconState().then(setDictationState);
    const unlisten = events.trayIconStateChanged.listen((event) => {
      setDictationState(event.payload.state);
    });
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, []);

  // El popover no se destruye al esconderse (ver nota de arriba), así que el
  // fin de una sesión —en curso mientras estaba escondido, o iniciada en la
  // ventana de reuniones mientras tanto— sólo llega por evento.
  useEffect(() => {
    const unlistenFinished = events.meetingFinished.listen(() => void load());
    const unlistenInterrupted = events.meetingInterrupted.listen(
      () => void load(),
    );
    return () => {
      void unlistenFinished.then((fn) => fn());
      void unlistenInterrupted.then((fn) => fn());
    };
  }, [load]);

  // El popover se muestra volviendo a tomar foco tras estar escondido — ese
  // es el momento de reabrir, así que es también el momento de refrescar
  // (incluidos los ajustes: pueden haber cambiado desde la ventana de Dilo
  // mientras el popover estaba escondido). No hay evento de "empezó a
  // grabar" en el backend; este es el mecanismo por el que una reunión
  // iniciada en otra ventana aparece acá como en curso.
  useEffect(() => {
    const win = getCurrentWindow();
    const unlisten = win.onFocusChanged(({ payload: focused }) => {
      if (focused) {
        void load();
        void refreshSettings();
      }
    });
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, [load, refreshSettings]);

  // Mini transcript en vivo: los segmentos llegan por el mismo evento que
  // alimenta la ventana de reuniones (`meeting-segment`) — los eventos de
  // Tauri llegan a cualquier ventana escuchando, a diferencia del store (ver
  // el doc comment del componente). Se escucha siempre, sin condicionar a
  // `recording`, para no perder el primer segmento por una carrera entre
  // "se detectó que hay una reunión" y "empezó a llegar transcript".
  useEffect(() => {
    const unlisten = events.meetingSegment.listen((event) => {
      setLiveSegments((prev) =>
        prev.some((existing) => existing.id === event.payload.id)
          ? prev
          : [...prev, event.payload],
      );
    });
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, []);

  // Siembra el transcript con lo que ya se dijo cuando se detecta una sesión
  // en curso (por ejemplo, el popover se abrió después de que la reunión ya
  // había empezado en otra ventana) y limpia todo cuando la sesión termina.
  const recordingId = recording?.id ?? null;
  useEffect(() => {
    if (recordingId === null) {
      setLiveSegments([]);
      setSpeakerNames({});
      return;
    }
    let cancelled = false;
    void commands.getMeeting(recordingId).then((result) => {
      if (cancelled || result.status !== "ok") return;
      setLiveSegments(result.data.segments);
      const names: Record<number, string> = {};
      for (const speaker of result.data.speakers) {
        if (speaker.display_name) names[speaker.id] = speaker.display_name;
      }
      setSpeakerNames(names);
    });
    return () => {
      cancelled = true;
    };
  }, [recordingId]);

  const miniSegments = useMemo(() => liveSegments.slice(-5), [liveSegments]);

  useEffect(() => {
    if (!recording) return;
    bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [miniSegments.length, recording]);

  // Sólo los modelos ya descargados, como en el submenú de la bandeja
  // (`update_tray_menu` en tray.rs) — no tiene sentido ofrecer acá un modelo
  // que primero habría que bajar.
  const downloadedModels = useMemo(
    () =>
      [...models]
        .filter((m) => m.is_downloaded)
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((m) => ({ id: m.id, name: m.name })),
    [models],
  );

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

  const handleCopyLast = async () => {
    setCopying(true);
    try {
      const result = await commands.copyLastTranscript();
      if (result.status === "error") {
        toast.error(t("popover.copyLastFailed"));
        return;
      }
      toast.success(t("popover.copyLastDone"));
    } catch (error) {
      toast.error(t("popover.copyLastFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setCopying(false);
    }
  };

  const handleSelectModel = async (modelId: string) => {
    if (modelId === "" || modelId === currentModel) return;
    const ok = await selectModel(modelId);
    if (!ok) {
      toast.error(t("popover.modelSwitchFailed"));
    }
  };

  // NOTA para quien revise el reporte de este arreglo: no existe un comando
  // para abrir la ventana de reuniones ya posicionada en una reunión
  // concreta (`open_meetings_window` no toma id). Un clic en "Abrir
  // transcript" abre la ventana a secas.
  const open = async (which: "transcript" | "dilo") => {
    const result =
      which === "transcript"
        ? await commands.openMeetingsWindow()
        : await commands.returnToMainWindow();
    if (result.status === "error") {
      toast.error(t("popover.openFailed"), { description: result.error });
    }
  };

  const dictationStatusLabel =
    dictationState === "recording"
      ? t("popover.status.recording")
      : dictationState === "transcribing"
        ? t("popover.status.transcribing")
        : t("popover.status.idle");

  if (recording) {
    return (
      <div className="flex h-full min-h-0 flex-col gap-3">
        <div className="glass-surface flex items-center justify-between gap-2 rounded-xl p-3">
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

        <div className="glass-surface min-h-0 flex-1 overflow-y-auto rounded-xl">
          {miniSegments.length === 0 ? (
            <div className="px-4 py-8 text-center text-sm text-muted-text">
              {t("meeting.transcript.listening")}
            </div>
          ) : (
            <div className="divide-y divide-mid-gray/15">
              <TranscriptList
                segments={miniSegments}
                speakerNames={speakerNames}
              />
              <div ref={bottomRef} />
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col gap-3">
      <div className="px-1 text-[11px] font-medium text-muted-text/80">
        {version}
      </div>

      <section className="glass-surface rounded-xl p-3">
        <div className="flex items-center gap-2">
          {dictationState === "transcribing" ? (
            <Loader2 className="size-3 shrink-0 animate-spin text-muted-text" />
          ) : (
            <span
              className={`size-2 shrink-0 rounded-full ${
                dictationState === "recording"
                  ? "bg-rojo dilo-meeting-pulse"
                  : "bg-menta"
              }`}
            />
          )}
          <span className="truncate text-sm text-text">
            {dictationStatusLabel}
          </span>
        </div>
      </section>

      <section className="glass-surface flex flex-col divide-y divide-mid-gray/15 rounded-xl">
        <div className="p-1.5">
          <button
            type="button"
            onClick={() => void handleCopyLast()}
            disabled={copying}
            className="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm text-text transition-colors hover:bg-white/10 disabled:opacity-60"
          >
            <Copy className="size-4 shrink-0 text-muted-text" />
            {t("tray.copyLastTranscript")}
          </button>
        </div>

        <div className="flex flex-col gap-0.5 p-1.5">
          <h3 className="px-2 pb-0.5 pt-0.5 text-[11px] uppercase tracking-wide text-muted-text">
            {t("sidebar.models")}
          </h3>
          <ModelSelectRow
            icon={<Cpu className="size-4" />}
            label={t("popover.models.dictation")}
            value={currentModel}
            onChange={(id) => void handleSelectModel(id)}
            options={downloadedModels}
          />
          <ModelSelectRow
            icon={<Video className="size-4" />}
            label={t("sidebar.meetings")}
            value={settings?.meeting_model_id ?? ""}
            onChange={(id) =>
              void updateSetting("meeting_model_id", id === "" ? null : id)
            }
            options={[
              { id: "", name: t("popover.models.inherit") },
              ...downloadedModels,
            ]}
          />
          <ModelSelectRow
            icon={<Wand2 className="size-4" />}
            label={t("sidebar.postProcessing")}
            value={settings?.post_process_provider_id ?? ""}
            onChange={(id) => void setPostProcessProvider(id)}
            options={(settings?.post_process_providers ?? []).map((p) => ({
              id: p.id,
              name: p.label,
            }))}
          />
          <ModelSelectRow
            icon={<Volume2 className="size-4" />}
            label={t("sidebar.voice")}
            value={settings?.tts_voice ?? ""}
            onChange={(id) => void updateSetting("tts_voice", id)}
            options={voices.map((v) => ({ id: v.id, name: v.name }))}
          />
        </div>
      </section>

      <button
        type="button"
        onClick={() => void handleStart()}
        disabled={starting}
        className="flex items-center justify-center gap-2 rounded-xl bg-logo-primary/15 px-3 py-2 text-sm font-medium text-text transition-colors hover:bg-logo-primary/25 disabled:opacity-60"
      >
        <Mic className="size-4 shrink-0" />
        {starting
          ? t("meeting.controls.starting")
          : t("meeting.controls.start")}
      </button>

      <div className="mt-auto flex flex-col gap-2">
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

        {/* Discreto y separado del resto: sin esto no queda ninguna vía
            para cerrar la app en macOS, ahora que el menú nativo del ícono
            de bandeja se fue (ver `tray.rs`). */}
        <button
          type="button"
          onClick={() => void commands.quitApp()}
          className="flex items-center justify-center gap-1.5 border-t border-mid-gray/15 pt-2 text-xs text-muted-text transition-colors hover:text-danger-text"
        >
          <LogOut className="size-3.5 shrink-0" />
          {t("tray.quit")}
        </button>
      </div>
    </div>
  );
};

interface ModelSelectRowProps {
  icon: React.ReactNode;
  label: string;
  value: string;
  onChange: (value: string) => void;
  options: { id: string; name: string }[];
}

/**
 * Una fila del selector de modelos: ícono + etiqueta corta + `<select>`
 * compacto, mismo tratamiento que ya usaba el único selector de modelo de
 * dictado. Si `value` no está entre `options` (un modelo sin descargar aún,
 * o borrado desde entonces) se antepone una opción fantasma deshabilitada
 * en vez de forzar la selección a otra cosa — mismo criterio que el
 * submenú de modelo de la bandeja.
 */
const ModelSelectRow: React.FC<ModelSelectRowProps> = ({
  icon,
  label,
  value,
  onChange,
  options,
}) => {
  const hasValue = options.some((option) => option.id === value);
  return (
    <label className="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-text">
      <span className="flex size-4 shrink-0 items-center justify-center text-muted-text">
        {icon}
      </span>
      <span className="w-[4.5rem] shrink-0 truncate text-xs text-muted-text">
        {label}
      </span>
      <select
        aria-label={label}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="w-full min-w-0 flex-1 truncate bg-transparent text-sm text-text outline-none"
      >
        {!hasValue && (
          <option value={value} disabled>
            {value || label}
          </option>
        )}
        {options.map((option) => (
          <option key={option.id} value={option.id}>
            {option.name}
          </option>
        ))}
      </select>
    </label>
  );
};

/**
 * Cronómetro de la sesión en curso. `started_at` es un timestamp Unix en
 * segundos; el reloj corre en cliente, comparado contra la hora local, así
 * que no depende de que el backend empuje nada mientras el popover está
 * abierto.
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

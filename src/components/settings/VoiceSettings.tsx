import React, { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { PlayIcon } from "lucide-react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { commands, type TtsVoiceInfo, type TtsWeightsStatus } from "@/bindings";
import { PageHeader } from "../ui/PageHeader";
import { SettingContainer, SettingsGroup, ToggleSwitch } from "../ui";
import { Dialog } from "../ui/Dialog";
import { Dropdown, type DropdownOption } from "../ui/Dropdown";
import { Button } from "../ui/Button";
import { ShortcutInput } from "./ShortcutInput";
import { useSettings } from "../../hooks/useSettings";

/** Frase de prueba corta con puntuación variada — ejercita la segmentación
 * por streaming (ver `tts::streaming::split_segments`), no solo la síntesis. */
const SAMPLE_PHRASE = "Hola, soy Dilo. ¿Cómo te puedo ayudar hoy?";

/**
 * Sección "Voz": elegir una de las 10 voces de Supertonic y escucharla con
 * una frase de prueba. Motor único por ahora (ver `TtsEngineSetting`), así
 * que no hay selector de motor — solo de voz.
 */
export const VoiceSettings: React.FC = () => {
  const { t } = useTranslation();
  const { settings, updateSetting, isUpdating } = useSettings();

  const [voices, setVoices] = useState<TtsVoiceInfo[]>([]);
  const [weights, setWeights] = useState<TtsWeightsStatus | null>(null);
  const [isDownloading, setIsDownloading] = useState(false);
  const [isTesting, setIsTesting] = useState(false);
  // Diálogo de licencia: los pesos son OpenRAIL-M, así que antes de
  // descargar se muestra la copia REAL del LICENSE (misma revisión pineada
  // que los pesos, vía `ttsLicenseText`) y recién ahí se puede aceptar.
  const [licenseOpen, setLicenseOpen] = useState(false);
  const [licenseText, setLicenseText] = useState<string | null>(null);
  const [licenseFailed, setLicenseFailed] = useState(false);

  const refreshWeightsStatus = useCallback(async () => {
    try {
      const result = await commands.ttsWeightsStatus();
      if (result.status === "ok") {
        setWeights(result.data);
      } else {
        console.error("Failed to read TTS weights status:", result.error);
      }
    } catch (error) {
      console.error("Failed to read TTS weights status:", error);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const list = await commands.ttsListVoices();
        if (!cancelled) setVoices(list);
      } catch (error) {
        console.error("Failed to list TTS voices:", error);
      }
    })();
    void refreshWeightsStatus();
    return () => {
      cancelled = true;
    };
  }, [refreshWeightsStatus]);

  const selectedVoice = settings?.tts_voice ?? "F5";
  const voicesReady = weights?.downloaded ?? false;

  const voiceOptions: DropdownOption[] = voices.map((voice) => ({
    value: voice.id,
    label: `${voice.name} · ${
      voice.gender === "female"
        ? t("settings.voice.female")
        : t("settings.voice.male")
    }`,
  }));

  const handleSelectVoice = (value: string) => {
    void updateSetting("tts_voice", value);
  };

  const handleTest = useCallback(async () => {
    setIsTesting(true);
    try {
      const result = await commands.ttsSpeak(SAMPLE_PHRASE, selectedVoice);
      if (result.status === "error") {
        throw new Error(result.error);
      }
    } catch (error) {
      console.error("Failed to test TTS voice:", error);
      toast.error(t("settings.voice.testError"));
    } finally {
      setIsTesting(false);
    }
  }, [selectedVoice, t]);

  const fetchLicense = useCallback(async () => {
    setLicenseFailed(false);
    try {
      const result = await commands.ttsLicenseText();
      if (result.status === "error") {
        throw new Error(result.error);
      }
      setLicenseText(result.data);
    } catch (error) {
      console.error("Failed to fetch TTS license text:", error);
      setLicenseFailed(true);
    }
  }, []);

  const handleOpenLicense = useCallback(() => {
    setLicenseOpen(true);
    if (licenseText === null) void fetchLicense();
  }, [licenseText, fetchLicense]);

  // Solo alcanzable desde el diálogo con la licencia a la vista — por eso
  // el `true`: acá el usuario ya la leyó y apretó aceptar.
  const handleAcceptAndDownload = useCallback(async () => {
    setLicenseOpen(false);
    setIsDownloading(true);
    try {
      const result = await commands.ttsDownloadWeights(true);
      if (result.status === "error") {
        throw new Error(result.error);
      }
      await refreshWeightsStatus();
    } catch (error) {
      console.error("Failed to download TTS weights:", error);
      toast.error(t("settings.voice.downloadError"));
    } finally {
      setIsDownloading(false);
    }
  }, [refreshWeightsStatus, t]);

  return (
    <div className="settings-page max-w-3xl w-full mx-auto space-y-6">
      <PageHeader
        title={t("settings.voice.title")}
        description={t("settings.voice.description")}
      />

      {!voicesReady && weights && (
        <SettingsGroup title={t("settings.voice.setupTitle")}>
          <SettingContainer
            title={t("settings.voice.downloadTitle")}
            description={t("settings.voice.downloadHint", {
              url: weights.license_url,
            })}
            descriptionMode="inline"
            layout="horizontal"
            grouped
          >
            <Button
              onClick={handleOpenLicense}
              variant="secondary"
              size="md"
              disabled={isDownloading}
            >
              {isDownloading
                ? t("settings.voice.downloading")
                : t("settings.voice.download")}
            </Button>
          </SettingContainer>
        </SettingsGroup>
      )}

      <Dialog
        open={licenseOpen}
        onOpenChange={setLicenseOpen}
        title={t("settings.voice.license.title")}
        description={t("settings.voice.license.intro")}
        closeLabel={t("settings.voice.license.cancel")}
        contentClassName="space-y-3"
        footer={
          <div className="flex w-full items-center justify-between gap-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => weights && openUrl(weights.license_url)}
            >
              {t("settings.voice.license.openInBrowser")}
            </Button>
            <Button
              variant="secondary"
              size="md"
              onClick={handleAcceptAndDownload}
              disabled={licenseText === null}
            >
              {t("settings.voice.license.accept")}
            </Button>
          </div>
        }
      >
        <p className="rounded-md bg-mid-gray/10 px-3 py-2 text-sm text-text">
          {t("settings.voice.license.whatYouDownload")}
        </p>
        {licenseText !== null ? (
          <pre className="max-h-72 overflow-y-auto whitespace-pre-wrap rounded-md bg-mid-gray/10 p-3 text-xs leading-relaxed text-text">
            {licenseText}
          </pre>
        ) : licenseFailed ? (
          <div className="space-y-2 text-sm text-muted-text">
            <p>{t("settings.voice.license.fetchError")}</p>
            <Button variant="ghost" size="sm" onClick={() => fetchLicense()}>
              {t("settings.voice.license.retry")}
            </Button>
          </div>
        ) : (
          <p className="text-sm text-muted-text">
            {t("settings.voice.license.loading")}
          </p>
        )}
      </Dialog>

      <SettingsGroup title={t("settings.voice.selectorTitle")}>
        <SettingContainer
          title={t("settings.voice.selectorTitle")}
          description={t("settings.voice.selectorHint")}
          descriptionMode="tooltip"
          layout="horizontal"
          grouped
          disabled={!voicesReady}
        >
          <div className="flex items-center gap-2">
            <Dropdown
              options={voiceOptions}
              selectedValue={selectedVoice}
              onSelect={handleSelectVoice}
              disabled={
                !voicesReady || isUpdating("tts_voice") || voices.length === 0
              }
              placeholder={t("settings.voice.selectorPlaceholder")}
            />
            <Button
              variant="secondary"
              size="md"
              onClick={handleTest}
              disabled={!voicesReady || isTesting}
              title={t("settings.voice.test")}
            >
              <PlayIcon className="mr-1.5 h-4 w-4" />
              {isTesting
                ? t("settings.voice.testing")
                : t("settings.voice.test")}
            </Button>
          </div>
        </SettingContainer>
      </SettingsGroup>

      <SettingsGroup
        title={t("settings.voice.assistantMode.title")}
        description={t("settings.voice.assistantMode.description")}
      >
        <ToggleSwitch
          checked={settings?.voice_assistant_enabled ?? false}
          onChange={(enabled) =>
            updateSetting("voice_assistant_enabled", enabled)
          }
          isUpdating={isUpdating("voice_assistant_enabled")}
          label={t("settings.voice.assistantMode.toggleLabel")}
          description={t("settings.voice.assistantMode.toggleDescription")}
          descriptionMode="tooltip"
          grouped
        />
        <ShortcutInput
          shortcutId="voice_assistant"
          descriptionMode="tooltip"
          grouped
          disabled={!(settings?.voice_assistant_enabled ?? false)}
        />
      </SettingsGroup>
    </div>
  );
};

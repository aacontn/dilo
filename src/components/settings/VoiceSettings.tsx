import React, { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { PlayIcon } from "lucide-react";
import { commands, type TtsVoiceInfo, type TtsWeightsStatus } from "@/bindings";
import { PageHeader } from "../ui/PageHeader";
import { SettingContainer, SettingsGroup, ToggleSwitch } from "../ui";
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

  const handleDownload = useCallback(async () => {
    setIsDownloading(true);
    try {
      const result = await commands.ttsDownloadWeights();
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
              onClick={handleDownload}
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

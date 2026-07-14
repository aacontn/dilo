import React from "react";
import { useTranslation } from "react-i18next";
import { WordCorrectionThreshold } from "./WordCorrectionThreshold";
import { LogLevelSelector } from "./LogLevelSelector";
import { LiveLogViewer } from "./LiveLogViewer";
import { PasteDelay } from "./PasteDelay";
import { RecordingBuffer } from "./RecordingBuffer";
import { SettingsGroup } from "../../ui/SettingsGroup";
import { AlwaysOnMicrophone } from "../AlwaysOnMicrophone";
import { SoundPicker } from "../SoundPicker";
import { ClamshellMicrophoneSelector } from "../ClamshellMicrophoneSelector";
import { UpdateChecksToggle } from "../UpdateChecksToggle";
import { WhatsNewPreview } from "./WhatsNewPreview";
import { PageHeader } from "../../ui/PageHeader";

export const DebugSettings: React.FC = () => {
  const { t } = useTranslation();

  return (
    <div className="settings-page max-w-3xl w-full mx-auto space-y-6">
      <PageHeader title={t("settings.debug.title")} />
      <SettingsGroup>
        <LogLevelSelector grouped={true} />
        <WhatsNewPreview descriptionMode="tooltip" grouped={true} />
        <UpdateChecksToggle descriptionMode="tooltip" grouped={true} />
        <SoundPicker
          label={t("settings.debug.soundTheme.label")}
          description={t("settings.debug.soundTheme.description")}
        />
        <WordCorrectionThreshold descriptionMode="tooltip" grouped={true} />
        <PasteDelay descriptionMode="tooltip" grouped={true} />
        <PasteDelay
          descriptionMode="tooltip"
          grouped={true}
          settingKey="paste_delay_after_ms"
          labelKey="settings.debug.pasteDelayAfter.title"
          descriptionKey="settings.debug.pasteDelayAfter.description"
        />
        <RecordingBuffer descriptionMode="tooltip" grouped={true} />
        <AlwaysOnMicrophone descriptionMode="tooltip" grouped={true} />
        <ClamshellMicrophoneSelector descriptionMode="tooltip" grouped={true} />
        <LiveLogViewer descriptionMode="tooltip" grouped={true} />
      </SettingsGroup>
    </div>
  );
};

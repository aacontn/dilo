import React, { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { open } from "@tauri-apps/plugin-dialog";
import { commands } from "@/bindings";
import { SettingContainer, SettingsGroup, ToggleSwitch } from "@/components/ui";
import { PageHeader } from "../ui/PageHeader";
import { Button } from "../ui/Button";
import { Input } from "../ui/Input";
import { ResetButton } from "../ui/ResetButton";
import { ShortcutInput } from "./ShortcutInput";
import { ApiKeyField } from "./PostProcessingSettingsApi/ApiKeyField";
import { useSettings } from "../../hooks/useSettings";
import { useOsType } from "../../hooks/useOsType";

/**
 * Sección "Notas": atajo de nota rápida, carpeta local, destinos de
 * sincronización (Notas de Apple / Notion) y cola de pendientes.
 */
export const NotesSettings: React.FC = () => {
  const { t } = useTranslation();
  const { settings, updateSetting, isUpdating, refreshSettings } =
    useSettings();
  const osType = useOsType();
  const isMacOS = osType === "macos";

  const [pendingCount, setPendingCount] = useState(0);
  const [isTesting, setIsTesting] = useState(false);
  const [isRetrying, setIsRetrying] = useState(false);

  const refreshPending = useCallback(async () => {
    try {
      const count = await commands.pendingNotesCount();
      setPendingCount(count);
    } catch (error) {
      console.error("Failed to read pending notes count:", error);
    }
  }, []);

  useEffect(() => {
    void refreshPending();
  }, [refreshPending]);

  const notesFolder = settings?.notes_folder ?? null;
  const appleEnabled = settings?.notes_apple_enabled ?? false;
  const appleFolder = settings?.notes_apple_folder ?? "";
  const notionEnabled = settings?.notes_notion_enabled ?? false;
  const notionParent = settings?.notes_notion_parent ?? "";
  const notionToken = settings?.notes_secrets?.notion ?? "";

  const handlePickFolder = useCallback(async () => {
    try {
      const selected = await open({ directory: true });
      if (typeof selected === "string") {
        await updateSetting("notes_folder", selected);
      }
    } catch (error) {
      console.error("Failed to pick notes folder:", error);
    }
  }, [updateSetting]);

  const handleResetFolder = useCallback(() => {
    void updateSetting("notes_folder", null);
  }, [updateSetting]);

  const handleAppleFolderChange = useCallback(
    (value: string) => {
      void updateSetting("notes_apple_folder", value.trim());
    },
    [updateSetting],
  );

  const [isSavingToken, setIsSavingToken] = useState(false);

  // Mismo patrón que la API key de post-proceso: comando dedicado + refresh
  // para que el input refleje el valor persistido (SecretMap del backend).
  const handleNotionTokenChange = useCallback(
    async (value: string) => {
      const trimmed = value.trim();
      if (trimmed === notionToken) return;
      setIsSavingToken(true);
      try {
        const result = await commands.changeNotesNotionToken(trimmed);
        if (result.status === "error") {
          throw new Error(result.error);
        }
        await refreshSettings();
      } catch (error) {
        console.error("Failed to save Notion token:", error);
        toast.error(t("settings.notes.notionTokenSaveError"));
      } finally {
        setIsSavingToken(false);
      }
    },
    [notionToken, refreshSettings, t],
  );

  const handleNotionParentChange = useCallback(
    (value: string) => {
      void updateSetting("notes_notion_parent", value.trim());
    },
    [updateSetting],
  );

  const handleTestNotion = useCallback(async () => {
    setIsTesting(true);
    try {
      const result = await commands.testNotionConnection();
      if (result.status === "ok") {
        toast.success(t("settings.notes.notionTestOk"));
      } else {
        toast.error(t("settings.notes.notionTestError"));
      }
    } catch (error) {
      console.error("Failed to test Notion connection:", error);
      toast.error(t("settings.notes.notionTestError"));
    } finally {
      setIsTesting(false);
    }
  }, [t]);

  const handleRetry = useCallback(async () => {
    setIsRetrying(true);
    try {
      const result = await commands.flushPendingNotes();
      if (result.status === "ok") {
        setPendingCount(result.data);
      } else {
        toast.error(t("settings.notes.retryError"));
        await refreshPending();
      }
    } catch (error) {
      console.error("Failed to flush pending notes:", error);
      toast.error(t("settings.notes.retryError"));
    } finally {
      setIsRetrying(false);
    }
  }, [refreshPending, t]);

  return (
    <div className="settings-page max-w-3xl w-full mx-auto space-y-6">
      <PageHeader title={t("settings.notes.title")} />

      <SettingsGroup
        title={t("settings.notes.shortcut")}
        description={t("settings.notes.shortcutHint")}
      >
        <ShortcutInput
          shortcutId="quick_note"
          descriptionMode="tooltip"
          grouped={true}
        />
      </SettingsGroup>

      <SettingsGroup title={t("settings.notes.folder")}>
        <SettingContainer
          title={t("settings.notes.folder")}
          description={t("settings.notes.folderHint")}
          descriptionMode="tooltip"
          layout="horizontal"
          grouped={true}
        >
          <div className="flex items-center gap-2">
            <span
              className="text-sm text-muted-text max-w-[280px] truncate"
              title={notesFolder ?? t("settings.notes.folderDefault")}
            >
              {notesFolder ?? t("settings.notes.folderDefault")}
            </span>
            <Button
              onClick={handlePickFolder}
              variant="secondary"
              size="md"
              className="shrink-0"
            >
              {t("settings.notes.folderPick")}
            </Button>
            {notesFolder !== null && (
              <ResetButton
                onClick={handleResetFolder}
                ariaLabel={t("settings.notes.folderReset")}
                className="flex h-9 w-9 items-center justify-center shrink-0"
              />
            )}
          </div>
        </SettingContainer>
      </SettingsGroup>

      <SettingsGroup title={t("settings.notes.sync")}>
        {isMacOS && (
          <>
            <ToggleSwitch
              label={t("settings.notes.apple")}
              description={t("settings.notes.appleHint")}
              checked={appleEnabled}
              onChange={(checked) =>
                updateSetting("notes_apple_enabled", checked)
              }
              isUpdating={isUpdating("notes_apple_enabled")}
              grouped={true}
            />
            {appleEnabled && (
              <SettingContainer
                title={t("settings.notes.appleFolder")}
                description={t("settings.notes.appleFolderHint")}
                descriptionMode="tooltip"
                layout="horizontal"
                grouped={true}
              >
                <ApiKeyFolderInput
                  value={appleFolder}
                  onBlur={handleAppleFolderChange}
                  placeholder={t("settings.notes.appleFolderPlaceholder")}
                />
              </SettingContainer>
            )}
          </>
        )}

        <ToggleSwitch
          label={t("settings.notes.notion")}
          description={t("settings.notes.notionHint")}
          checked={notionEnabled}
          onChange={(checked) => updateSetting("notes_notion_enabled", checked)}
          isUpdating={isUpdating("notes_notion_enabled")}
          grouped={true}
        />
        {notionEnabled && (
          <>
            <SettingContainer
              title={t("settings.notes.notionToken")}
              description={t("settings.notes.notionTokenHint")}
              descriptionMode="tooltip"
              layout="horizontal"
              grouped={true}
            >
              <div className="flex items-center gap-2">
                <ApiKeyField
                  value={notionToken}
                  onBlur={handleNotionTokenChange}
                  placeholder={t("settings.notes.notionTokenPlaceholder")}
                  disabled={isSavingToken}
                  className="min-w-[280px]"
                />
              </div>
            </SettingContainer>

            <SettingContainer
              title={t("settings.notes.notionParent")}
              description={t("settings.notes.notionParentHint")}
              descriptionMode="tooltip"
              layout="horizontal"
              grouped={true}
            >
              <ApiKeyFolderInput
                value={notionParent}
                onBlur={handleNotionParentChange}
                placeholder={t("settings.notes.notionParentPlaceholder")}
              />
            </SettingContainer>

            <SettingContainer
              title={t("settings.notes.notionTest")}
              description={t("settings.notes.notionTestHint")}
              descriptionMode="tooltip"
              layout="horizontal"
              grouped={true}
            >
              <Button
                onClick={handleTestNotion}
                variant="secondary"
                size="md"
                disabled={isTesting}
              >
                {t("settings.notes.notionTest")}
              </Button>
            </SettingContainer>
          </>
        )}
      </SettingsGroup>

      {pendingCount > 0 && (
        <SettingsGroup title={t("settings.notes.pendingTitle")}>
          <SettingContainer
            title={t("settings.notes.pending", { count: pendingCount })}
            description={t("settings.notes.pendingHint")}
            descriptionMode="tooltip"
            layout="horizontal"
            grouped={true}
          >
            <Button
              onClick={handleRetry}
              variant="secondary"
              size="md"
              disabled={isRetrying}
            >
              {t("settings.notes.retry")}
            </Button>
          </SettingContainer>
        </SettingsGroup>
      )}
    </div>
  );
};

/**
 * Input de texto con estado local que solo persiste al perder el foco.
 * Mismo patrón que `ApiKeyField` pero como texto plano visible.
 */
const ApiKeyFolderInput: React.FC<{
  value: string;
  onBlur: (value: string) => void;
  placeholder?: string;
}> = ({ value, onBlur, placeholder }) => {
  const [localValue, setLocalValue] = useState(value);

  useEffect(() => {
    setLocalValue(value);
  }, [value]);

  return (
    <Input
      type="text"
      value={localValue}
      onChange={(event) => setLocalValue(event.target.value)}
      onBlur={() => onBlur(localValue)}
      placeholder={placeholder}
      variant="compact"
      className="flex-1 min-w-[280px]"
    />
  );
};

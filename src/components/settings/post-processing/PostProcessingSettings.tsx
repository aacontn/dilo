import React, { useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import {
  ArrowLeft,
  ChevronRight,
  Code2,
  Mail,
  MessageCircle,
  Quote,
  RefreshCcw,
  Sparkles,
} from "lucide-react";
import { commands, type LLMPrompt } from "@/bindings";

import { Alert } from "../../ui/Alert";
import { SettingContainer, SettingsGroup, Textarea } from "@/components/ui";
import { Button } from "../../ui/Button";
import { ResetButton } from "../../ui/ResetButton";
import { Input } from "../../ui/Input";

import { ProviderSelect } from "../PostProcessingSettingsApi/ProviderSelect";
import { BaseUrlField } from "../PostProcessingSettingsApi/BaseUrlField";
import { ApiKeyField } from "../PostProcessingSettingsApi/ApiKeyField";
import { ModelSelect } from "../PostProcessingSettingsApi/ModelSelect";
import { usePostProcessProviderState } from "../PostProcessingSettingsApi/usePostProcessProviderState";
import { ModeShortcutInput } from "../ModeShortcutInput";
import { ModeProviderSelect } from "./ModeProviderSelect";
import { useSettings } from "../../../hooks/useSettings";
import { PageHeader } from "../../ui/PageHeader";
import {
  isModeDraftDirty,
  resolveModeProviderBadge,
  resolveModesView,
  type ModeProviderBadge,
  type ModesTabView,
} from "@/lib/postProcessPresets";

// Mismo mapeo que `DictationModes.tsx` (dashboard de Inicio): los modos de
// fábrica llevan un ícono fijo por id, cualquier modo propio del usuario cae
// en el genérico. Se duplica acá a propósito en vez de importarlo — es una
// tabla de presentación de tres líneas, no lógica que valga la pena acoplar
// entre dos pantallas que no comparten ningún otro estado.
const MODE_ICONS: Record<
  string,
  React.ComponentType<{ className?: string }>
> = {
  "dilo-clean": Sparkles,
  "dilo-prompt": Quote,
  "dilo-message": MessageCircle,
  "dilo-email": Mail,
  "dilo-code": Code2,
};

const PostProcessingSettingsApiComponent: React.FC = () => {
  const { t } = useTranslation();
  const state = usePostProcessProviderState();

  return (
    <>
      <SettingContainer
        title={t("settings.postProcessing.api.provider.title")}
        description={t("settings.postProcessing.api.provider.description")}
        descriptionMode="tooltip"
        layout="horizontal"
        grouped={true}
      >
        <div className="flex items-center gap-2">
          <ProviderSelect
            options={state.providerOptions}
            value={state.selectedProviderId}
            onChange={state.handleProviderSelect}
          />
        </div>
      </SettingContainer>

      {state.isAppleProvider ? (
        state.appleIntelligenceUnavailable ? (
          <Alert variant="error" contained>
            {t("settings.postProcessing.api.appleIntelligence.unavailable")}
          </Alert>
        ) : null
      ) : (
        <>
          {state.selectedProvider?.id === "custom" && (
            <SettingContainer
              title={t("settings.postProcessing.api.baseUrl.title")}
              description={t("settings.postProcessing.api.baseUrl.description")}
              descriptionMode="tooltip"
              layout="horizontal"
              grouped={true}
            >
              <div className="flex items-center gap-2">
                <BaseUrlField
                  value={state.baseUrl}
                  onBlur={state.handleBaseUrlChange}
                  placeholder={t(
                    "settings.postProcessing.api.baseUrl.placeholder",
                  )}
                  disabled={state.isBaseUrlUpdating}
                  className="min-w-[380px]"
                />
              </div>
            </SettingContainer>
          )}

          <SettingContainer
            title={t("settings.postProcessing.api.apiKey.title")}
            description={t("settings.postProcessing.api.apiKey.description")}
            descriptionMode="tooltip"
            layout="horizontal"
            grouped={true}
          >
            <div className="flex items-center gap-2">
              <ApiKeyField
                value={state.apiKey}
                onBlur={state.handleApiKeyChange}
                placeholder={t(
                  "settings.postProcessing.api.apiKey.placeholder",
                )}
                disabled={state.isApiKeyUpdating}
                className="min-w-[320px]"
              />
            </div>
          </SettingContainer>
        </>
      )}

      {!state.isAppleProvider && (
        <SettingContainer
          title={t("settings.postProcessing.api.model.title")}
          description={
            state.isCustomProvider
              ? t("settings.postProcessing.api.model.descriptionCustom")
              : t("settings.postProcessing.api.model.descriptionDefault")
          }
          descriptionMode="tooltip"
          layout="stacked"
          grouped={true}
        >
          <div className="flex items-center gap-2">
            <ModelSelect
              value={state.model}
              options={state.modelOptions}
              disabled={state.isModelUpdating}
              isLoading={state.isFetchingModels}
              placeholder={
                state.modelOptions.length > 0
                  ? t(
                      "settings.postProcessing.api.model.placeholderWithOptions",
                    )
                  : t("settings.postProcessing.api.model.placeholderNoOptions")
              }
              onSelect={state.handleModelSelect}
              onCreate={state.handleModelCreate}
              onBlur={() => {}}
              className="flex-1 min-w-[380px]"
            />
            <ResetButton
              onClick={state.handleRefreshModels}
              disabled={state.isFetchingModels}
              ariaLabel={t("settings.postProcessing.api.model.refreshModels")}
              className="flex h-10 w-10 items-center justify-center"
            >
              <RefreshCcw
                className={`h-4 w-4 ${state.isFetchingModels ? "animate-spin" : ""}`}
              />
            </ResetButton>
          </div>
        </SettingContainer>
      )}
    </>
  );
};

const PostProcessingSettingsApi = React.memo(
  PostProcessingSettingsApiComponent,
);
PostProcessingSettingsApi.displayName = "PostProcessingSettingsApi";

interface ModeRowProps {
  prompt: LLMPrompt;
  badge: ModeProviderBadge;
  onSelect: () => void;
}

/**
 * Fila clickeable de la lista de modos. Es un `div role="button"`, no un
 * `<button>`, a propósito: adentro va un `ModeShortcutInput` compacto que ya
 * es interactivo (botón de captura + botón de limpiar atajo), y anidar
 * `<button>` dentro de `<button>` es HTML inválido. El mismo patrón
 * (`role="button"` + `tabIndex` + `onKeyDown`) ya se usa en
 * `ModelDropdown.tsx` para filas de lista clickeables.
 */
const ModeRow: React.FC<ModeRowProps> = ({ prompt, badge, onSelect }) => {
  const { t } = useTranslation();
  const Icon = MODE_ICONS[prompt.id] ?? Sparkles;

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onSelect();
        }
      }}
      className="flex w-full items-center gap-3 px-4 py-3 text-start transition-colors hover:bg-text/[0.03] cursor-pointer focus:outline-none focus-visible:bg-text/[0.05]"
    >
      <Icon className="size-4 shrink-0 text-muted-text" />
      <span className="min-w-0 flex-1 truncate text-sm font-medium text-text">
        {prompt.name}
      </span>
      {badge && (
        <span className="shrink-0 rounded-full bg-text/[0.06] px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-muted-text">
          {badge === "local"
            ? t("settings.postProcessing.modeProvider.badgeLocal")
            : t("settings.postProcessing.modeProvider.badgeOnline")}
        </span>
      )}
      <ModeShortcutInput
        compact
        promptId={prompt.id}
        shortcut={prompt.shortcut}
      />
      <ChevronRight className="size-4 shrink-0 text-muted-text" />
    </div>
  );
};

const PostProcessingSettingsModesComponent: React.FC = () => {
  const { t } = useTranslation();
  const { settings, getSetting, refreshSettings } = useSettings();
  const [view, setView] = useState<ModesTabView>({ kind: "list" });
  const [draftName, setDraftName] = useState("");
  const [draftText, setDraftText] = useState("");

  const prompts = getSetting("post_process_prompts") || [];
  // Si el modo que la vista pedía ya no existe (por ejemplo se borró desde
  // otra pestaña), cae al listado en vez de un formulario de detalle roto.
  const effectiveView = resolveModesView(view, prompts);
  const selectedPrompt =
    effectiveView.kind === "detail"
      ? (prompts.find((prompt) => prompt.id === effectiveView.promptId) ?? null)
      : null;

  useEffect(() => {
    if (effectiveView.kind === "create") return;

    if (selectedPrompt) {
      setDraftName(selectedPrompt.name);
      setDraftText(selectedPrompt.prompt);
    } else {
      setDraftName("");
      setDraftText("");
    }
  }, [
    effectiveView.kind,
    selectedPrompt?.id,
    selectedPrompt?.name,
    selectedPrompt?.prompt,
  ]);

  const handleBack = () => setView({ kind: "list" });

  const handleStartCreate = () => {
    setDraftName("");
    setDraftText("");
    setView({ kind: "create" });
  };

  const handleCreatePrompt = async () => {
    if (!draftName.trim() || !draftText.trim()) return;

    try {
      const result = await commands.addPostProcessPrompt(
        draftName.trim(),
        draftText.trim(),
      );
      if (result.status === "ok") {
        await refreshSettings();
        setView({ kind: "detail", promptId: result.data.id });
      }
    } catch (error) {
      console.error("Failed to create prompt:", error);
    }
  };

  const handleUpdatePrompt = async () => {
    if (!selectedPrompt || !draftName.trim() || !draftText.trim()) return;

    try {
      await commands.updatePostProcessPrompt(
        selectedPrompt.id,
        draftName.trim(),
        draftText.trim(),
      );
      await refreshSettings();
    } catch (error) {
      console.error("Failed to update prompt:", error);
    }
  };

  const handleDeletePrompt = async () => {
    if (!selectedPrompt) return;

    try {
      await commands.deletePostProcessPrompt(selectedPrompt.id);
      await refreshSettings();
      setView({ kind: "list" });
    } catch (error) {
      console.error("Failed to delete prompt:", error);
    }
  };

  const isDirty = isModeDraftDirty(
    { name: draftName, text: draftText },
    selectedPrompt,
  );

  const backButton = (
    <button
      type="button"
      onClick={handleBack}
      className="inline-flex items-center gap-1.5 text-sm text-muted-text transition-colors hover:text-text cursor-pointer"
    >
      <ArrowLeft className="size-4" />
      {t("settings.postProcessing.modes.back")}
    </button>
  );

  if (effectiveView.kind === "list") {
    return (
      <div className="space-y-3">
        <div className="flex justify-end">
          <Button onClick={handleStartCreate} variant="primary" size="md">
            {t("settings.postProcessing.prompts.createNew")}
          </Button>
        </div>
        <SettingsGroup>
          {prompts.length === 0 ? (
            <div className="px-4 py-8 text-center text-sm text-muted-text">
              {t("settings.postProcessing.prompts.createFirst")}
            </div>
          ) : (
            prompts.map((prompt) => (
              <ModeRow
                key={prompt.id}
                prompt={prompt}
                badge={resolveModeProviderBadge(prompt, settings ?? {})}
                onSelect={() =>
                  setView({ kind: "detail", promptId: prompt.id })
                }
              />
            ))
          )}
        </SettingsGroup>
      </div>
    );
  }

  if (effectiveView.kind === "create") {
    return (
      <div className="space-y-3">
        {backButton}
        <SettingsGroup>
          <div className="space-y-3 p-4">
            <div className="flex flex-col space-y-2">
              <label className="text-sm font-semibold text-text">
                {t("settings.postProcessing.prompts.promptLabel")}
              </label>
              <Input
                type="text"
                value={draftName}
                onChange={(e) => setDraftName(e.target.value)}
                placeholder={t(
                  "settings.postProcessing.prompts.promptLabelPlaceholder",
                )}
                variant="compact"
              />
            </div>

            <div className="space-y-2 flex flex-col">
              <label className="text-sm font-semibold">
                {t("settings.postProcessing.prompts.promptInstructions")}
              </label>
              <Textarea
                variant="prompt"
                value={draftText}
                onChange={(e) => setDraftText(e.target.value)}
                placeholder={t(
                  "settings.postProcessing.prompts.promptInstructionsPlaceholder",
                )}
              />
              <p className="text-xs text-muted-text">
                <Trans
                  i18nKey="settings.postProcessing.prompts.promptTip"
                  components={{ code: <code /> }}
                />
              </p>
            </div>

            <div className="flex gap-2 pt-2">
              <Button
                onClick={handleCreatePrompt}
                variant="primary"
                size="md"
                disabled={!draftName.trim() || !draftText.trim()}
              >
                {t("settings.postProcessing.prompts.createPrompt")}
              </Button>
              <Button onClick={handleBack} variant="secondary" size="md">
                {t("settings.postProcessing.prompts.cancel")}
              </Button>
            </div>
          </div>
        </SettingsGroup>
      </div>
    );
  }

  // `effectiveView.kind === "detail"`: `resolveModesView` ya garantiza que
  // `selectedPrompt` existe acá (si no, habría caído a "list" arriba).
  if (!selectedPrompt) return null;

  return (
    <div className="space-y-3">
      {backButton}
      <SettingsGroup>
        <div className="space-y-3 p-4">
          <div className="flex flex-col space-y-2">
            <label className="text-sm font-semibold text-text">
              {t("settings.postProcessing.prompts.promptLabel")}
            </label>
            <Input
              type="text"
              value={draftName}
              onChange={(e) => setDraftName(e.target.value)}
              placeholder={t(
                "settings.postProcessing.prompts.promptLabelPlaceholder",
              )}
              variant="compact"
            />
          </div>

          <div className="space-y-2 flex flex-col">
            <label className="text-sm font-semibold">
              {t("settings.postProcessing.prompts.promptInstructions")}
            </label>
            <Textarea
              variant="prompt"
              value={draftText}
              onChange={(e) => setDraftText(e.target.value)}
              placeholder={t(
                "settings.postProcessing.prompts.promptInstructionsPlaceholder",
              )}
            />
            <p className="text-xs text-muted-text">
              <Trans
                i18nKey="settings.postProcessing.prompts.promptTip"
                components={{ code: <code /> }}
              />
            </p>
          </div>

          <ModeShortcutInput
            promptId={selectedPrompt.id}
            shortcut={selectedPrompt.shortcut}
          />

          {/* `key` fuerza un remount al cambiar de modo seleccionado: el
              segmentado guarda su lado (General/Local/Online) en estado
              local derivado del `providerId` inicial, y sin esto quedaría
              pegado al lado del modo anterior. */}
          <ModeProviderSelect
            key={selectedPrompt.id}
            promptId={selectedPrompt.id}
            providerId={selectedPrompt.provider_id}
            model={selectedPrompt.model}
          />

          <div className="flex gap-2 pt-2">
            <Button
              onClick={handleUpdatePrompt}
              variant="primary"
              size="md"
              disabled={!draftName.trim() || !draftText.trim() || !isDirty}
            >
              {t("settings.postProcessing.prompts.updatePrompt")}
            </Button>
            <Button
              onClick={handleDeletePrompt}
              variant="secondary"
              size="md"
              disabled={prompts.length <= 1}
            >
              {t("settings.postProcessing.prompts.deletePrompt")}
            </Button>
          </div>
        </div>
      </SettingsGroup>
    </div>
  );
};

const PostProcessingSettingsModes = React.memo(
  PostProcessingSettingsModesComponent,
);
PostProcessingSettingsModes.displayName = "PostProcessingSettingsModes";

type PostProcessingTab = "modes" | "provider";

export const PostProcessingSettings: React.FC = () => {
  const { t } = useTranslation();
  const [activeTab, setActiveTab] = useState<PostProcessingTab>("modes");

  return (
    <div className="settings-page max-w-3xl w-full mx-auto space-y-6">
      <PageHeader title={t("sidebar.postProcessing")} />

      <div className="flex gap-1 rounded-lg bg-text/[0.04] p-1 w-fit">
        {(["modes", "provider"] as const).map((tab) => (
          <button
            key={tab}
            type="button"
            onClick={() => setActiveTab(tab)}
            className={`rounded-md px-4 py-1.5 text-sm font-medium transition-colors cursor-pointer ${
              activeTab === tab
                ? "bg-logo-primary/20 text-text"
                : "text-muted-text hover:text-text"
            }`}
          >
            {t(`settings.postProcessing.tabs.${tab}`)}
          </button>
        ))}
      </div>

      {activeTab === "modes" ? (
        <PostProcessingSettingsModes />
      ) : (
        <SettingsGroup title={t("settings.postProcessing.api.title")}>
          <PostProcessingSettingsApi />
        </SettingsGroup>
      )}
    </div>
  );
};

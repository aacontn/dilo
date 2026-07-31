import React, { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Cloud, Laptop } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import { Dropdown } from "../../ui/Dropdown";
import { useSettings } from "../../../hooks/useSettings";

type Scope = "general" | "local" | "online";

interface ModeProviderSelectProps {
  promptId: string;
  // `LLMPrompt.provider_id`/`model` son campos opcionales del binding
  // (`string | null | undefined`), igual que `shortcut` en
  // `ModeShortcutInput`: se tipan así en vez de `string | null` para que
  // calcen con el dato real que entrega `selectedPrompt`.
  providerId: string | null | undefined;
  model: string | null | undefined;
}

export const ModeProviderSelect: React.FC<ModeProviderSelectProps> = ({
  promptId,
  providerId,
  model,
}) => {
  const { t } = useTranslation();
  const { settings, refreshSettings } = useSettings();
  const providers = settings?.post_process_providers ?? [];

  // `undefined` (campo ausente) y `null` (explícitamente "sin proveedor
  // propio") son el mismo estado para este bloque: el modo hereda del
  // proveedor global. Normalizarlo acá evita repetir el `?? null` en cada uso.
  const normalizedProviderId = providerId ?? null;

  const current = providers.find((p) => p.id === normalizedProviderId) ?? null;
  const [scope, setScope] = useState<Scope>(
    normalizedProviderId === null
      ? "general"
      : current?.is_local
        ? "local"
        : "online",
  );

  const globalProvider = providers.find(
    (p) => p.id === settings?.post_process_provider_id,
  );

  const options = useMemo(
    () =>
      providers
        .filter((p) => (scope === "local" ? p.is_local : !p.is_local))
        .map((p) => ({ value: p.id, label: p.label })),
    [providers, scope],
  );

  const save = async (
    nextProviderId: string | null,
    nextModel: string | null,
  ) => {
    const result = await commands.setPostProcessPromptProvider(
      promptId,
      nextProviderId,
      nextModel,
    );
    if (result.status === "error") {
      toast.error(t("settings.postProcessing.modeProvider.saveFailed"), {
        description: result.error,
      });
      return;
    }
    await refreshSettings();
  };

  const handleScope = async (next: Scope) => {
    setScope(next);
    if (next === "general") {
      await save(null, null);
      return;
    }
    // Al cambiar de lado, se preselecciona el primero de ese lado para que el
    // bloque nunca quede en un estado a medias (elegido "Local" pero sin
    // proveedor).
    const first = providers.find((p) =>
      next === "local" ? p.is_local : !p.is_local,
    );
    if (first) await save(first.id, null);
  };

  return (
    <div className="space-y-2">
      <label className="text-sm font-semibold">
        {t("settings.postProcessing.modeProvider.label")}
      </label>

      <div className="flex gap-1 rounded-lg bg-text/[0.04] p-1 w-fit">
        {(["general", "local", "online"] as const).map((option) => (
          <button
            key={option}
            type="button"
            onClick={() => void handleScope(option)}
            className={`rounded-md px-3 py-1 text-xs font-medium transition-colors cursor-pointer ${
              scope === option
                ? "bg-logo-primary/20 text-text"
                : "text-muted-text hover:text-text"
            }`}
          >
            {t(`settings.postProcessing.modeProvider.scope.${option}`)}
          </button>
        ))}
      </div>

      {scope === "general" ? (
        <p className="text-xs text-muted-text">
          {t("settings.postProcessing.modeProvider.inherits", {
            provider: globalProvider?.label ?? "—",
          })}
        </p>
      ) : (
        <div className="space-y-2">
          <Dropdown
            options={options}
            selectedValue={normalizedProviderId ?? ""}
            onSelect={(value) => void save(value, null)}
          />
          <p className="inline-flex items-center gap-1.5 text-xs text-muted-text">
            {scope === "local" ? (
              <Laptop className="size-3.5" />
            ) : (
              <Cloud className="size-3.5" />
            )}
            {t(`settings.postProcessing.modeProvider.hint.${scope}`)}
          </p>
          {model && (
            <p className="text-xs text-muted-text">
              {t("settings.postProcessing.modeProvider.model", { model })}
            </p>
          )}
          {/* Aviso, no bloqueo: el modo queda configurado igual y el usuario
              decide cuándo ir a poner la clave. Apple Intelligence no lleva
              clave, así que se excluye del chequeo. */}
          {normalizedProviderId !== null &&
            normalizedProviderId !== "apple_intelligence" &&
            !(
              settings?.post_process_api_keys?.[normalizedProviderId] ?? ""
            ).trim() && (
              <p className="text-xs text-warning-text">
                {t("settings.postProcessing.modeProvider.missingKey")}
              </p>
            )}
        </div>
      )}
    </div>
  );
};

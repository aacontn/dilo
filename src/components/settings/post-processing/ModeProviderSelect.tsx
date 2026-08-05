import React, { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Cloud, Laptop } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import { Dropdown } from "../../ui/Dropdown";
import { useSettings } from "../../../hooks/useSettings";
import { APPLE_PROVIDER_ID } from "../PostProcessingSettingsApi/usePostProcessProviderState";
import { pickProviderForScope } from "@/lib/postProcessPresets";

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
  // `current === null` cubre dos casos que el backend trata igual (`own` en
  // `resolve_mode_provider`): sin proveedor propio, o apuntando a uno que ya
  // no está en el catálogo (por ejemplo `apple_intelligence` en una máquina
  // que no es Mac ARM). En ambos el modo hereda el general, así que el
  // segmentado tiene que arrancar en "General" y no en "Online".
  const [scope, setScope] = useState<Scope>(
    current === null ? "general" : current.is_local ? "local" : "online",
  );
  // Lado que el usuario intentó activar pero no tenía ningún proveedor
  // (ver `handleScope`). Sólo sirve para mostrar el aviso; no es el `scope`
  // visible, que nunca se mueve hacia un lado vacío.
  const [emptyScopeAttempt, setEmptyScopeAttempt] = useState<Scope | null>(
    null,
  );

  const globalProvider = providers.find(
    (p) => p.id === settings?.post_process_provider_id,
  );

  // El modelo por modo (`LLMPrompt.model`) todavía no se elige desde esta UI
  // (no hay flujo de listar modelos por proveedor). Mientras tanto, mostrar
  // el modelo efectivo con el que en realidad va a correr el modo: el propio
  // si lo tiene, si no el heredado del proveedor elegido. Cadena vacía cuenta
  // como "no tiene".
  const effectiveModel =
    model?.trim() ||
    (normalizedProviderId
      ? settings?.post_process_models?.[normalizedProviderId]?.trim()
      : undefined) ||
    null;

  const options = useMemo(
    () =>
      providers
        .filter((p) => (scope === "local" ? p.is_local : !p.is_local))
        .map((p) => ({ value: p.id, label: p.label })),
    [providers, scope],
  );

  // Devuelve si el guardado fue exitoso: quien llama decide qué hacer con el
  // estado visual (segmentado) según el resultado, en vez de asumir éxito.
  const save = async (
    nextProviderId: string | null,
    nextModel: string | null,
  ): Promise<boolean> => {
    const result = await commands.setPostProcessPromptProvider(
      promptId,
      nextProviderId,
      nextModel,
    );
    if (result.status === "error") {
      toast.error(t("settings.postProcessing.modeProvider.saveFailed"), {
        description: result.error,
      });
      return false;
    }
    // Un guardado exitoso por cualquier vía (segmentado o dropdown) resuelve
    // el aviso de "lado vacío" si estaba mostrándose.
    setEmptyScopeAttempt(null);
    await refreshSettings();
    return true;
  };

  const handleScope = async (next: Scope) => {
    if (next === "general") {
      const saved = await save(null, null);
      // El segmentado sólo se mueve si el guardado se confirmó: si falla,
      // debe seguir mostrando el lado que realmente quedó persistido.
      if (saved) setScope(next);
      return;
    }
    // Al cambiar de lado se preselecciona un proveedor de ese lado para que
    // el bloque nunca quede en un estado a medias (elegido "Local" pero sin
    // proveedor). Cuál, lo decide `pickProviderForScope`: el general si es de
    // ese lado, si no el primero con clave — nunca a ciegas el primero del
    // catálogo, que era lo que hacía aparecer "falta la clave" con la clave
    // puesta. Si ese lado no tiene ningún proveedor (p. ej. Local en una
    // máquina sin Apple Intelligence y con Custom apuntando a un servidor
    // remoto), no hay nada que preseleccionar: no movemos el segmentado,
    // porque hacerlo sin guardar dejaría al usuario creyendo que activó ese
    // lado cuando el modo sigue enrutando al proveedor anterior.
    const first = pickProviderForScope(providers, next, {
      post_process_provider_id: settings?.post_process_provider_id,
      post_process_api_keys: settings?.post_process_api_keys ?? undefined,
    });
    if (!first) {
      setEmptyScopeAttempt(next);
      return;
    }
    const saved = await save(first.id, null);
    if (saved) setScope(next);
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

      {emptyScopeAttempt && (
        <p className="text-xs text-warning-text">
          {t("settings.postProcessing.modeProvider.emptySide", {
            scope: t(
              `settings.postProcessing.modeProvider.scope.${emptyScopeAttempt}`,
            ),
          })}
        </p>
      )}

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
          {effectiveModel && (
            <p className="text-xs text-muted-text">
              {t("settings.postProcessing.modeProvider.model", {
                model: effectiveModel,
              })}
            </p>
          )}
          {/* Aviso, no bloqueo: el modo queda configurado igual y el usuario
              decide cuándo ir a poner la clave. Apple Intelligence no lleva
              clave, así que se excluye del chequeo. */}
          {normalizedProviderId !== null &&
            normalizedProviderId !== APPLE_PROVIDER_ID &&
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

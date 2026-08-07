import {
  Code2,
  Info,
  Mail,
  MessageCircle,
  Quote,
  Settings2,
  Sparkles,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  buildDictationModeEntries,
  buildGeneralShortcutReminderEntries,
} from "@/lib/postProcessPresets";
import { useSettings } from "@/hooks/useSettings";
import { useOsType } from "@/hooks/useOsType";
import { formatKeyCombination } from "@/lib/utils/keyboard";

const ICONS = {
  "dilo-clean": Sparkles,
  "dilo-prompt": Quote,
  "dilo-message": MessageCircle,
  "dilo-email": Mail,
  "dilo-code": Code2,
} as const;

interface DictationModesProps {
  onCustomize: () => void;
}

/**
 * Lectura de un atajo, no edición: para cambiarlo se va a Transformar (los
 * modos) o a Ajustes generales (dictar/cancelar). Antes esta misma tarjeta
 * traía un capturador de tecla interactivo — se retiró junto con "Modo
 * inteligente activo" para que Inicio deje de ser una segunda pantalla de
 * edición.
 */
const ShortcutReminder = ({ shortcut }: { shortcut: string | null }) => {
  const { t } = useTranslation();
  const osType = useOsType();
  if (!shortcut) {
    return (
      <span className="text-xs text-muted-text">
        {t("home.shortcuts.unassigned")}
      </span>
    );
  }
  return (
    <kbd className="dilo-keycap font-mono text-xs rounded-md px-2 py-1 text-text whitespace-nowrap">
      {formatKeyCombination(shortcut, osType)}
    </kbd>
  );
};

export const DictationModes = ({ onCustomize }: DictationModesProps) => {
  const { t } = useTranslation();
  const { settings } = useSettings();
  if (!settings) return null;

  const providerId = settings.post_process_provider_id || "openai";
  const providerModel = settings.post_process_models?.[providerId]?.trim();
  const providerApiKey = settings.post_process_api_keys?.[providerId]?.trim();
  const providerReady =
    Boolean(providerModel) &&
    (providerId === "apple_intelligence" ||
      providerId === "custom" ||
      Boolean(providerApiKey));
  const prompts = settings.post_process_prompts || [];

  // Todo lo que decide qué se lista, en qué orden y qué atajo le
  // corresponde a cada fila vive en `postProcessPresets.ts` (funciones
  // puras, cubiertas en `postProcessPresets.test.ts`) — este componente
  // sólo llama y mapea el resultado.
  const generalShortcuts = buildGeneralShortcutReminderEntries(
    settings.bindings,
  );
  const modeEntries = buildDictationModeEntries(prompts, settings);

  return (
    <section className="dictation-modes-section">
      <div className="mb-3 flex items-end justify-between gap-3">
        <div>
          <h2 className="font-semibold text-base text-text">
            {t("home.shortcuts.title")}
          </h2>
          <p className="text-xs text-muted-text">{t("home.modes.subtitle")}</p>
        </div>
        <button
          type="button"
          onClick={onCustomize}
          className="dictation-modes-customize flex shrink-0 items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium text-text"
        >
          <Settings2 className="size-4" />
          {t("home.modes.customize")}
        </button>
      </div>

      <ul className="dictation-modes-general mb-3 flex flex-wrap gap-2">
        {generalShortcuts.map((entry) => (
          <li
            key={entry.id}
            className="glass-surface flex items-center gap-2 rounded-lg px-3 py-1.5"
          >
            <span className="text-xs font-medium text-text">
              {t(`settings.general.shortcut.bindings.${entry.id}.name`)}
            </span>
            <ShortcutReminder shortcut={entry.shortcut} />
          </li>
        ))}
      </ul>

      <div className="dictation-modes-grid grid gap-3">
        {modeEntries.map((entry) => {
          const Icon = ICONS[entry.id as keyof typeof ICONS] || Sparkles;
          const label = entry.isPreset
            ? t(entry.labelKey ?? "")
            : (entry.name ?? "");
          const description = entry.isPreset
            ? t(entry.descriptionKey ?? "")
            : (entry.description ?? "");
          const providerBadge =
            entry.badge === "local"
              ? t("settings.postProcessing.modeProvider.badgeLocal")
              : entry.badge === "online"
                ? t("settings.postProcessing.modeProvider.badgeOnline")
                : null;
          return (
            <div
              key={entry.id}
              className="glass-surface dictation-mode-card flex flex-col rounded-xl"
            >
              <div className="dictation-mode-card-main flex flex-1 flex-col gap-1 p-3 text-start">
                <span className="flex items-center gap-2">
                  <Icon className="size-4 shrink-0 text-muted-text" />
                  <span className="min-w-0 flex-1 truncate text-sm font-medium text-text">
                    {label}
                  </span>
                  {providerBadge && (
                    <span className="ml-2 rounded-full bg-text/[0.06] px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-muted-text">
                      {providerBadge}
                    </span>
                  )}
                </span>
                <span className="dictation-mode-card-desc text-xs text-muted-text">
                  {description}
                </span>
              </div>
              <div className="dictation-mode-card-footer flex items-center px-3 py-2">
                <ShortcutReminder shortcut={entry.shortcut} />
              </div>
            </div>
          );
        })}
      </div>
      {!providerReady && (
        <div className="mt-3 flex items-center gap-2 px-0.5 text-xs text-muted-text">
          <Info className="size-4 shrink-0" />
          {t("home.modes.needsProvider")}
        </div>
      )}
    </section>
  );
};

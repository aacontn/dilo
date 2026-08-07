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
  buildDictationModeRows,
  buildGeneralShortcutRows,
} from "@/lib/postProcessPresets";
import { useSettings } from "@/hooks/useSettings";
import { useOsType } from "@/hooks/useOsType";

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
 * edición. El texto ya viene resuelto (`shortcutText`/`hasShortcut`) desde
 * `postProcessPresets.ts` — este componente sólo elige qué etiqueta usar.
 */
const ShortcutReminder = ({
  shortcutText,
  hasShortcut,
}: {
  shortcutText: string;
  hasShortcut: boolean;
}) => {
  if (!hasShortcut) {
    return <span className="text-xs text-muted-text">{shortcutText}</span>;
  }
  return (
    <kbd className="dilo-keycap font-mono text-xs rounded-md px-2 py-1 text-text whitespace-nowrap">
      {shortcutText}
    </kbd>
  );
};

export const DictationModes = ({ onCustomize }: DictationModesProps) => {
  const { t } = useTranslation();
  const osType = useOsType();
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

  // Todo lo que decide qué se lista, en qué orden, y el texto ya traducido
  // de cada fila (etiqueta, descripción, tecla o "Sin tecla", insignia)
  // vive en `postProcessPresets.ts` (funciones puras, cubiertas en
  // `postProcessPresets.test.ts`). Acá sólo se pasan las props crudas
  // (`settings.bindings`, `prompts`, `settings`, `t`, `osType`) tal cual,
  // sin componer nada — el componente sólo mapea el resultado a JSX.
  const generalRows = buildGeneralShortcutRows(settings.bindings, osType, t);
  const modeRows = buildDictationModeRows(prompts, settings, osType, t);

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
        {generalRows.map((row) => (
          <li
            key={row.id}
            className="glass-surface flex items-center gap-2 rounded-lg px-3 py-1.5"
          >
            <span className="text-xs font-medium text-text">{row.label}</span>
            <ShortcutReminder
              shortcutText={row.shortcutText}
              hasShortcut={row.hasShortcut}
            />
          </li>
        ))}
      </ul>

      <div className="dictation-modes-grid grid gap-3">
        {modeRows.map((row) => {
          const Icon = ICONS[row.id as keyof typeof ICONS] || Sparkles;
          return (
            <div
              key={row.id}
              className="glass-surface dictation-mode-card flex flex-col rounded-xl"
            >
              <div className="dictation-mode-card-main flex flex-1 flex-col gap-1 p-3 text-start">
                <span className="flex items-center gap-2">
                  <Icon className="size-4 shrink-0 text-muted-text" />
                  <span className="min-w-0 flex-1 truncate text-sm font-medium text-text">
                    {row.label}
                  </span>
                  {row.badgeText && (
                    <span className="ml-2 rounded-full bg-text/[0.06] px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-muted-text">
                      {row.badgeText}
                    </span>
                  )}
                </span>
                <span className="dictation-mode-card-desc text-xs text-muted-text">
                  {row.description}
                </span>
              </div>
              <div className="dictation-mode-card-footer flex items-center px-3 py-2">
                <ShortcutReminder
                  shortcutText={row.shortcutText}
                  hasShortcut={row.hasShortcut}
                />
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

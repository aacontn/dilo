import React from "react";
import { useTranslation } from "react-i18next";
import { MemoryStick } from "lucide-react";

interface UnloadModelButtonProps {
  /** Only a loaded model can be unloaded — hide the button otherwise. */
  visible: boolean;
  disabled?: boolean;
  onUnload: () => void;
  className?: string;
}

/**
 * Manual shortcut to free the model from RAM without closing Dilo. Dilo also
 * does this on its own after a configurable idle timeout
 * (`ModelUnloadTimeoutSetting`) — this button is just the "do it now" path,
 * which macOS lost when the native tray menu was removed in 84dc360f.
 */
const UnloadModelButton: React.FC<UnloadModelButtonProps> = ({
  visible,
  disabled = false,
  onUnload,
  className = "",
}) => {
  const { t } = useTranslation();

  if (!visible) return null;

  return (
    <button
      type="button"
      onClick={onUnload}
      disabled={disabled}
      title={t("modelSelector.unloadModelTooltip")}
      aria-label={t("modelSelector.unloadModel")}
      className={`flex items-center justify-center w-5 h-5 shrink-0 rounded text-text/50 hover:text-text/80 hover:bg-mid-gray/10 transition-colors disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-transparent ${className}`}
    >
      <MemoryStick className="w-3.5 h-3.5" />
    </button>
  );
};

export default UnloadModelButton;

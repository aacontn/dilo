import { useEffect, useRef, useState } from "react";
import { Check, Mic, RotateCcw } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useSettings } from "@/hooks/useSettings";
import { useOsType } from "@/hooks/useOsType";
import { formatKeyCombination } from "@/lib/utils/keyboard";
import { Button } from "../ui/Button";
import { Wordmark } from "../shared";

interface DictationTestOnboardingProps {
  onComplete: () => void;
}

export const DictationTestOnboarding = ({
  onComplete,
}: DictationTestOnboardingProps) => {
  const { t } = useTranslation();
  const { settings } = useSettings();
  const osType = useOsType();
  const [text, setText] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const success = text.trim().length > 0;
  const shortcut =
    settings?.bindings?.transcribe?.current_binding || "option+space";

  useEffect(() => {
    textareaRef.current?.focus();
  }, []);

  const tryAgain = () => {
    setText("");
    requestAnimationFrame(() => textareaRef.current?.focus());
  };

  return (
    <div className="h-screen w-screen flex flex-col items-center justify-center p-6">
      <div className="w-full max-w-xl">
        <div className="flex flex-col items-center text-center mb-5">
          <Wordmark size="lg" />
          <div className="mt-4 flex items-center justify-center size-11 rounded-full bg-logo-primary/10 text-logo-primary">
            {success ? (
              <Check className="size-6" />
            ) : (
              <Mic className="size-6" />
            )}
          </div>
          <h1 className="mt-3 font-display text-2xl font-semibold text-text">
            {success
              ? t("onboarding.test.successTitle")
              : t("onboarding.test.title")}
          </h1>
          <p className="mt-1 max-w-md text-sm text-text/65">
            {success
              ? t("onboarding.test.successDescription")
              : t("onboarding.test.description")}
          </p>
        </div>

        <div
          className={`rounded-2xl border p-3 transition-colors ${
            success
              ? "border-menta/45 bg-menta/[0.05]"
              : "border-logo-primary/25 bg-logo-primary/[0.04]"
          }`}
        >
          <textarea
            ref={textareaRef}
            value={text}
            onChange={(event) => setText(event.target.value)}
            placeholder={t("onboarding.test.placeholder")}
            aria-label={t("onboarding.test.fieldLabel")}
            className="h-28 w-full resize-none rounded-xl border border-mid-gray/15 bg-background px-4 py-3 text-base text-text outline-none placeholder:text-text/30 focus:border-logo-primary/55"
          />
          <div className="flex items-center justify-between gap-3 px-1 pt-3">
            <p className="text-xs text-text/50">
              {t("onboarding.test.shortcutPrefix")}{" "}
              <kbd className="font-mono rounded border border-mid-gray/20 bg-mid-gray/10 px-1.5 py-0.5 text-text/80">
                {formatKeyCombination(shortcut, osType)}
              </kbd>
            </p>
            {success && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={tryAgain}
                className="flex items-center gap-1.5"
              >
                <RotateCcw className="size-3.5" />
                {t("onboarding.test.tryAgain")}
              </Button>
            )}
          </div>
        </div>

        <div className="mt-4 flex items-center justify-between">
          <Button type="button" variant="ghost" onClick={onComplete}>
            {t("onboarding.test.skip")}
          </Button>
          <Button
            type="button"
            variant="primary"
            size="lg"
            disabled={!success}
            onClick={onComplete}
          >
            {t("onboarding.test.finish")}
          </Button>
        </div>
      </div>
    </div>
  );
};

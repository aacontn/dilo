import React from "react";

/** Brand name as a TS constant — the wordmark is never localized, and the
 * i18next lint rule only allows JSX text that flows through expressions. */
export const BRAND_NAME = "dilo";
const CARET = "▌";

interface WordmarkProps {
  /** sm — sidebar / headers · lg — onboarding hero */
  size?: "sm" | "lg";
  className?: string;
}

/** `dilo▌` — lowercase Space Grotesk wordmark with the blinking mango caret
 * (a prompt waiting for you to speak). Caret styling + `dilo-blink` keyframes
 * live in src/styles/brand.css. */
const Wordmark: React.FC<WordmarkProps> = ({ size = "sm", className = "" }) => {
  const sizeClasses = size === "lg" ? "text-6xl" : "text-3xl";

  return (
    <span
      className={`font-display font-semibold leading-none tracking-tight text-text select-none ${sizeClasses} ${className}`}
    >
      {BRAND_NAME}
      <span aria-hidden="true" className="wordmark-caret">
        {CARET}
      </span>
    </span>
  );
};

export default Wordmark;

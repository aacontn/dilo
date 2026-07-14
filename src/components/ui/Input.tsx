import React from "react";

interface InputProps extends React.InputHTMLAttributes<HTMLInputElement> {
  variant?: "default" | "compact";
}

export const Input: React.FC<InputProps> = ({
  className = "",
  variant = "default",
  disabled,
  ...props
}) => {
  const baseClasses =
    "px-2 py-1 text-sm font-medium bg-[var(--glass-inset)] border border-[var(--glass-border)] rounded-md text-start transition-all duration-150";

  const interactiveClasses = disabled
    ? "opacity-60 cursor-not-allowed"
    : "hover:bg-text/[0.05] hover:border-text/20 focus:outline-none focus:border-accent-text focus:ring-1 focus:ring-accent-text";

  const variantClasses = {
    default: "px-3 py-2",
    compact: "px-2 py-1",
  } as const;

  return (
    <input
      className={`${baseClasses} ${variantClasses[variant]} ${interactiveClasses} ${className}`}
      disabled={disabled}
      {...props}
    />
  );
};

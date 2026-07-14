import React from "react";

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?:
    | "primary"
    | "primary-soft"
    | "secondary"
    | "danger"
    | "danger-ghost"
    | "ghost";
  size?: "sm" | "md" | "lg";
}

export const Button: React.FC<ButtonProps> = ({
  children,
  className = "",
  variant = "primary",
  size = "md",
  ...props
}) => {
  const baseClasses =
    "font-medium rounded-lg border focus:outline-none transition-colors disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer";

  const variantClasses = {
    primary:
      "text-ink bg-background-ui border-background-ui hover:bg-background-ui/80 hover:border-background-ui/80 focus:ring-1 focus:ring-background-ui",
    "primary-soft":
      "text-text bg-logo-primary/20 border-transparent hover:bg-logo-primary/30 focus:ring-1 focus:ring-accent-text",
    secondary:
      "bg-text/[0.04] border-text/10 hover:bg-text/[0.08] hover:border-text/20 focus:outline-none",
    danger:
      "text-ink bg-rojo border-mid-gray/20 hover:bg-rojo/85 hover:border-rojo/85 focus:ring-1 focus:ring-rojo",
    "danger-ghost":
      "text-danger-text border-transparent hover:text-danger-text hover:bg-rojo/10 focus:bg-rojo/20",
    ghost:
      "text-current border-transparent hover:bg-text/[0.06] focus:bg-text/[0.09]",
  };

  const sizeClasses = {
    sm: "px-2 py-1 text-xs",
    md: "px-4 py-[5px] text-sm",
    lg: "px-4 py-2 text-base",
  };

  return (
    <button
      className={`${baseClasses} ${variantClasses[variant]} ${sizeClasses[size]} ${className}`}
      {...props}
    >
      {children}
    </button>
  );
};

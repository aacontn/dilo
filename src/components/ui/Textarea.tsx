import React from "react";

interface TextareaProps
  extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
  variant?: "default" | "compact" | "prompt";
}

export const Textarea: React.FC<TextareaProps> = ({
  className = "",
  variant = "default",
  ...props
}) => {
  const baseClasses =
    "px-2 py-1 text-sm font-semibold bg-mid-gray/10 border border-mid-gray/80 rounded-md text-start transition-[background-color,border-color] duration-150 hover:bg-logo-primary/10 hover:border-accent-text focus:outline-none focus:bg-logo-primary/10 focus:border-accent-text resize-y";

  const variantClasses = {
    default: "px-3 py-2 min-h-[100px]",
    compact: "px-2 py-1 min-h-[80px]",
    // Instrucciones de un modo de dictado: los de fábrica tienen entre 600 y
    // 900 caracteres, que en 100px se ven por la ventanita de un sobre
    // ("el prompt no se ve completo", reporte del dueño). Con 280px entran
    // enteros; sigue siendo redimensionable (`resize-y`) para los largos.
    prompt: "px-3 py-2 min-h-[280px] font-normal leading-relaxed",
  };

  return (
    <textarea
      className={`${baseClasses} ${variantClasses[variant]} ${className}`}
      {...props}
    />
  );
};

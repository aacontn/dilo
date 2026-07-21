import React, { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useTranslation } from "react-i18next";

export interface DropdownOption {
  value: string;
  label: string;
  disabled?: boolean;
}

interface DropdownProps {
  options: DropdownOption[];
  className?: string;
  selectedValue: string | null;
  onSelect: (value: string) => void;
  placeholder?: string;
  disabled?: boolean;
  onRefresh?: () => void;
}

export const Dropdown: React.FC<DropdownProps> = ({
  options,
  selectedValue,
  onSelect,
  className = "",
  placeholder = "Select an option...",
  disabled = false,
  onRefresh,
}) => {
  const { t } = useTranslation();
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const [menuRect, setMenuRect] = useState<{
    top: number;
    left: number;
    width: number;
  } | null>(null);

  // El menú se monta en <body> vía portal, no dentro del contenedor: las
  // tarjetas de ajustes (`.glass-surface`) usan `backdrop-filter`, y eso crea
  // un stacking context propio por tarjeta. Dentro de él, cualquier z-index
  // del menú solo compite con sus hermanos de esa tarjeta, así que la tarjeta
  // siguiente lo tapaba entero. Al portarlo al body, el menú vuelve a competir
  // en el contexto raíz. Como contrapartida ya no hereda la posición del
  // contenedor y hay que calcularla a mano (`position: fixed`).
  const updateMenuRect = useCallback(() => {
    const trigger = dropdownRef.current;
    if (!trigger) return;
    const rect = trigger.getBoundingClientRect();
    setMenuRect({ top: rect.bottom + 4, left: rect.left, width: rect.width });
  }, []);

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      const target = event.target as Node;
      // El menú vive fuera de `dropdownRef` (portal), así que hay que
      // excluirlo aparte o el mousedown sobre una opción cerraría el menú
      // antes de que su click llegue a dispararse.
      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(target) &&
        !menuRef.current?.contains(target)
      ) {
        setIsOpen(false);
      }
    };
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  // Con `position: fixed` el menú no sigue al contenedor solo: si la lista de
  // ajustes hace scroll o cambia el tamaño de la ventana, hay que recolocarlo.
  useEffect(() => {
    if (!isOpen) return;
    updateMenuRect();
    window.addEventListener("scroll", updateMenuRect, true);
    window.addEventListener("resize", updateMenuRect);
    return () => {
      window.removeEventListener("scroll", updateMenuRect, true);
      window.removeEventListener("resize", updateMenuRect);
    };
  }, [isOpen, updateMenuRect]);

  const selectedOption = options.find(
    (option) => option.value === selectedValue,
  );

  const handleSelect = (value: string) => {
    onSelect(value);
    setIsOpen(false);
  };

  const handleToggle = () => {
    if (disabled) return;
    if (!isOpen && onRefresh) onRefresh();
    // Medir antes de pintar evita que el menú aparezca un frame en (0,0).
    if (!isOpen) updateMenuRect();
    setIsOpen(!isOpen);
  };

  return (
    <div className={`relative ${className}`} ref={dropdownRef}>
      <button
        type="button"
        className={`px-2 py-[5px] text-sm font-medium bg-[var(--glass-inset)] border border-[var(--glass-border)] rounded-md min-w-[200px] w-full text-start grid grid-cols-[1fr_auto] gap-2 items-center transition-all duration-150 ${
          disabled
            ? "opacity-50 cursor-not-allowed"
            : "hover:bg-text/[0.05] cursor-pointer hover:border-text/20"
        }`}
        onClick={handleToggle}
        disabled={disabled}
      >
        <span className="truncate">{selectedOption?.label || placeholder}</span>
        <svg
          className={`w-4 h-4 transition-transform duration-200 ${isOpen ? "transform rotate-180" : ""}`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M19 9l-7 7-7-7"
          />
        </svg>
      </button>
      {isOpen &&
        !disabled &&
        menuRect &&
        createPortal(
          <div
            ref={menuRef}
            style={{
              position: "fixed",
              top: menuRect.top,
              left: menuRect.left,
              width: menuRect.width,
            }}
            className="glass-popover rounded-lg z-[1000] max-h-60 overflow-y-auto"
          >
            {options.length === 0 ? (
              <div className="px-2 py-1 text-sm text-muted-text">
                {t("common.noOptionsFound")}
              </div>
            ) : (
              options.map((option) => (
                <button
                  key={option.value}
                  type="button"
                  className={`w-full px-2 py-1 text-sm text-start hover:bg-logo-primary/10 transition-colors duration-150 ${
                    selectedValue === option.value
                      ? "bg-logo-primary/20 font-semibold"
                      : ""
                  } ${option.disabled ? "opacity-50 cursor-not-allowed" : ""}`}
                  onClick={() => handleSelect(option.value)}
                  disabled={option.disabled}
                >
                  <span className="whitespace-normal break-words">
                    {option.label}
                  </span>
                </button>
              ))
            )}
          </div>,
          document.body,
        )}
    </div>
  );
};

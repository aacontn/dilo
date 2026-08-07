import { describe, expect, it } from "bun:test";
import {
  attachOrDiscardListener,
  comboFromHandyKeysEvent,
} from "@/lib/utils/keyboard";

describe("captura de atajos de modo", () => {
  it("conserva fn, que el navegador nunca reporta en macOS", () => {
    expect(comboFromHandyKeysEvent({ modifiers: ["fn"], key: "F17" })).toBe(
      "fn+f17",
    );
  });

  it("una tecla sin modificadores queda sola", () => {
    expect(comboFromHandyKeysEvent({ modifiers: [], key: "F17" })).toBe("f17");
  });
});

describe("carrera montaje/desmontaje del listener nativo", () => {
  it("si el efecto ya se limpió antes de que listen() resuelva, desengancha de inmediato en vez de guardarlo", () => {
    let unlistenCalls = 0;
    const unlisten = () => {
      unlistenCalls += 1;
    };
    let attached: (() => void) | null = null;

    // Simula listen() resolviendo después de que el cleanup del efecto ya
    // corrió (editing pasó a false por cancelar, guardar o desmontar).
    attachOrDiscardListener(unlisten, /* wasCanceled */ true, (fn) => {
      attached = fn;
    });

    expect(unlistenCalls).toBe(1);
    expect(attached).toBeNull();
  });

  it("si el efecto sigue vivo, guarda el unlisten en vez de llamarlo", () => {
    let unlistenCalls = 0;
    const unlisten = () => {
      unlistenCalls += 1;
    };
    let attached: (() => void) | null = null;

    attachOrDiscardListener(unlisten, /* wasCanceled */ false, (fn) => {
      attached = fn;
    });

    expect(unlistenCalls).toBe(0);
    expect(attached).toBe(unlisten);
  });
});

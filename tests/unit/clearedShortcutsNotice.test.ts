import { describe, expect, test } from "bun:test";
import type { TFunction } from "i18next";
import {
  buildClearedNoticeSummary,
  buildClearedNoticeText,
  shouldShowClearedNotice,
} from "@/lib/clearedShortcutsNotice";
import type { ModeShortcutsClearedEvent } from "@/lib/types/events";

/** Traductor de identidad, igual que en `postProcessPresets.test.ts`. */
const identityT = ((key: string, opts?: Record<string, string>) =>
  opts ? `${key}|${opts.modes}` : key) as unknown as TFunction;

const evento = (
  modes: ModeShortcutsClearedEvent["modes"],
): ModeShortcutsClearedEvent => ({ modes });

describe("shouldShowClearedNotice", () => {
  // Rust reemite el aviso en cada `get_app_settings` y en cada ventana que se
  // muestra — a propósito, porque no puede saber si había alguien
  // escuchando. Cortar la repetición es responsabilidad de este lado.
  test("se muestra una sola vez por sesión", () => {
    const e = evento([{ mode_name: "Correo", shortcut: "f17" }]);
    expect(shouldShowClearedNotice(e, false)).toBe(true);
    expect(shouldShowClearedNotice(e, true)).toBe(false);
  });

  test("un aviso sin modos no se muestra", () => {
    expect(shouldShowClearedNotice(evento([]), false)).toBe(false);
    expect(shouldShowClearedNotice(null, false)).toBe(false);
    expect(shouldShowClearedNotice(undefined, false)).toBe(false);
  });
});

describe("buildClearedNoticeSummary", () => {
  test("dice el modo y la tecla que perdió", () => {
    // Decir cuál era la tecla importa: es la que la persona iba a apretar.
    const resumen = buildClearedNoticeSummary(
      evento([
        { mode_name: "Correo", shortcut: "f17" },
        { mode_name: "Código", shortcut: "f9" },
      ]),
      "macos",
    );
    expect(resumen).toBe("Correo (F17), Código (F9)");
  });

  test("el texto del aviso lleva la lista dentro", () => {
    const { title, description } = buildClearedNoticeText(
      evento([{ mode_name: "Correo", shortcut: "f17" }]),
      "macos",
      identityT,
    );
    expect(title).toBe("settings.postProcessing.modes.clearedNoticeTitle");
    expect(description).toBe(
      "settings.postProcessing.modes.clearedNotice|Correo (F17)",
    );
  });
});

describe("cableado del aviso", () => {
  // Lo que las funciones puras no pueden cubrir: que el aviso sobreviva a que
  // nadie tenga una ventana abierta, que es el caso normal al actualizar.
  test("Rust guarda el aviso en el store, no sólo en memoria", async () => {
    const source = await Bun.file("src-tauri/src/settings.rs").text();
    expect(source).toContain('"pending_mode_shortcut_notice"');
    expect(source).toContain("store.set(PENDING_SHORTCUT_NOTICE_KEY, notice)");
  });

  test("se reemite al mostrarse una ventana y al pedir los ajustes", async () => {
    const utils = await Bun.file("src-tauri/src/utils.rs").text();
    expect(utils).toContain("emit_pending_shortcut_notice(app)");
    const commands = await Bun.file("src-tauri/src/commands/mod.rs").text();
    expect(commands).toContain("emit_pending_shortcut_notice(&app)");
  });

  test("asignar una tecla de modo lo da por cumplido", async () => {
    const source = await Bun.file("src-tauri/src/shortcut/mod.rs").text();
    expect(source).toContain("clear_pending_shortcut_notice(&app)");
  });

  test("el frontend pide el refresco DESPUÉS de poner el listener", async () => {
    // El orden es lo único que evita perder el aviso en el arranque:
    // `listen()` resuelve asincrónicamente.
    const source = await Bun.file("src/App.tsx").text();
    // Se busca la llamada, no el nombre importado: el `import` menciona el
    // evento mucho antes y haría pasar el test siempre.
    const listener = source.indexOf("await listen<ModeShortcutsClearedEvent>(");
    const poke = source.indexOf("await commands.getAppSettings();");
    expect(listener).toBeGreaterThan(-1);
    expect(poke).toBeGreaterThan(listener);
  });
});

import { describe, expect, it } from "bun:test";
import {
  buildShortcutOwners,
  findShortcutConflict,
  resolveShortcutConflict,
} from "@/lib/utils/shortcutConflicts";

const owners = [
  {
    kind: "binding" as const,
    id: "transcribe",
    name: "Dictado",
    combo: "fn+f19",
  },
  { kind: "mode" as const, id: "dilo-email", name: "Correo", combo: "fn+f15" },
];

describe("conflictos de atajos", () => {
  it("detecta que la tecla ya la usa el dictado", () => {
    expect(findShortcutConflict("fn+f19", owners, "dilo-clean")?.name).toBe(
      "Dictado",
    );
  });

  it("un modo no choca consigo mismo al reasignar la misma tecla", () => {
    expect(findShortcutConflict("fn+f15", owners, "dilo-email")).toBeNull();
  });

  it("una tecla libre no da conflicto", () => {
    expect(findShortcutConflict("fn+f13", owners, "dilo-clean")).toBeNull();
  });

  it("compara sin importar mayúsculas", () => {
    expect(findShortcutConflict("FN+F19", owners, "dilo-clean")?.name).toBe(
      "Dictado",
    );
  });

  it("compara sin importar el orden de los modificadores", () => {
    const reordered = [
      {
        kind: "binding" as const,
        id: "transcribe",
        name: "Dictado",
        combo: "f19+fn",
      },
    ];
    expect(findShortcutConflict("fn+f19", reordered, "dilo-clean")?.name).toBe(
      "Dictado",
    );
  });

  it("una combinación vacía nunca da conflicto", () => {
    expect(findShortcutConflict("", owners, "dilo-clean")).toBeNull();
  });
});

describe("armado de la lista de dueños", () => {
  it("junta bindings generales y modos con atajo propio", () => {
    const settings = {
      bindings: {
        transcribe: {
          id: "transcribe",
          name: "Dictado",
          description: "",
          default_binding: "fn+f19",
          current_binding: "fn+f19",
        },
        cancel: {
          id: "cancel",
          name: "Cancelar",
          description: "",
          default_binding: "esc",
          current_binding: "esc",
        },
      },
      post_process_prompts: [
        {
          id: "dilo-email",
          name: "Correo",
          prompt: "",
          shortcut: "fn+f15",
        },
        {
          id: "dilo-clean",
          name: "Limpieza",
          prompt: "",
          shortcut: null,
        },
      ],
    } as never;

    const result = buildShortcutOwners(settings);

    expect(result).toContainEqual({
      kind: "binding",
      id: "transcribe",
      name: "Dictado",
      combo: "fn+f19",
    });
    expect(result).toContainEqual({
      kind: "mode",
      id: "dilo-email",
      name: "Correo",
      combo: "fn+f15",
    });
    // "dilo-clean" has no shortcut assigned; it must not appear as an owner.
    expect(result.find((owner) => owner.id === "dilo-clean")).toBeUndefined();
  });

  it("con settings nulos devuelve una lista vacía", () => {
    expect(buildShortcutOwners(null)).toEqual([]);
    expect(buildShortcutOwners(undefined)).toEqual([]);
  });
});

// Exercises the exact composition `ModeShortcutInput.tsx` calls at commit
// time: settings -> resolveShortcutConflict(combo, settings, selfId). This
// is the wiring Task 1's follow-up warned about — a mutation to how
// `buildShortcutOwners` and `findShortcutConflict` are combined (wrong
// argument, dropped selfId) can't be caught by a mounted-component test
// (no React here), so it has to be caught here instead.
describe("resolución de conflicto desde settings completos", () => {
  const settings = {
    bindings: {
      transcribe: {
        id: "transcribe",
        name: "Dictado",
        description: "",
        default_binding: "fn+f19",
        current_binding: "fn+f19",
      },
    },
    post_process_prompts: [
      { id: "dilo-email", name: "Correo", prompt: "", shortcut: "fn+f15" },
    ],
  } as never;

  it("detecta el choque contra un binding general", () => {
    expect(
      resolveShortcutConflict("fn+f19", settings, "dilo-email")?.name,
    ).toBe("Dictado");
  });

  it("detecta el choque contra otro modo", () => {
    expect(
      resolveShortcutConflict("fn+f15", settings, "dilo-clean")?.name,
    ).toBe("Correo");
  });

  it("un modo no choca consigo mismo", () => {
    expect(
      resolveShortcutConflict("fn+f15", settings, "dilo-email"),
    ).toBeNull();
  });

  it("una tecla libre no da conflicto", () => {
    expect(
      resolveShortcutConflict("fn+f13", settings, "dilo-clean"),
    ).toBeNull();
  });
});

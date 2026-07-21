import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "../..");

const read = (name: string) =>
  readFileSync(join(repoRoot, name), "utf8").trimEnd();

describe("instrucciones para asistentes", () => {
  // CLAUDE.md es la fuente de verdad; AGENTS.md existe para las herramientas
  // que lo buscan por nombre (Codex). Se mantienen como copias idénticas en
  // vez de un puntero `Read @CLAUDE.md` porque no todas las herramientas
  // resuelven esa referencia, y una que no la resuelva se queda sin ninguna
  // instrucción. Este test es la guardia: si editas uno y olvidas el otro,
  // falla acá y no en medio de una sesión con el asistente desalineado.
  test("CLAUDE.md y AGENTS.md son idénticos", () => {
    expect(read("AGENTS.md")).toBe(read("CLAUDE.md"));
  });

  test("no quedan punteros en vez del contenido", () => {
    for (const name of ["CLAUDE.md", "AGENTS.md"]) {
      const content = read(name);
      expect(content.split("\n").length).toBeGreaterThan(10);
      expect(content).not.toMatch(/^Read @/m);
    }
  });
});

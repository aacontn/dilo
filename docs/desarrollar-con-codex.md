# Desarrollar Dilo con Codex (respaldo a Claude Code)

Dilo se desarrolla con asistentes de IA. El principal es **Claude Code**; este
doc es el **plan B para cuando se te acaben los tokens/límite de Claude** y
quieras seguir avanzando sin parar.

**Por qué sirve como respaldo:** el CLI de Codex se autentica con tu cuenta de
**ChatGPT**, no con la de Claude. Son cuotas separadas — si una se agota, la otra
sigue. Y como Codex lee `AGENTS.md` (que es copia byte a byte de `CLAUDE.md`),
trabaja con **exactamente las mismas instrucciones** que Claude Code. No hay que
reconfigurar nada.

## Requisitos

- **Codex CLI instalado.** Comprueba con `codex --version`. Para actualizar:
  `codex update`. Para diagnosticar instalación/login/entorno: `codex doctor`.
- **Sesión iniciada.** `codex login status` debe decir que estás logueado
  (con ChatGPT). Si no: `codex login`.

## Cómo lo corres

Desde la raíz del repo:

```bash
cd ~/Developer/Dilo/dilo

# Sesión interactiva (como Claude Code). Lee AGENTS.md solo.
codex

# Con una instrucción directa de arranque
codex "arregla el bug X en tal archivo"

# No interactivo (scripts, tareas de una pasada)
codex exec "corre los tests y arregla lo que falle"

# Continuar la última sesión donde quedaste
codex resume --last
```

Flags útiles:

| Flag                                | Para qué                                                  |
| ----------------------------------- | --------------------------------------------------------- |
| `-m, --model <MODELO>`              | Elegir modelo                                             |
| `-a, --ask-for-approval <POLÍTICA>` | Cuánto te pide confirmar antes de actuar                  |
| `-s, --sandbox <MODO>`              | Nivel de aislamiento al tocar archivos/red                |
| `-C, --cd <DIR>`                    | Correr apuntando a otro directorio                        |
| `--search`                          | Habilitar búsqueda web                                    |
| `codex apply`                       | Aplicar el último diff que produjo Codex como `git apply` |

Empieza conservador con la aprobación (que te pida confirmar acciones) hasta que
le tomes confianza en este repo.

## Reglas del proyecto

**No las repetimos aquí a propósito:** viven en `AGENTS.md` (= `CLAUDE.md`) y
Codex las lee solo. Ahí están el copy español-primero, la regla de mantener el
núcleo Rust cerca de upstream, y el flujo de commits.

Recordatorio del checklist antes de commitear (lo mismo que corre Claude):

```bash
bun run lint
bun run format:check
bun test tests/unit
bun run check:translations   # falla si algún idioma queda incompleto
cd src-tauri && cargo test && cargo clippy
```

## Gotchas

- **`gh` en este repo:** usa siempre `--repo aacontn/dilo`. Hay un remote
  `upstream` que apunta a Handy (`cjpais/handy`), y `gh` por defecto puede
  resolver ahí y rechazarte por permisos (o peor, tocar el repo equivocado).
- **CLAUDE.md es la fuente.** Si Codex edita `CLAUDE.md`, tiene que copiarlo a
  `AGENTS.md` — `tests/unit/agentInstructions.test.ts` falla si divergen.
- **Verifica igual que con Claude.** Codex es capaz, pero el trabajo se revisa
  con la misma vara: corre la batería de tests de arriba antes de dar algo por
  cerrado.

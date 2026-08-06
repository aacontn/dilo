# Un atajo por modo — Plan de implementación

> **Para agentes:** SUB-SKILL REQUERIDA: usar superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar tarea por tarea. Los pasos usan casillas (`- [ ]`) para seguimiento.

**Objetivo:** que cada modo de transformación sea invocable por su propia tecla, y que desaparezca el "modo activo" que hoy obliga a elegir uno en Ajustes.

**Arquitectura:** el modelo mental pasa de "un modo activo + un atajo general" a "cada modo = prompt + tecla + proveedor". La pantalla Transformar se parte en dos pestañas (Modos / Proveedor) porque hoy apila tres cosas que se tocan en momentos distintos. La captura de atajos de modo se unifica con la de los atajos generales, que es la causa raíz del bug.

**Stack:** Tauri 2 (Rust) + React/TypeScript, `handy-keys 0.3.0` para atajos globales.

**Diseño:** [`docs/superpowers/specs/2026-08-05-atajos-por-modo-design.md`](../specs/2026-08-05-atajos-por-modo-design.md)

## Restricciones globales

- **Sin dependencias nuevas.**
- **El dictado no cambia.** Su atajo, su camino y su modelo se quedan como están.
- **Copia es-first en tuteo chileno, NUNCA voseo** — "podés", "querés", "detené", "mirá" son defectos; van "puedes", "quieres", "detén", "mira". Toda clave nueva en los 21 idiomas, traducida de verdad: `check:translations` sólo verifica que la clave exista, así que el relleno en inglés pasa el gate y le llega al usuario.
- **`src/bindings.ts` es generado, nunca a mano**: desde `src-tauri/`, `cargo build && ./target/debug/dilo --list-devices`.
- **NUNCA agregar `Co-Authored-By` ni atribución de IA a los commits.**
- **Un `settings.json` de 0.2.2 tiene que cargar sin que nadie pierda su configuración.**

### Cómo compilar en esta máquina — LEER

La máquina del dueño tiene 16 GB y **se le congeló dos veces por compilaciones de Rust**, con apagado forzado y más de una hora perdida cada vez.

- **Un solo comando de cargo a la vez. NUNCA dos en paralelo, ni de fondo.**
- **NO correr `tauri dev` ni `cargo build --release`.**
- **Agrupar las compilaciones**: hacer todos los cambios de Rust y compilar una vez, no tarea por tarea.
- Los gates de `bun` son livianos y se pueden correr cuando sea.
- **La verificación de Rust es responsabilidad de CI** (`test.yml`, `code-quality.yml` corren en cada push). Preferir CI antes que compilar local.

---

## Estructura de archivos

| Archivo                                                              | Responsabilidad                                                                   | Tarea          |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------- | -------------- |
| `src/components/settings/ModeShortcutInput.tsx`                      | Captura del atajo de un modo — **hoy usa eventos del navegador, ahí está el bug** | 1              |
| `src/components/settings/HandyKeysShortcutInput.tsx`                 | Captura de los atajos generales — **el patrón correcto a seguir**, no se modifica | 1 (referencia) |
| `src/lib/utils/shortcutConflicts.ts`                                 | Detectar que una tecla ya está ocupada (nuevo)                                    | 2              |
| `src-tauri/src/settings.rs`                                          | Campo del modo activo y su migración                                              | 3              |
| `src-tauri/src/shortcut/mod.rs`                                      | Registro de atajos de modo; lógica del modo activo                                | 3              |
| `src-tauri/src/actions.rs`                                           | Resolución de qué prompt aplicar                                                  | 3              |
| `src/components/settings/post-processing/PostProcessingSettings.tsx` | Pantalla Transformar → dos pestañas                                               | 4              |
| `src/components/home/HomeDashboard.tsx`, `DictationModes.tsx`        | Inicio: estado + recordatorio de teclas                                           | 5              |

---

## Task 1: La captura de atajos de modo usa el grabador nativo

**Por qué primero:** es la causa raíz del bug reportado y se puede verificar sin tocar nada más. En la instalación del dueño el modo "Correo" quedó con `f17` mientras su teclado emite `fn+f17`, así que ese atajo **nunca disparó**.

**Causa, confirmada leyendo el código:**

- `HandyKeysShortcutInput.tsx:3,83` usa `listen<HandyKeysEvent>` — el **grabador nativo** de `handy-keys`, que sí ve la tecla `fn`.
- `ModeShortcutInput.tsx:156-157` usa `window.addEventListener("keydown"/"keyup")` — **eventos del navegador**, y en macOS **`fn` no genera evento de navegador**.

**Files:**

- Modify: `src/components/settings/ModeShortcutInput.tsx`
- Reference (NO modificar): `src/components/settings/HandyKeysShortcutInput.tsx`

**Interfaces:**

- Consume: `commands.startHandyKeysRecording()` / `commands.stopHandyKeysRecording()` y el evento `HandyKeysEvent`, tal como los usa `HandyKeysShortcutInput.tsx`.
- Produce: `ModeShortcutInput` guarda con `commands.changeModeShortcut(promptId, value)` (ya existe, línea 59) — la firma no cambia, sólo de dónde sale `value`.

- [ ] **Paso 1: Leer completo `HandyKeysShortcutInput.tsx`**

No lo resumas ni lo adaptes de memoria: es el patrón correcto y hay que entender su ciclo completo (arrancar la grabación, escuchar, parar, limpiar el listener en `unlistenRef`). Los bugs de esta clase salen de copiar la mitad.

- [ ] **Paso 2: Escribir el test que falla**

En `tests/unit/` (Bun). Cubre exactamente la regla que se rompió: un atajo capturado tiene que conservar los modificadores que el grabador nativo reporta.

```ts
import { describe, expect, it } from "bun:test";
import { comboFromHandyKeysEvent } from "@/lib/utils/keyboard";

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
```

- [ ] **Paso 3: Correr el test y confirmar que falla**

`bun test tests/unit` — falla porque `comboFromHandyKeysEvent` no existe todavía.

- [ ] **Paso 4: Extraer la conversión a `src/lib/utils/keyboard.ts`**

Hoy esa lógica vive dentro de `HandyKeysShortcutInput.tsx`. Sácala a una función pura para que los dos componentes la compartan y sea testeable sin montar React.

- [ ] **Paso 5: Reemplazar la captura de `ModeShortcutInput`**

Sacar los tres `window.addEventListener` (líneas 156-158) y usar el grabador nativo. Cuidar: parar la grabación y soltar el listener al desmontar y al cancelar — igual que hace el de referencia.

- [ ] **Paso 6: Correr los gates de front**

`bun test tests/unit`, `bun run build`, `bun run lint`, `bun run format:check`.

- [ ] **Paso 7: Mutar y confirmar**

Cambia la conversión para que descarte `fn` y confirma que el test lo caza. Revierte verificando con `diff`.

- [ ] **Paso 8: Commit**

```bash
git add src/components/settings/ModeShortcutInput.tsx src/lib/utils/keyboard.ts tests/unit
git commit -m "fix(atajos): los atajos de modo se capturan con el grabador nativo"
```

---

## Task 2: Avisar cuando una tecla ya está ocupada

Hoy asignar una tecla ya usada deja un atajo muerto en silencio. Con un atajo por modo esto pasa a ser mucho más probable.

**Files:**

- Create: `src/lib/utils/shortcutConflicts.ts`
- Create: `tests/unit/shortcutConflicts.test.ts`
- Modify: `src/components/settings/ModeShortcutInput.tsx`

**Interfaces:**

- Produce:

  ```ts
  export interface ShortcutOwner {
    kind: "binding" | "mode";
    id: string;
    name: string;
    combo: string;
  }
  export function findShortcutConflict(
    combo: string,
    owners: ShortcutOwner[],
    selfId: string,
  ): ShortcutOwner | null;
  ```

- [ ] **Paso 1: Escribir el test que falla**

```ts
import { describe, expect, it } from "bun:test";
import { findShortcutConflict } from "@/lib/utils/shortcutConflicts";

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
});
```

- [ ] **Paso 2: Correr y confirmar que falla.** `bun test tests/unit`

- [ ] **Paso 3: Implementar `findShortcutConflict`**

Comparación normalizada (mismo `normalizeKey` que ya usa `keyboard.ts`), excluyendo al propio dueño por `id`.

- [ ] **Paso 4: Correr y confirmar que pasa.**

- [ ] **Paso 5: Mostrar el aviso en `ModeShortcutInput`**

Aviso, no bloqueo: si hay conflicto se muestra qué lo ocupa y no se guarda. Clave i18n nueva, en los 21 idiomas. Español (autoral, tuteo chileno, **no** voseo):

```
"settings.shortcuts.conflict": "Esa tecla ya la usa {{name}}. Elige otra."
```

- [ ] **Paso 6: Gates de front.** `bun test tests/unit`, `bun run build`, `bun run lint`, `bun run format:check`, `bun run check:translations`.

- [ ] **Paso 7: Commit**

```bash
git add src/lib/utils/shortcutConflicts.ts tests/unit/shortcutConflicts.test.ts src/components/settings/ModeShortcutInput.tsx src/i18n
git commit -m "feat(atajos): avisar cuando la tecla ya está ocupada"
```

---

## Task 3: Fuera el modo activo — backend y migración

**Files:**

- Modify: `src-tauri/src/settings.rs:501` (campo), `:1171` (default), `:1706` (fixture de test)
- Modify: `src-tauri/src/actions.rs:306,709` (resolución del prompt)
- Modify: `src-tauri/src/shortcut/mod.rs:1266-1267,1330` (lógica del modo activo)

**Interfaces:**

- Consume: `LLMPrompt { id, name, prompt, shortcut, provider_id, model }` (ya existe en `settings.rs`).
- Produce: `post_process_selected_prompt_id` deja de existir. `resolve_mode_prompt` pasa a depender sólo del `binding_id` (`mode:<prompt_id>`), sin fallback al modo activo.

**Reglas de migración** (un `settings.json` de 0.2.2 tiene que cargar):

1. El prompt al que apunta `post_process_selected_prompt_id` **hereda el atajo** que tenía `transcribe_with_post_process`, para no perder la elección de la persona.
2. Un atajo de modo **sin modificadores cuando el resto de los atajos sí los tiene** (el caso `f17` con teclado que emite `fn+f17`) **se borra**. No se intenta corregir adivinando: la app no sabe qué teclado hay, y un atajo inventado sería otro atajo fantasma. El modo queda sin tecla, visible en la lista.
3. Un `provider_id` de modo que apunte a un proveedor **sin clave** vuelve a `None` (usa el general).
4. **Instalación nueva:** el modo `dilo-clean` (Limpio) trae `fn+F17` de fábrica.

- [ ] **Paso 1: Escribir los tests de migración que fallan**

En el módulo de tests de `settings.rs`, siguiendo el patrón de los que ya están ahí (ver `salvage_drops_only_wrong_typed_fields`). Uno por regla:

```rust
#[test]
fn el_modo_activo_hereda_el_atajo_general() {
    // settings 0.2.2: selected = "dilo-email", transcribe_with_post_process = "fn+f17"
    // tras migrar: el prompt dilo-email tiene shortcut "fn+f17"
}

#[test]
fn un_atajo_sin_modificadores_se_borra_si_el_resto_los_tiene() {
    // dilo-email con shortcut "f17" y los bindings generales con "fn+..."
    // tras migrar: dilo-email queda sin shortcut
}

#[test]
fn un_proveedor_de_modo_sin_clave_vuelve_al_general() {
    // dilo-email con provider_id "openai" y post_process_api_keys["openai"] = ""
    // tras migrar: provider_id = None
}

#[test]
fn instalacion_nueva_trae_limpio_en_fn_f17() {
    // AppSettings::default(): dilo-clean tiene shortcut "fn+F17"
}
```

Rellena los cuerpos con el fixture real; el bloque de arriba fija los nombres y lo que cada uno afirma, no es el test terminado.

- [ ] **Paso 2: NO compiles todavía.** Sigue al paso 3 y compila una sola vez al final (ver las restricciones de arriba).

- [ ] **Paso 3: Quitar el campo y su lógica**

Sacar `post_process_selected_prompt_id` de `AppSettings`, de los dos `or_else`/`or` de `actions.rs`, y de la lógica de `shortcut/mod.rs:1266,1330`. Escribir la migración.

- [ ] **Paso 4: Quitarlo del frontend**

`src/stores/settingsStore.ts:140` y `PostProcessingSettings.tsx:158,181`. El desplegable "Prompt activo" desaparece en la Task 4; acá basta con que compile sin él.

- [ ] **Paso 5: Regenerar bindings**

Desde `src-tauri/`: `cargo build && ./target/debug/dilo --list-devices`. **Ésta es la única compilación de esta tarea.**

- [ ] **Paso 6: Correr los tests una vez**

`cargo test --lib` (uno solo, sin nada en paralelo) y los gates de `bun`.

- [ ] **Paso 7: Mutar y confirmar**

Saca la regla 2 de la migración y confirma que su test la caza. Revierte verificando con `diff`.

- [ ] **Paso 8: Commit**

```bash
git add src-tauri/src src/stores src/components src/bindings.ts
git commit -m "feat(transformar): cada modo tiene su tecla, se acaba el modo activo"
```

---

## Task 4: Transformar en dos pestañas

**Files:**

- Modify: `src/components/settings/post-processing/PostProcessingSettings.tsx`
- Modify: `src/components/settings/post-processing/ModeProviderSelect.tsx`

**Estructura:**

- **Pestaña "Modos"** — la lista: nombre, ícono, tecla, y si usa modelo local u online. Tocar un modo abre su detalle: nombre, instrucciones, tecla, y su IA (`ModeProviderSelect`, que ya existe y se reusa tal cual).
- **Pestaña "Proveedor"** — proveedor, clave, modelo. Es lo que hoy vive en `PostProcessingSettingsApi/`; se mueve entero, no se reescribe.

**Código se queda** en la lista, sin tecla de fábrica.

- [ ] **Paso 1: Leer `PostProcessingSettings.tsx` completo** antes de moverlo. Son tres responsabilidades apiladas y hay que separarlas sin perder comportamiento.

- [ ] **Paso 2: Partir en dos pestañas**, moviendo el bloque de API a la suya y dejando la lista de modos en la otra. Sin desplegable de "Prompt activo".

- [ ] **Paso 3: El textarea de instrucciones entra completo**

El dueño reportó que "el prompt no se ve completo, se ve como una ventana muy chica". Los prompts de fábrica tienen 600-900 caracteres. Ya hay un `min-h-[280px]` de la 0.2.2 — verificar que sobreviva la reorganización.

- [ ] **Paso 4: Claves i18n nuevas** para los títulos de pestaña, en los 21 idiomas. Español:

```
"settings.postProcessing.tabs.modes": "Modos"
"settings.postProcessing.tabs.provider": "Proveedor"
```

- [ ] **Paso 5: Gates de front.** `bun test tests/unit`, `bun run build`, `bun run lint`, `bun run format:check`, `bun run check:translations`.

- [ ] **Paso 6: Commit**

```bash
git add src/components/settings src/i18n
git commit -m "feat(transformar): separar modos de la configuración del proveedor"
```

---

## Task 5: Inicio con estado y recordatorio de teclas

**Files:**

- Modify: `src/components/home/HomeDashboard.tsx`
- Modify: `src/components/home/DictationModes.tsx`

Hoy el Inicio dice **"Modo inteligente activo: fn+F17"** como si hubiera un solo modo inteligente. Con este diseño esa frase deja de tener sentido.

**Queda:** estado arriba (Dilo listo, qué modelo usa, lo último que dictaste) y abajo el recordatorio de teclas — qué hace cada una. **Sin edición**: para editar se va a Transformar.

- [ ] **Paso 1: Sacar "Modo inteligente activo"** y su tarjeta.

- [ ] **Paso 2: El recordatorio lista los atajos reales**, generales y de modo, leyendo la configuración. Un modo sin tecla se muestra sin tecla, no se esconde — así se ve que existe y se le puede asignar una.

- [ ] **Paso 3: Claves i18n** en los 21 idiomas. Español:

```
"home.shortcuts.title": "Tus teclas"
"home.shortcuts.unassigned": "Sin tecla"
```

- [ ] **Paso 4: Gates de front.**

- [ ] **Paso 5: Commit**

```bash
git add src/components/home src/i18n
git commit -m "feat(inicio): recordatorio de teclas en vez de un modo activo"
```

---

## Verificación final (requiere la máquina del dueño)

Esto no se puede probar sin un teclado real y no debe intentarse con compilaciones locales — sale de un build de CI.

- **El atajo de un modo dispara ese modo**, no el general.
- **Una tecla ocupada no se puede asignar** sin aviso.
- **Un atajo capturado desde la interfaz coincide** con lo que emite el teclado — probar con las teclas de función, que es donde apareció el bug.
- **Un `settings.json` de 0.2.2 carga** y conserva la elección de modo.
- **Un modo local y otro online** funcionan los dos en la misma sesión.

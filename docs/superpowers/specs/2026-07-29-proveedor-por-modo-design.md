# Dilo — Proveedor de IA por modo, con local y online explícitos

**Fecha:** 2026-07-29 · **Estado:** diseño aprobado por Alfonso en conversación · **Base:** §4 del spec [2026-07-22 Modos e IA](2026-07-22-modos-e-ia-design.md), sistema de modos (`post_process_prompts`), catálogo de proveedores (`post_process_providers`)

## El problema

Hoy el post-proceso usa **un solo proveedor global** (`post_process_provider_id`, default `openai`) para todos los modos. Si pones Gemini, todos los modos usan Gemini; no hay forma de que Código use uno y Limpio otro.

El spec del 2026-07-22 ya aprobó la solución en su §4, pero quedó sin implementar: el commit que entró (84cec188) sólo agregó Gemini al catálogo. `LLMPrompt` sigue teniendo únicamente `id`, `name`, `prompt` y `shortcut`.

A eso se suma algo que el spec anterior no cubría: **no se ve cuáles modos mandan tu texto fuera del computador**. Apple Intelligence corre en el chip y Ollama en `localhost`, pero en la UI se ven igual que OpenAI o Gemini. La distinción local/online importa y hoy es invisible.

## Decisiones tomadas (con Alfonso)

- **"Local" no es un motor nuevo.** Se etiqueta lo que ya existe: Apple Intelligence (en el chip) y Ollama/LM Studio (vía el proveedor Custom apuntando a `localhost`). Descartados explícitamente: hacer de Ollama un proveedor de primera clase, y empotrar un LLM en Dilo (dependencia nueva, contra las restricciones del spec anterior).
- **Si el proveedor del modo falla, cae al proveedor global.** El dictado casi nunca sale sin procesar.
- **Esa caída avisa cuando cruza de local a nube**, después del hecho. Se prefirió saberlo tarde antes que no saberlo: un modo que pusiste local casi siempre es por privacidad.
- **La elección se hace en dos pasos**: primero General / Local / Online, después el proveedor concreto. La decisión de privacidad va primero y bien visible.

## Diseño

### 1 · Modelo de datos

`LLMPrompt` gana los dos campos que el spec anterior ya definió:

```rust
#[serde(default)]
pub provider_id: Option<String>,   // None = usa el proveedor global
#[serde(default)]
pub model: Option<String>,
```

`None` significa "hereda el general": los settings existentes siguen funcionando sin migración ni tocar nada.

`PostProcessProvider` gana `is_local: bool`:

- **Fijo para los de fábrica**: Apple Intelligence es el único `true`.
- **Derivado para `custom`**: se calcula de su `base_url` (`localhost`, `127.0.0.1`, `::1`). Es el único proveedor cuyo destino lo define el usuario — viene apuntando a Ollama en `localhost:11434`, pero si lo cambia a un servidor remoto deja de decir LOCAL **solo**, sin depender de que alguien se acuerde de actualizar una bandera.

Las claves siguen viviendo en `post_process_api_keys`, una por proveedor. No se duplican por modo.

### 2 · Resolución y caída

Una función pura, testeable sin red:

```rust
fn resolve_mode_provider(settings, prompt) -> Resolved { provider, model, is_local }
```

- `prompt.provider_id == None` → el global.
- Apunta a un proveedor **que ya no existe** (el usuario lo borró) → el global, en silencio. Eso no es una falla, es configuración vieja.
- Sin modelo configurado (ni el del modo ni el default del proveedor) → cuenta como no disponible, y va a la caída.

Al dictar:

1. Se intenta el proveedor del modo.
2. Si falla —apagado, sin API key, sin modelo, error de red, respuesta vacía— **se reintenta con el proveedor global**.
3. Si el global también falla, sale el texto con el piso local aplicado, igual que hoy.
4. Si el paso 2 **cruzó de local a online**, se emite un evento que el frontend muestra como aviso: _"Código se procesó con Gemini porque Ollama no respondió"_.

El aviso es **después del hecho** por decisión explícita: el texto ya viajó, pero enterarse tarde es mejor que no enterarse.

### 3 · UI

En el panel de edición del modo (donde ya vive `ModeShortcutInput`), un bloque **"IA de este modo"**:

```
Código                                  ⌥⌘C
┌─ IA de este modo ───────────────────┐
│  [ General ]  [ Local ]  [ Online ] │
│                             ▔▔▔▔▔▔  │
│  Proveedor:  Google Gemini      ▾   │
│  Modelo:     gemini-2.5-flash   ▾   │
└─────────────────────────────────────┘
```

- **General** = `provider_id: None`. Muestra en gris cuál es el general, para que se sepa qué se está heredando.
- **Local** lista sólo proveedores con `is_local`; **Online**, el resto.
- Elegir un proveedor sin API key configurada muestra un aviso en línea con enlace a la pestaña de claves — no un error que trabe.

En Inicio, cada tarjeta de modo (`DictationModes`) lleva una etiqueta chica LOCAL u ONLINE: el vistazo que responde "¿cuáles de mis modos mandan texto afuera?".

## Alcance

**Entra:** §4 del spec anterior (proveedor y modelo por modo) más la distinción local/online que este documento agrega.

**No entra** — piezas independientes del spec del 2026-07-22, cada una con su propio trabajo: piso local con mayúsculas y puntuación, modo default, eliminación de `post_process_selected_prompt_id`, menú reordenado y recuperación del pegado. Meterlas juntas haría un cambio imposible de revisar.

**Tampoco entra:** Ollama como proveedor de primera clase (detección automática y listado de sus modelos) ni un LLM empotrado en Dilo. Ambos descartados en la conversación, el segundo además choca con "sin dependencias nuevas".

Va en rama propia desde `main`, fuera del worktree del notetaker.

## Restricciones transversales

- **Copy es-first**, autoral, tuteo chileno; claves en los 21 idiomas — `check:translations` bloquea el gate.
- **Offline-first intacto:** un modo sin proveedor propio se comporta exactamente como hoy.
- **Aditivo respecto de upstream:** campos nuevos con `serde(default)`, sin migración de settings.
- Sin dependencias nuevas.

## Verificación

**Tests (Rust):** resolución cuando hereda, cuando tiene proveedor propio, cuando apunta a uno borrado y cuando le falta el modelo; la caída al global; y que el cruce local→online sea el único caso que emite aviso.

**Visual:** preview en el navegador con el CSS real, claro y oscuro.

**En vivo (Alfonso):**

1. Modo Código con Gemini y modo Limpio con Apple Intelligence; dictar con los dos seguidos → cada uno llama al suyo.
2. Un modo sin proveedor propio sigue usando el general.
3. Modo Código apuntando a Ollama con Ollama apagado → el texto sale procesado por el general y aparece el aviso de que cruzó a la nube.
4. Las etiquetas LOCAL/ONLINE en Inicio coinciden con lo configurado en cada modo.

---

## Cambios durante la implementación (2026-07-29)

El diseño se implementó completo. Cuatro cosas se apartaron de lo escrito acá,
todas descubiertas por las revisiones de cada tarea:

1. **El guard de "proveedor sin modelo" hay que conservarlo explícitamente.**
   La caída al proveedor general, tal como estaba redactada en el plan, perdía
   una comprobación que ya existía en el código: los settings de fábrica
   insertan modelo vacío (`""`) para cada proveedor, así que un dictado podía
   terminar haciendo un POST con la transcripción a `api.openai.com` sin modelo
   ni clave — una llamada que antes no existía. La resolución del proveedor
   global corta ahora con `model.trim().is_empty()`.

2. **El "no reintentar el mismo proveedor" compara el par (proveedor, modelo),
   no sólo el id.** Un modo que apunta al mismo proveedor que el general pero
   con modelo propio distinto sí merece la caída: es una llamada distinta.

3. **Elegir un lado vacío no cambia el estado.** Si el usuario elige Local u
   Online y no hay ningún proveedor de ese tipo, el segmentado **no se mueve** y
   aparece un aviso (`emptySide`). Mover el control sin persistir nada dejaría
   la pantalla diciendo "Local" mientras el modo sigue enrutando a la nube —
   exactamente la confusión que este bloque existe para evitar. Por la misma
   razón, el segmentado sólo se mueve después de confirmar que el guardado no
   falló.

4. **`PostProcessOutcome.used_provider_id` no lo lee nadie.** Se definió en este
   diseño pensando en el historial, pero ningún consumidor lo usa todavía.
   Queda señalado para eliminarlo (YAGNI) o para darle uso cuando el historial
   registre con qué proveedor se procesó cada dictado.

**Pendiente conocido:** un modo local cuyo proveedor no resuelve (fue borrado o
quedó sin modelo) cae al general en la nube **sin mostrar el aviso**, porque
"era local" se deduce de la resolución, que en ese caso está vacía. Es
justamente uno de los casos que el aviso existe para cubrir; el arreglo es
deducirlo de `provider_id` del modo cuando la resolución falla.

## Cambios durante la ola de arreglos del review final (2026-07-30)

El pendiente de arriba, y otros tres hallazgos del review final antes de
mergear, se arreglaron en esta ola. Uno es una desviación del diseño que
conviene dejar anotada:

5. **El bloque "IA de este modo" no trae selector de modelo** — el diagrama
   de la sección 3 muestra `Modelo: gemini-2.5-flash ▾`, pero implementarlo de
   verdad necesita un flujo de listar modelos por proveedor que no entró en
   esta rama (es trabajo aparte). `LLMPrompt.model` existe en el backend
   (`set_post_process_prompt_provider` ya lo acepta) pero ninguna UI lo
   escribe todavía: siempre se guarda `null`. En vez de mostrar ese campo casi
   siempre vacío, el bloque ahora muestra el **modelo efectivo** con el que el
   modo va a correr — el propio si lo tuviera, si no el heredado de
   `post_process_models[provider_id]` — y no dibuja la línea si tampoco hay
   ninguno. El selector en sí queda pendiente para cuando exista ese flujo.

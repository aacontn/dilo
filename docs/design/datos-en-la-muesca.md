# Datos a los costados de la muesca

Pedido de Alfonso, 2026-09-23: «mostrar cosas más entretenidas de forma
permanente, alargar un poquito el notch y poner stats, como los consumos de IA
o los stats del computador […] y que todo sea personalizable». Y: «estaríamos
abarcando cosas que ya hay open source y que sería solamente una aplicación».

Este documento dice qué hay, cómo está armado y **cómo se suma un proveedor
más**. La referencia de todo esto es [CodexBar](https://github.com/steipete/CodexBar)
(MIT), que ya resolvió dónde deja su uso cada herramienta: se lee y se escribe
de nuevo en Swift, no se copia. El día que se adapte código suyo, la atribución
entra en el `LICENSE` antes que el código.

## Qué hay (v1)

| Dato | De dónde sale | Qué muestra | Permisos |
| --- | --- | --- | --- |
| Codex | `~/.codex/sessions/AAAA/MM/DD/rollout-*.jsonl`, último evento `token_count` con `rate_limits` | % de la ventana de 5 h (y semanal en el detalle) | Ninguno |
| Claude | `~/.claude/projects/**/*.jsonl`, bloques de 5 h al modo de `ccusage` | Tokens del bloque: entrada + salida + escritura de caché | Ninguno |
| Claude, % del plan (opcional) | `GET api.anthropic.com/api/oauth/usage` con la sesión de Claude Code del Llavero (`Claude Code-credentials`) | % de la ventana de 5 h | Diálogo del Llavero, una vez |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)`, diferencia entre dos lecturas | % de todo el sistema | Ninguno |
| RAM | `host_statistics64(HOST_VM_INFO64)`: activa + fija + comprimida | % de la memoria física | Ninguno |

En App Store el sandbox no deja leer `~/.claude` ni `~/.codex`: esas opciones
se esconden (`Capacidad.consumoDeIADeOtrasApps`) y quedan CPU y RAM.

## Cómo está armado

- **`DiloCore/Sources/DiloConsumo`** — lo que no sabe nada de la app y se
  prueba con `swift test`: `DatoDeLaMuesca` (qué se puede elegir),
  `VentanaDeUso` y `ConsumoDeIA` (qué se sabe de un proveedor), un lector por
  fuente (`LectorDeCodex`, `LectorDeClaude`, `ClienteDeUsoDeClaude`,
  `MuestraDelSistema`) y `TextoDelDato` (cómo se escribe).
- **`Dilo/CoreHUD/DatosDeLaMuesca.swift`** — la tarea que refresca: CPU y RAM
  cada 3 s, archivos cada 30 s, el plan de Claude cada 2 min. Sin datos
  elegidos no corre nada.
- **La geometría** — `HUDScreenSnapshot.anchoDeLosLados` alarga
  `reposoSize` a los dos lados por igual (`HUDNotchGeometry.anchoDeUnLado`),
  y con eso la ventana, la zona del mouse y la silueta quedan de acuerdo.
- **La vista** — `HUDMarcaDeReposo` dibuja cada costado: etiqueta apagada,
  valor claro, mango desde el 75 % y rojo desde el 90 %.

## La regla de las credenciales

Algunos proveedores sólo dicen su porcentaje a quien presenta la sesión del
usuario. Cuando Dilo la usa:

1. Es **opcional y apagado de fábrica**, con un texto en Ajustes que dice qué
   se lee y a quién se le pregunta.
2. Se lee **en cada consulta** y se suelta: no se guarda, no se registra, y
   sólo viaja al servidor que la emitió.
3. **Nunca se renueva** un token ajeno: dos apps renovando la misma sesión
   terminan cerrándosela a la otra. Si venció, se espera a que la herramienta
   dueña la renueve y mientras tanto se muestra el dato local.
4. Cookies del navegador, no. Es la fuente más frágil y la más invasiva.

## Cómo se suma un proveedor

1. Un caso nuevo en `DatoDeLaMuesca` (el `rawValue` es lo que se guarda: no
   se renombra después) y su `leeArchivosDeOtraApp`.
2. Un lector en `DiloConsumo` que devuelva `ConsumoDeIA`, con tests armados
   con la forma exacta del archivo o la respuesta. Nada de red ni de carpetas
   de verdad en los tests.
3. Su rama en `DatosDeLaMuesca.lado(_:)` y en `refrescar()`, con una cadencia
   que respete el reposo.
4. Su nombre en `AppearanceSettingsView.nombreDelDato`.
5. Si pide credencial, la regla de arriba entera.

## Candidatos, por orden de cuánto se usan

Lo que dice «según CodexBar» está leído de su documentación
(`docs/<proveedor>.md`) el 2026-09-23 y no se probó todavía desde Dilo.

| Proveedor | Fuente según CodexBar | Qué haría falta | Notas |
| --- | --- | --- | --- |
| **Gemini** | Sesión OAuth del CLI de Gemini (`~/.gemini/oauth_creds.json`) contra APIs de cuota privadas de Google | Tener el CLI de Gemini con sesión iniciada | En el Mac de Alfonso no hay sesión del CLI (2026-09-23): la app web de Gemini no deja nada en disco. Pendiente de que lo use |
| **Cursor** | Token de Cursor.app en su base SQLite (`cursorAuth/accessToken`) y APIs de cursor.com | Leer la base de Cursor; credencial ⇒ regla de arriba | |
| **GitHub Copilot** | Device flow de GitHub + API interna de uso de Copilot | Un inicio de sesión propio de Dilo con GitHub | Pide un flujo de OAuth nuevo |
| **OpenRouter** | Clave de API: créditos, tope y gasto (`/api/v1/credits`, `/key`) | Que la persona pegue su clave; guardarla en el Llavero de Dilo | API pública y documentada |
| **OpenAI API** (no ChatGPT) | Admin API: `/v1/organization/costs` y `/usage/completions` | Clave de administrador de la organización | Para cuentas de empresa |
| **Windsurf** | Caché SQLite local (`state.vscdb`) o la web | Leer su base local | Según CodexBar, el local se desactualiza cuando Windsurf está cerrado |
| **Ollama Cloud** | Clave de API o cookies de ollama.com | Clave de API | Las cuotas sólo por cookies |
| **Ollama local / LM Studio** | Su servidor local (`localhost`) | Nada | No es consumo sino qué modelo está cargado; podría ser un dato «Modelo local» |

Otros que CodexBar cubre y quedan para después: Perplexity, Grok (xAI),
Mistral, DeepSeek, Kimi, z.ai, Factory, Amp, Warp, Kiro, Vertex AI, Bedrock.

## Lo que falta en v1

- El **detalle en el hover**: cuándo se reinicia cada ventana y la semanal.
  Los datos ya están en `ConsumoDeIA`; falta darle lugar en el panel.
- Las **traducciones al inglés** de los textos nuevos de Ajustes.

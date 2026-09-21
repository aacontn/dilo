# Contribuir a Dilo

Dilo es una app de dictado en español que vive en la barra de menús, para
macOS 26 en Apple Silicon. La mantiene una persona en su tiempo libre. Esta
guía es el contrato para todo el que escriba código acá, humano o agente.
`AGENTS.md` y `CLAUDE.md` apuntan a este archivo y este gana sobre los dos.

Lee [`CONTEXT.md`](CONTEXT.md) antes de escribir nada. Es el modelo de dominio
y el reglamento, su vocabulario es vinculante, y casi todo comentario de
revisión acá es alguna versión de "eso no es lo que dice CONTEXT.md".

## Mira alrededor primero

La única regla que cubre todo lo que este archivo detalla. Antes de cambiar
algo, lee el código de al lado. Copia los nombres, la densidad de comentarios,
el tamaño de los archivos, el estilo de los tests y la forma en que se anotan
las decisiones. Un parche que discute con el código que lo rodea es un parche
que se devuelve, aunque esté correcto.

## Antes de escribir código

**Abre un issue primero.** Los issues de
[aacontn/dilo](https://github.com/aacontn/dilo/issues) son el canal: bugs,
funcionalidades y preguntas empiezan ahí.

Un pull request implementa un issue. Uno que llega sin issue detrás puede
cerrarse o quedarse parado, por bueno que sea el código. No es burocracia: el
diseño se discute en el issue, donde cambiar de opinión es barato, y un pull
request es un mal lugar para descubrir que la funcionalidad no se quería.

### Qué necesita un reporte de bug

Dilo se apoya en el servidor de ventanas, la API de Accesibilidad y un tap
global de eventos, así que "no funcionó" nunca alcanza. Incluye:

- Versión de macOS y modelo de Mac, y si la pantalla tiene notch físico
- Versión de Dilo, desde el menú de la barra
- Qué gatillo usaste y si fue sostenido o un toque corto
- En qué aplicación dictabas
- Qué esperabas y qué pasó en cambio
- Una grabación de pantalla, para cualquier cosa del HUD, su animación o dónde
  se dibuja
- La salida de Consola filtrada por Dilo, para un cuelgue o un crash

### Qué necesita una propuesta

- El caso que quieres resolver, no la solución que tienes en mente
- Cómo lo resuelves hoy
- Qué hacen otras apps de dictado ahí, si hacen algo
- Qué términos de `CONTEXT.md` toca, o que necesita uno nuevo

Una propuesta que contradice una decisión de `docs/adr/` o una regla de
`CONTEXT.md` tiene que discutir con esa decisión explícitamente. Ver
[Decisiones ya tomadas](#decisiones-ya-tomadas).

## Uso de IA

Dilo se construye con ayuda de IA y la recibe bien. Las reglas son sobre
comprensión, no sobre herramientas.

**Dilo en el pull request.** Qué herramienta usaste y cuánto del trabajo hizo.
Una línea basta.

**Entiende lo que mandas.** Tienes que poder explicar cada línea de tu cambio,
por qué está escrita así y qué pasa en sus bordes. Usa IA para entender código,
para aprender, para lo que quieras; lo que no se puede es mandar código que no
entiendes, porque alguien va a tener que mantenerlo. Si un revisor pregunta por
qué está esa guarda y la respuesta honesta es "la puso el agente", el cambio no
está listo.

**Sólo texto y código.** Nada de imágenes, íconos, audio ni video generados.

**Córrelo.** Un cambio en el dictado, el HUD, la inserción o la lectura en voz
alta tiene que haberse usado en un Mac de verdad, no sólo compilado. Di en el
pull request qué probaste y en qué hardware. Si no puedes probar un camino, di
cuál y por qué.

## Compilar y probar

Necesitas macOS 26 en Apple Silicon, y Xcode.

```bash
git clone https://github.com/aacontn/dilo.git
cd dilo/mac
open Dilo.xcodeproj   # ⌘R
```

Sin abrir Xcode, que es lo que corre CI:

```bash
cd DiloCore && swift test
xcodebuild -project Dilo.xcodeproj -scheme Dilo -configuration Debug build
xcodebuild -project Dilo.xcodeproj -scheme Dilo-MAS -configuration Debug build
xcodebuild test -project Dilo.xcodeproj -scheme Dilo -destination 'platform=macOS'
```

Todo eso tiene que pasar antes de abrir un pull request. Cuatro tests de medios
se saltan sin sus archivos de prueba; es lo esperado y pasa igual en `main`.
DerivedData va a `/Volumes/SSD2/derived-data`, nunca al disco interno.

Dilo necesita permiso de Micrófono, Reconocimiento de voz y Accesibilidad para
correr. Un build de depuración pide los suyos, aparte de los de una copia
publicada. El target `Dilo-MAS` se prueba con `open -a`, **nunca** lanzando el
binario desde el terminal: TCC le atribuye los permisos al proceso padre y el
audio llega en silencio.

## Estilo

Esto son reglas, no preferencias.

- **Dos espacios de indentación.** En todo: Swift, Metal, JSON, YAML. Ancho 2,
  tabulación 2, espacios y no tabs. Es lo que dice el `.editorconfig`
  versionado. Nunca reformatees un archivo de vuelta a cuatro espacios.
- **Nada de comentarios `// MARK:`.** Un archivo que necesita separadores es un
  archivo que necesita partirse. Usa tipos chicos y archivos aparte.
- **Usa el vocabulario de `CONTEXT.md`.** Lista el término que va y los que hay
  que evitar. Aplica a identificadores, comentarios, mensajes de commit y copy.
- **Comenta el porqué, no el qué.** Los comentarios de este código explican la
  razón por la que una línea sobrevivió la revisión: qué carrera cierra, qué
  comportamiento de la plataforma la obligó. En español.
- **Superficie chica.** Ninguna abstracción para un solo llamador, ninguna
  configuración que nadie pidió, ningún manejo de errores para estados que no
  pueden pasar.

### Tests

Los tests de la app van junto a sus pares en `DiloTests/`; los del paquete
propio, en `DiloCore/Tests/`. Se nombran por el comportamiento y no por la
función: `releasingRightOptionWhileLeftIsHeldReadsAsUp`, no `testFlags`.

Prueba las costuras puras. `DictationSessionMachine`, `HUDPlacement`,
`HUDNotchGeometry`, `UsageMetrics`, `KeyboardMap` y lo que vive en `DiloCore/`
son puros a propósito, para poder fijar sus reglas sin micrófono ni ventana.
Cuando un bug resulta vivir en código impuro, el arreglo casi siempre es mover
la regla a un value type y testear eso.

Un arreglo de bug viene con un test que falla antes.

## Ramas

Nombra la rama `tipo/descripción-corta`, en minúsculas, con guiones:

```
feature/drop-transcription
fix/el-drop-target-se-queda-pegado
docs/drop-transcription-en-el-readme
chore/dmg-con-version
```

El tipo es uno de seis. Es la misma palabra que la etiqueta del título del pull
request, así rama y PR siempre concuerdan:

| Prefijo de rama | Etiqueta del PR | Para |
| --- | --- | --- |
| `feature/` | `[FEATURE]` | Comportamiento nuevo que alguien ve |
| `fix/` | `[FIX]` | Un bug, un crash, una carrera, un test inestable |
| `refactor/` | `[REFACTOR]` | Cambia la forma, conserva el comportamiento |
| `docs/` | `[DOCS]` | Documentación y comentarios nada más |
| `test/` | `[TEST]` | Sólo tests |
| `chore/` | `[CHORE]` | Build, CI, release, herramientas, dependencias |

Describe el cambio, no el ticket: `fix/la-pildora-tiembla-al-aparecer`, nunca
`fix/issue-42`. Nada de `bugfix/`, y nada de dejar el nombre por defecto de tu
herramienta (`agent/...`, `codex/...`). Se trabaja en una rama, nunca en `main`.

## Pull requests

**Titúlalo `[ETIQUETA] Qué hace el cambio`**, con la etiqueta de la tabla:

```
[FEATURE] Permitir que los botones del mouse disparen el dictado
[FIX] Mantener abierto el drop target mientras el puntero sigue encima
[DOCS] Poner Transcripción por arrastre en el README
```

Una etiqueta, entre corchetes, en mayúsculas, adelante. Después, el cambio en
imperativo, una frase sin punto final. El título sobrevive al merge como
asunto del commit en `main`: escríbelo para alguien que lea `git log` en un año.

**Enlaza el issue en el cuerpo**, en su propia línea al final: `Closes #42`
cuando el merge debe cerrarlo, que es lo normal, o `Refs #42` cuando se
relaciona pero no lo termina.

**Las descripciones son chicas y concretas.** Unas frases que contesten qué,
cómo y por qué. Nada más: ni viñetas, ni títulos, ni sección de plan de
pruebas, ni resumen del diff.

**Un pull request, un asunto.** Las limpiezas sueltas van en el suyo. Si ves
código muerto mientras trabajas, dilo en el issue en vez de borrarlo de paso.

**No reformatees código que no estás cambiando.** Un diff donde cada línea
tocada se explica por el propósito declarado es un diff que se puede revisar.

## Commits y merge

**Los mensajes de commit** van en español, en imperativo, y explican el porqué
—el diff ya dice el qué—. No llevan `[ETIQUETA]`: esa es del título del PR.
Mira `git log` antes de escribir uno.

- **Squash por defecto.** Una rama que iteró —prototipos, arreglos de revisión,
  un merge de otra rama— se convierte en un commit en `main`.
- **Rebase sólo cuando los commits ya son atómicos**, es decir, cada uno
  compila, pasa y es un cambio que alguien querría tener solo. La prueba es
  `git bisect`.
- En los dos casos `main` queda lineal.

## Decisiones ya tomadas

Están cerradas. Reabrir una necesita un argumento nuevo, no una preferencia:

- Un `Dilo.xcodeproj` versionado y a secas. Ni Tuist, ni generación de proyecto
- Swift 6, concurrencia estricta completa
- **Dos targets desde el día uno:** `Dilo` (venta directa, con Sparkle) y
  `Dilo-MAS` (App Sandbox, sin Sparkle). Los bundle ids y las claves de
  `UserDefaults` no se renombran: romperían las preferencias de quien ya tiene
  la app
- AppKit es el caparazón: ciclo de vida, status item, paneles que no activan.
  SwiftUI dibuja la UI con ventana adentro
- Model-View con reducers locales puros. Ni MVVM, ni TCA, ni store global
  (`docs/adr/0005-mv-with-local-reducers.md`)
- Todo el copy visible se escribe en español, de autoría propia; el inglés se
  traduce desde ahí
- Dos dependencias de terceros: Sparkle, encerrada en `Dilo/Updates/`, y
  FluidAudio para el motor Parakeet. Agregar una tercera es una decisión que se
  plantea, no una que se toma en un pull request

Las decisiones de arquitectura viven en [`docs/adr/`](docs/adr/). Si tu cambio
contradice una, dilo en el issue y di por qué vale la pena reabrirla. Si tu
cambio toma una decisión de ese tamaño, agrega un ADR al lado.

## Licencia

Dilo es [MIT](LICENSE). Abrir un pull request licencia tu contribución bajo los
mismos términos y permite que el mantenedor la modifique. De dónde viene el
código que Dilo ya traía cuando nació está en
[`docs/historia/`](docs/historia/README.md).

## Trabajar como agente o con uno

`AGENTS.md` —y `CLAUDE.md`, su copia byte a byte— orientan a un agente en este
código: el mapa de módulos, las trampas que siguen mordiendo, hacia dónde va la
cosa. Nombran este archivo como vinculante y no lo repiten, salvo cuatro reglas
que se reescriben allá porque son las que los agentes rompen más.

Las convenciones propias del repo para agentes están en
[`docs/agents/`](docs/agents/): cómo se usa el tracker de issues, qué significa
cada etiqueta de triage y cómo se leen los documentos de dominio.

Todo lo de arriba aplica al trabajo que un agente hizo por ti. Tú abriste el
pull request: es tuyo explicarlo.

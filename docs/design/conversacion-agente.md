# La Conversación como agente: agentes con nombre, herramientas y voz

2026-10-30. Alfonso, al probar la Conversación: «esta lejos de ser agente, no
tiene tool calling ni se conecta a mis agentes […] la idea es que sea la
interfaz de voz de las cosas que pueda hacer». Y después: «ponerle nombres a
diferente gente, incluyendo a Dilo, tener una wake word y escuchar, además del
atajo […] si te digo "revisa Claude Code", la puede abrir y controlar esa
sesión por voz desde Dilo». Referencia: el modo hablado de Codex.

Es la idea escrita en `Dilo/app/docs/superpowers/specs/2026-07-22-dilo-plataforma-conversacional-abierta.md`:
**Dilo posee la experiencia de voz; las capacidades son conexiones que elige
la persona.**

> **Cambio del 2026-10-30, tras la prueba de la 0.11.1.** Alfonso: «no sirve para
> un agente de voz real como el de ChatGPT». Pasar a Claude Code dejaba hablando
> un filtro sin modelo. Ahora hay una sola voz: Kami se queda, Claude Code corre
> por detrás como encargo, y se le puede hablar encima. Donde esto contradiga lo
> de abajo, manda `AGENTS.md`, «Conversación».

## Agentes con nombre

Un **Agente** es un nombre y un destino (`Agente`, `DestinoDeConversacion`
en `DiloModes`). De fábrica:

| Nombre | Destino | Qué hace |
| --- | --- | --- |
| **Dilo** | Claude por la API con las herramientas de Dilo y los MCP conectados | lo cotidiano: dictados, reuniones, calendario, notas, portapapeles, abrir apps |
| **Claude Code** | una sesión de Claude Code en una carpeta | tareas de código, manejadas por voz |
| **Switchboard** | el MCP de Switchboard | clientes, memoria, calendario, trabajos |

Se renombran y se agregan en **Ajustes → Conversación → Agentes**. A quién se
le habla:

- Por su nombre al principio de lo dicho: «Switchboard, ¿qué tengo hoy?».
  `EnrutadorDeAgentes` (puro) separa el nombre del resto, sin tildes ni
  mayúsculas y con lo que Parakeet suele oír mal («cloud code»).
- Por el menú de destino de la barra de llamada.
- Sin nombre ni elección, el último al que le hablaste en esa llamada, y si no,
  Dilo.
- «Revisa Claude Code», «abre Claude Code», «pásame con Switchboard» cambian
  de destino sin mandar nada.

## Herramientas y MCP (destino Dilo)

- **Tool calling** con la API de Anthropic, en streaming, con el router de
  modelos de siempre.
- **Herramientas propias**, de sólo lectura salvo las marcadas: dictados y
  reuniones (las de `HerramientasDeDilo`), el guion de una reunión, el
  calendario de hoy, el portapapeles, Tus palabras; con aprobación: crear una
  nota, copiar al portapapeles, abrir una app o una URL.
- **Cliente MCP** por stdio para los servidores que la persona conecta en
  Ajustes (comando y argumentos). Switchboard es el primero. Dilo **no lee**
  `~/.claude` ni `~/.codex` para descubrirlos.
- Cada herramienta se declara de lectura o de escritura. **Las de escritura
  siempre piden un clic** (`Aprobacion`); la voz nunca aprueba.

## Claude Code por voz

- Dilo abre o retoma una sesión de Claude Code en el proyecto nombrado («Claude
  Code, en Dilo, revisa los tests») por la puerta oficial: la CLI `claude` en
  modo de control por programa (`--print` con `--input-format` y
  `--output-format` `stream-json`, `--resume` para retomar). Lo que sale se
  resume para la voz; el detalle va a la transcripción.
- Los permisos que pide Claude Code llegan como `Aprobacion` y se deciden con
  un clic en la muesca.
- Usa la cuenta de Claude Code de la persona, no la clave de la API.
- Dilo no lee los archivos de sesiones por su cuenta: qué sesiones hay se le
  pregunta a la CLI.

## Escucha de nombres (wake word)

- Opcional y **apagada de fábrica** (Ajustes → Conversación → «Escuchar mi
  nombre»). El atajo sigue igual.
- Con ella prendida el micrófono queda abierto y macOS muestra el punto
  naranja; lo que se oye vive en un búfer de RAM de pocos segundos que se pisa
  solo, **nunca va a disco ni sale del Mac**, y no pasa por el historial.
- Es la excepción declarada al ~0 % de CPU en reposo, sólo con la escucha
  prendida: se mide y se dice en Ajustes cuánto gasta.
- Escucha los nombres de los agentes que tienen «Se llama por nombre». De
  fábrica sólo «Dilo».
- Al oír un nombre abre la Conversación con ese agente y lo que siguió al
  nombre es el primer turno.

## Lo que no se hace

- La voz no aprueba nada sensible.
- Nada de leer archivos de otros agentes para espiarlos.
- Nada de mandar audio a la nube: sólo viaja texto, y sólo a los destinos
  elegidos.

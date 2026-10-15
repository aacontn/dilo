# Agentes en la muesca, el URL scheme y los App Intents

Fase 5 del plan (pasos 1 y 2), 2026-10-15. Dos puertas para que lo que no es
Dilo le hable a Dilo, cada una con su regla:

| Puerta | Quién la usa | Qué puede hacer | Por qué ésa |
| --- | --- | --- | --- |
| **URL scheme** `dilo://agente?…` | el *hook* de un agente de código | **sólo mostrar** un segmento al costado de la muesca, que se quita con un clic | una URL la abre cualquiera, también una página web |
| **App Intents** | Atajos, Spotlight, Siri, `shortcuts run` | dictar, dictar una nota, elegir el modo, copiar o leer lo último, transcribir un archivo, buscar en el historial, mostrar un aviso | un atajo lo arma la persona; nada lo dispara desde una página |

Lo que abre el micrófono, cambia Ajustes o toca el portapapeles **nunca**
entra por URL. `EnlaceDeDilo` rechaza cualquier ruta que no sea `agente`, y
hay un test por cada una que alguien podría querer agregar (`dictar`, `nota`,
`copiar`, `modo`, `muesca`). Si un día hace falta, va por un intent.

## Agentes: el agente avisa, Dilo no espía

Otras islas de notch siguen a los agentes **leyendo lo que escriben en
disco** (los JSONL de `~/.claude`, los rollouts de Codex, la base SQLite de
Cursor) y sacan los límites del plan con el token de cada CLI. Dilo no: la
persona pega una línea en la configuración de su agente, el agente corre
`dilo-agente.sh` en cada evento y el script abre
`dilo://agente?de=claude&fase=espera&proyecto=dilo-mac`. Dilo no abre un
archivo ajeno ni toca una credencial para esto.

### La URL

```
dilo://agente?de=<agente>&fase=<fase>&proyecto=<carpeta>
```

- `de`: `claude`, `codex`, `cursor`, `cowork`. Cualquier otro se muestra como
  «Agente».
- `fase`: `trabajando` (prioridad baja), `espera` (alta: un permiso, una
  pregunta), `listo` y `error` (normal), `fin` (retira).
- `proyecto`: el **nombre** de la carpeta, nunca la ruta, el prompt ni la
  herramienta: una URL abierta con `open` queda en el registro de
  LaunchServices. Se limpia a letras, números y `-_. `, 32 caracteres.

Una URL que no se entiende no hace nada y queda en el log con el motivo:

```bash
log show --predicate 'subsystem == "cl.espaciodigital.dilo" && category == "plataforma"' --last 10m
```

### Cuánto dura cada cosa (`RegistroDeAgentes`)

- `listo` se va a los 30 s; `error`, a los 2 min.
- Sin noticias en 15 min, la sesión se olvida (la terminal se cerró y el
  `fin` nunca llegó).
- La misma fase otra vez sólo estira el plazo: no vuelve a sentar el segmento.
- Un agente en una carpeta es una sesión: dos proyectos son dos segmentos.
- A lo más 8 sesiones; con una novena se va la más vieja.
- Un clic en el segmento lo quita; si el agente vuelve a avisar, vuelve.

Dilo no sondea: duerme hasta el próximo vencimiento.

### En la muesca

Cada sesión es un segmento al costado (`AsientosDeLaMuesca`, nunca la forma
entera): el nombre del agente como palabra y la fase en el ícono —
`ellipsis.circle` trabajando, `hand.raised.fill` en el acento cuando te
espera, `checkmark.circle` listo, `exclamationmark.triangle` error—. La frase
entera con el proyecto va en el tooltip y en VoiceOver. «Claude te espera» no
cabe en los 100 puntos de un segmento.

## Cómo se engancha cada agente

Ajustes → **Datos en la muesca** → tarjeta **Agentes** muestra las líneas con
la ruta del script de la copia instalada y un «Copiar». Dilo **no las
escribe** en `~/.claude` ni en `~/.codex`: la configuración de otra
herramienta es de la persona. Con Dilo en `/Applications`:

### Claude Code

En `~/.claude/settings.json` (o el `.claude/settings.json` de un proyecto),
dentro del objeto de más afuera:

```json
"hooks" : {
  "Notification" : [ { "hooks" : [ { "command" : "sh '/Applications/Dilo.app/Contents/Resources/dilo-agente.sh' claude espera", "type" : "command" } ] } ],
  "PostToolUse" : [ { "hooks" : [ { "command" : "sh '/Applications/Dilo.app/Contents/Resources/dilo-agente.sh' claude trabajando", "type" : "command" } ] } ],
  "SessionEnd" : [ { "hooks" : [ { "command" : "sh '/Applications/Dilo.app/Contents/Resources/dilo-agente.sh' claude fin", "type" : "command" } ] } ],
  "Stop" : [ { "hooks" : [ { "command" : "sh '/Applications/Dilo.app/Contents/Resources/dilo-agente.sh' claude listo", "type" : "command" } ] } ],
  "UserPromptSubmit" : [ { "hooks" : [ { "command" : "sh '/Applications/Dilo.app/Contents/Resources/dilo-agente.sh' claude trabajando", "type" : "command" } ] } ]
}
```

`PostToolUse` está para que «te espera» vuelva a «trabajando» después de dar
un permiso; sin él se quedaba puesto hasta el `Stop`. Es un aviso por
herramienta, pero el script se va al fondo y no frena a Claude.

**Sin verificar contra la versión vigente:** `Notification` también llega
cuando Claude lleva un rato esperando tu siguiente mensaje, y entonces el
segmento dice «te espera» después de un «listo». Si molesta, Claude Code
acepta un `matcher` por tipo de notificación en versiones recientes; no se
puso porque no está probado.

### Codex

En `~/.codex/config.toml`:

```toml
notify = ["sh", "/Applications/Dilo.app/Contents/Resources/dilo-agente.sh", "codex", "listo"]
```

Codex llama a `notify` sólo al terminar cada turno, así que de Codex se ve
«listo» y nada más. Le agrega un JSON con la conversación como último
argumento; el script lo ignora entero.

### Cursor, Cowork y otros

Cursor tiene *hooks* propios (`hooks.json`); la línea sería
`sh '…/dilo-agente.sh' cursor listo` en su evento de fin, **sin verificar**
su formato. Cowork no tiene *hooks* conocidos: lo que hace Droppy —vigilar
`local-agent-mode-sessions` con FSEvents— es leer archivos de otra app y no
se hizo. Cualquier otra herramienta que pueda correr un comando sirve con
`sh '…/dilo-agente.sh' <nombre> <fase>`.

### El script (`Dilo/Resources/dilo-agente.sh`)

Viaja dentro del `.app`. Lo que hace y lo que no:

- Codifica el nombre de la carpeta byte a byte (espacios, tildes, `&`), sin
  python ni jq.
- Toma la carpeta de `DILO_PROYECTO`, si no de `CLAUDE_PROJECT_DIR`, si no de
  la actual.
- **No abre Dilo si no está corriendo** (`pgrep -x Dilo`).
- Manda la URL por bundle id (`open -g -b cl.espaciodigital.dilo`), no a
  «quien tenga el esquema»: cada build de Debug y cada corrida de los tests
  registra `dilo://` en LaunchServices, y sin el id una URL podía lanzar una
  copia vieja de DerivedData. `DILO_ID` cambia el id para una copia de prueba.
- Nunca falla ni imprime: un *hook* que sale con error o escribe algo le
  cambia el comportamiento al agente.
- `DILO_SOLO_IMPRIMIR=1` imprime la URL y no abre nada: así lo prueban los
  tests de `DiloPlataforma`.

Para probar a mano desde una terminal, con Dilo abierto:

```bash
DILO_PROYECTO=prueba sh /Applications/Dilo.app/Contents/Resources/dilo-agente.sh claude espera
```

o el botón «Probar» de la tarjeta, que no pasa por LaunchServices.

### Lo que no se hizo, a propósito

- Leer los JSONL, los rollouts o la base de Cursor (el plan, «Lo que no se
  hace»).
- Los límites del plan por los agentes: el % de Claude sigue como estaba
  (opcional, `datos-en-la-muesca.md`), y no se lee el token de Cursor ni se
  lanza `security`.
- Instalar los *hooks* solo.

## App Intents (`Dilo/Atajos/`)

| Intent | Qué hace | Devuelve | En Siri/Spotlight |
| --- | --- | --- | --- |
| Dictar (`DictarIntent`) | empieza un dictado trabado donde está el cursor, o termina el que está en curso. Parámetro opcional `modo`: vacío es el del atajo general, «Sin modo» dicta como se dijo | — | «Dictar con Dilo», «Dictar con Dilo en Correo» |
| Dictar una nota | la nota rápida a Apple Notas | — | «Dictar una nota con Dilo» |
| Elegir el modo de Dilo | el modo del atajo general, como el panel del hover; «Sin modo» incluido | un diálogo | «Usar Correo en Dilo» |
| Último dictado | lo último que dictaste (lo pegado o lo dicho) | texto | sólo en Atajos |
| Copiar el último dictado | lo mismo que el ítem del menú | texto | «Copiar el último dictado de Dilo» |
| Transcribir un archivo | un audio o video, en este Mac, idioma principal | texto | «Transcribir un archivo con Dilo» |
| Buscar en el historial de Dilo | dictados guardados, del más nuevo; sólo con el historial encendido | lista de textos | «Buscar en el historial de Dilo» |
| Mostrar en la muesca | un aviso corto al costado por 1–120 s; un clic lo quita | — | sólo en Atajos |

Todos corren con `supportedModes = .background`: Dilo vive en la barra y
traerlo al frente le robaría el foco a la app donde vas a pegar. Ninguno
tiene lógica propia: `EjecucionDeAtajos` (con tests y un doble de la app)
llama a `AccionesDeDiloEnVivo`, que llama a lo mismo que el menú de la barra
y el panel del hover. `PuenteDeAtajos.actual` lo llena `AppDelegate` al
arrancar; un intent que llega antes dice «Dilo todavía está arrancando».

Desde un script, con un atajo «Avisar en la muesca» armado en la app Atajos
(la entrada del atajo conectada al texto de «Mostrar en la muesca»):

```bash
echo "Compilación lista" | shortcuts run "Avisar en la muesca" --input-path -
```

El inglés de las frases vive en `Dilo/AppShortcuts.xcstrings`; el de los
títulos, descripciones y errores, en `Localizable.xcstrings`.

## Cómo se mira sin un agente

- En PNG, sin abrir nada: `scripts/render-muesca.sh` deja
  `c2/reposo-agente-espera-*.png` y `c2/reposo-dos-agentes-*.png`.
- En la pantalla, con un Debug abierto: `scripts/muesca.sh mostrar
  agente-esperando` (el arnés, `EscenaDeMuestra`).

## Lo que sólo se prueba a mano

- Que Atajos muestre las ocho acciones en español y Spotlight las frases.
- Que «Dictar» desde Spotlight o Siri pegue en la app de antes y no en
  Spotlight: el foco se toma al empezar la sesión.
- Que Siri entienda «Dictar con Dilo» en es-CL.
- Que una URL `dilo://` llegue a la copia instalada y no a una de DerivedData
  (`lsregister -dump | grep -B2 'dilo:'` dice quién la tiene registrada).
- Los *hooks* de verdad en Claude Code y Codex.

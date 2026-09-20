<p align="center">
  <img src="brand/dilo-icon.svg" width="96" alt="Ícono de Dilo" />
</p>

<h1 align="center">Dilo</h1>

<h3 align="center">Dictado en español para Mac, rápido y sin que nada salga de tu compu</h3>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" />
  <img src="https://img.shields.io/badge/macOS-26+-blue.svg" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-lightgrey.svg" />
  <img src="https://img.shields.io/badge/licencia-MIT-green.svg" />
</p>

Aprieta, habla, suelta. Aparece escrito donde tengas el cursor.

> **Dilo es un fork con cariño de [Talkify](https://github.com/tornikegomareli/Talkify)
> (Tornike Gomareli, MIT).** El HUD del notch, la máquina de sesión y el tap de
> teclado vienen de ahí, y son buenos. Dilo agrega lo que a un dictado en
> español le faltaba: la voz, las muletillas, tus palabras, los modos con su
> propio atajo y proveedor, y una píldora que no tapa la barra de menús.

Dilo también existe como app multiplataforma en Tauri
(`/Volumes/SSD 1/Dilo/app`), **congelada en 0.3.2**. Esta es la versión nativa
de Mac, que continúa la numeración desde 0.4.0.

## Privacidad

Todo pasa en tu compu: `SpeechAnalyzer`/`SpeechTranscriber` de Apple para
reconocer, `AVSpeechSynthesizer` para leer en voz alta, `Translation` para
traducir y `FoundationModels` para transformar. Ese último es un modelo de
lenguaje, es de Apple, y corre acá: no hay key, no hay cuenta, no hay request.
Dilo no guarda audio y no manda nada a ningún lado.

Dos advertencias honestas:

- El texto dictado se **pega**, así que pasa por el portapapeles del sistema
  por medio segundo antes de que Dilo devuelva lo que tenías copiado. Un
  gestor de portapapeles o el Portapapeles Universal pueden verlo en esa
  ventana.
- Los **modos con proveedor en línea** (OpenAI, Gemini, Anthropic) mandan el
  texto ya transcrito a ese tercero. La tarjeta lo dice: **LOCAL** o **EN
  LÍNEA**, siempre. El dictado normal nunca sale de acá.

## Qué necesitas

- macOS 26 (Tahoe) o superior, en Apple Silicon. No hay binario Intel: para
  eso está el Tauri 0.3.2, congelado.

## Compilar

DerivedData va al disco de taller, nunca al interno:

```bash
git clone <este repo> && cd mac
open Talkify.xcodeproj                        # ⌘R

# o sin abrir Xcode
xcodebuild -project Talkify.xcodeproj -scheme Dilo -configuration Debug \
  -derivedDataPath /Volumes/SSD2/derived-data build

# el paquete propio
cd DiloCore && swift test
```

Hay **dos targets** desde el primer día:

| Target | Bundle | Para qué |
| --- | --- | --- |
| `Dilo` | `cl.espaciodigital.dilo` | venta directa, con updater (Sparkle) |
| `Dilo-MAS` | `cl.espaciodigital.dilo.mas` | App Sandbox, sin Sparkle, para App Store |

El sandbox no rompe la compilación: lo que se cae, se cae en ejecución. Por eso
el target MAS se prueba con `open -a Dilo-MAS.app` y **nunca** lanzando el
binario desde el terminal — TCC le atribuye los permisos al proceso padre y el
audio llega en silencio.

## Cómo se usa

| Qué quieres | Cómo |
| --- | --- |
| Dictar | Mantén **fn**, habla, suelta |
| Dictar sin sostener | Toque corto a **fn**, habla, otro toque para terminar |
| Cancelar a media frase | **Esc** |
| Transcribir un archivo | Arrastra el audio o el video al notch y suéltalo |
| Leer en voz alta lo seleccionado | **⌥ ⎋** |
| Todo lo demás | El fantasma de la barra de menús → Ajustes |

Los gatillos se reconfiguran en **Ajustes → Atajos**. Regla de la casa:
**ningún gatillo por defecto escribe símbolos** en teclado latino. Nada de ⌥
derecha sola — en ISO-LatAm es AltGr y escribe `@ # \ | { } [ ]`. El segundo
idioma viene apagado.

Dilo **nunca toca el volumen maestro**. Si algún día se silencia la música al
dictar, se pausa la reproducción.

## Arquitectura

El árbol que viene de Talkify conserva su nombre de carpeta a propósito, para
que `git merge upstream/main` siga siendo barato:

- `Talkify/App/` — raíz de composición, ajustes persistidos, status item
- `Talkify/Input/` — el tap global de teclado y los atajos grabados
- `Talkify/Dictation/` — la máquina de sesión (un reducer puro con tests), los
  servicios de voz e inserción, y el HUD que sólo el dictado dibuja
- `Talkify/CoreHUD/` — lo que comparten todas las features: el panel único, la
  geometría y los shaders de Metal
- `Talkify/DropTranscription/`, `Translation/`, `ReadAloud/`, `Settings/`,
  `Insights/`, `Updates/`

Y todo lo de Dilo vive aparte, en un Swift Package local:

- `DiloCore/Sources/DiloText/` — español: muletillas, tus palabras
- `DiloCore/Sources/DiloEngines/` — el contrato `SpeechEngine` y sus motores
- `DiloCore/Sources/DiloModes/` — modos, proveedores y el `Decider`
- `DiloCore/Sources/DiloCapabilities/` — `HostCapabilities` completa y sandbox
- `DiloCore/Sources/DiloMetrics/` — los números del spec, medidos

`CONTEXT.md` es el modelo de dominio, `AGENTS.md` es el contrato de trabajo, la
dirección está en `docs/superpowers/specs/` y las decisiones heredadas en
`docs/adr/`.

## Licencia

[MIT](LICENSE). El copyright de Tornike Gomareli se conserva intacto y el de
Dilo se agrega al lado, igual que se hizo con Handy en el repo Tauri.

Dos activos heredados **no son publicables** y hay que reemplazarlos antes de
cualquier release: el set de sonidos Pop (CC-BY-NC, `LICENSE-SOUNDS.txt`) y la
obra del orbe Siri (`LICENSE-ARTWORK.txt`).

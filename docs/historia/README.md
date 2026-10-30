# De dónde viene este código

Dilo Mac no se escribió desde cero. El árbol de la app —el HUD del notch, la
máquina de sesión del dictado y el tap global de teclado— viene de **Talkify**,
de Tornike Gomareli, MIT: <https://github.com/tornikegomareli/Talkify>.

Y el producto viene de **Handy**, de CJ Pais, MIT:
<https://github.com/cjpais/Handy>. De ahí salieron los specs que el Dilo de
Tauri implementó y que esta app reescribió en Swift.

Esta nota es **el único lugar del repo donde esos nombres aparecen fuera de
donde la licencia los pide**, y es a propósito:

- El copyright de los dos se conserva en `LICENSE`, junto al de Dilo, y la app
  los nombra en **Ajustes → Acerca de → Licencias de terceros**. Eso es lo que
  la licencia MIT pide y ahí es donde se cumple, una sola vez en cada lado.
- Dilo se presenta como **producto propio**: no se anuncia como fork ni en la
  portada del README ni en la app. Quien quiera la genealogía completa, la
  tiene acá.
- Los documentos de diseño fechados de `docs/superpowers/` dicen «el árbol de
  origen» o «la app de origen». Son este proyecto: se dejaron sin el nombre
  para no repetir la atribución en cada archivo, no para esconder nada.

Lo que estuvo archivado acá y ya no está: el `CONTEXT.md` de Talkify 0.8.3 y
sus notas de versión de la 0.6.0 a la 0.8.3. Son documentos de ese repo, siguen
publicados ahí, y tener una copia congelada sólo garantizaba que envejeciera
mal. El `CONTEXT.md` de la raíz dice lo que de todo aquello sigue siendo cierto
para Dilo.

## Piezas adaptadas de otros proyectos

Además del árbol de origen, hay código chico adaptado de tres proyectos MIT,
con su copyright en `LICENSE` y su nombre en Acerca de:

- **imnotpayingforwisprflow**, de Yosef Shammout (MIT): el recorte de
  silencio en los bordes de una toma (`DiloEngines/RecorteDeBordes.swift`,
  portado de `Native/audio-activity.h`) y los números del tope de cinco
  minutos (`DiloEngines/GrabacionEnRAM.swift`, de `RecordingPolicy.swift`).
- **Muesli**, de Pranav Hari (MIT): las expresiones que reconocen los tokens
  de control de un motor de voz (`DiloText/FiltroDeArtefactos.swift`, de
  `TranscriptionEngineArtifactsFilter.swift`), la lectura del texto
  alrededor del cursor para el contexto de la limpieza
  (`DiloCapabilities/LecturaDelContexto.swift`, de
  `ScreenContextCapture.swift`) y el Jaro-Winkler del aprendizaje de
  correcciones (`DiloText/AprendizajeDeCorrecciones.swift`, de
  `CustomWordMatcher.swift`).
- **meeting-transcriber**, de pasrom (MIT): para la pista `ellos` de las
  reuniones, la forma del agregado privado del tap y que el búfer del tap es
  el último del IOProc (`Dilo/Reuniones/CapturaDelSistema.swift`, de
  `AppAudioCapture+AggregateDescription.swift`, `AppAudioCapture+TapBuffer.swift`
  y `AppTapSession.swift`), y el remuestreo que se rearma al cambiar la tasa
  (`Dilo/Reuniones/RemuestreoA16k.swift`, de `StreamingMonoResampler.swift`).
  De FluidVoice (GPLv3) no se copió nada.

Cada archivo lleva una línea de origen sobre el bloque adaptado. De otras apps
que se estudiaron sin licencia abierta sólo se tomó la técnica, nunca el
código.

El remote `upstream` sigue apuntando al repo de origen: un remote no es un
archivo del proyecto, y sirve para ir a mirar qué cambió allá.

## El validador de la limpieza

`DiloCore/Sources/DiloText/ValidadorDeLimpieza.swift` adapta reglas y umbrales
de **imnotpayingforwisprflow**, de Yosef Shammout (MIT,
`Sources/LocalDictation/CleanupClient.swift`), y de **Muesli**, de Pranav Hari
(MIT, `Qwen3PostProcessor.swift`), reescritos con listas del español de Chile.
Su copyright está en `LICENSE` y su nombre en Acerca de. Los umbrales de
palabras de BetterWispr se tomaron como dato, sin copiar texto de su archivo,
que es GPL. El prompt de limpieza, los comandos de formato y los reemplazos son
código propio: de otras apps se tomó sólo la técnica, y cada archivo dice de
dónde.

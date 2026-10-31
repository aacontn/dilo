# Pendientes

El plan por fases vive en `/Volumes/SSD 1/Incubator/ingenieria-inversa/informes/02-plan-dilo.md`.
Estado al 2026-10-29: `main` local (sin push) en la 0.10.0, instalada y notarizada: dictado con Ultra, Phonon, Conversación y Reuniones fase 1. `versiones/` sigue con los archivos de la 0.9.4 (los arma `release.sh`).

## Por hacer

- 2026-10-31 · En la llamada de la 0.13.0 (12:50, 13 turnos, 7 interrupciones) 3 interrupciones cayeron mientras pensaba, justo después de cerrar el turno: puede ser Alfonso siguiendo tras una pausa, o ruido. La 0.13.1 sube ese umbral; ver si siguen. No bajar el silencio de 700 ms hasta saberlo.
- 2026-10-31 · Confirmar en una llamada con la 0.13.0: interrumpir hablando con parlantes, si Kami suena peor por el motor con cancelación, y si Parakeet entiende igual con la voz procesada.
- 2026-10-31 · Probar por voz lo que falta: encargar a Claude Code y seguir conversando, el aviso al terminar y el clic. La llamada del 30-10 (20:49, 25 s) no lo tocó. Sí midió: sin caídas, 2 interrupciones, eco −0,25, de callar a oír 2,36-2,58 s (silencio 0,72; transcribir 2-10 ms; Claude 0,9-1,25; primera frase 0,2-0,45; Phonon 0,4-0,7) y 3,6 s con la frase abierta. Falta confirmar con Alfonso si las dos interrupciones fueron suyas: la segunda duró casi sólo lo que tarda en detectarse.
- 2026-10-31 · Probar Reuniones 0.13.0 en una reunión real (Alfonso): que macOS pregunte por el audio del sistema, que `ellos` suene a velocidad normal y dure lo mismo que `yo` con audífonos Bluetooth en llamada, que el vivo avance por las dos pistas, y escribir y dictar una nota sin perder el foco de la llamada. Lista en `docs/design/probar-reuniones-en-vivo.md`.
- 2026-10-31 · Medir en esa reunión la CPU y la RAM del vivo y cuánto va detrás de lo dicho (spec: < 25 % de un núcleo y ≤ 4 s). Con voces de `say` a ritmo real dio 9 % de un núcleo y hasta ~2,5 s.
- 2026-10-31 · Hablantes en el vivo con Nemotron `fast32` (spec F2), y el eco con parlantes: en vivo, lo que el micrófono recapta de los parlantes sale también como «Yo»; la pasada final sí lo saca.
- 2026-10-30 · Sacar `PedidoAClaudeCode` y `PreguntaDeProyecto` si la 0.12.0 anda: la llamada ya no los usa.
- 2026-10-30 · Probar la Conversación como agente con la app abierta: herramientas («¿qué dicté ayer?», «¿qué tengo hoy?»), una aprobación (Aprobar, No, colgar esperando), «pásame con Switchboard», «Claude Code, en Dilo, revisa los tests», «revisa Claude Code», y que `eager_input_streaming` y el tool use no den 400 en Haiku, Sonnet y Opus 5.5.
- 2026-10-30 · Autorizar a Dilo en Switchboard (ventana «Agentes»: emparejamiento con código, herramientas y proyectos) y ver si pide confirmar de nuevo tras cada build. (Alfonso)
- 2026-10-30 · Probar «Escuchar mi nombre» un día con la voz y el micrófono de Alfonso: aciertos, falsas alarmas, pausas (dictado, conversación, reunión, pantalla bloqueada), Bluetooth sin bajar a calidad de llamada, CPU y RAM con `scripts/metrics.sh`.
- 2026-10-30 · Dejar una sola tabla de cómo el motor escribe cada nombre: `EnrutadorDeAgentes.variantes(de:)` y `NombreQueDespierta.comoLoOyeElMotor` están duplicadas.

- 2026-10-29 · `VentanaDeLaMuescaTests.elHitTestNilDejaPasarElClicALaVistaDeAbajo` falla en macOS 27 sin que el código haya cambiado: `NSHostingView` sin ventana no reclama el clic. Rehacer el test con una ventana o sacarlo.

- 2026-10-15 · Probar en pantalla la fase 5 (agentes en la muesca, App Intents, MCP, CLI): lista en `docs/design/agentes-en-la-muesca.md`. Nunca tomando el Mac mientras Alfonso lo usa.
- 2026-10-21 · Analizar con rea FluidVoice 1.6.12-beta.1 y Wispr Flow con Notetaker (la descarga de Wispr la hace Alfonso) y devolver `Dilo/taller/` al SSD2.
- 2026-10-21 · Espiga de ExtensionKit; sobrantes (troceo, casos especiales); vista previa estable; regla de música (requiere medir).
- 2026-10-29 · Probar con la app abierta lo de la 0.10.0: reuniones (permiso del audio del sistema, salida intacta con AirPods, las cinco apps de llamada, matar la app grabando, SSD desmontado, dictar durante la reunión, ventana del guion), Conversación (fin de turno a 1,1 s, interrumpir, colgar sola) y Phonon. Nunca tomando el Mac.
- 2026-10-29 · Correr `scripts/comparar-motores.sh` con dictados reales (v3 contra Ultra) y `scripts/banco-reuniones.sh` con reuniones reales etiquetadas, y fijar con esos números la variante recomendada y el diarizador.
- 2026-10-29 · Medir en una reunión de una hora el tiempo hasta el guion (meta < 90 s; Parakeet midió ~150 s por hora por pista en archivos cortos) y la primera compilación de Nemotron (412 s en el M1).
- 2026-10-29 · Probar «envía» al final y la mayúscula según el cursor (apagados) en Slack, Mail y Chrome.
- 2026-10-29 · Calibrar los umbrales de silencio de la Conversación con la voz de Alfonso y probar `scripts/probar-conversacion.sh --llamar` (pide el Llavero: lo corre Alfonso).
- 2026-10-29 · Avisarle a Gradium que Phonon 0.5.0 no pronuncia la ñ ni la ú (Dilo lo esquiva reescribiendo el texto).
- 2026-10-30 · Confirmar de oído que «Yo» y «Ya» al partir una respuesta ya no suenan «Io», «Ia», en parlantes y en Bluetooth. Si sigue, medir cuánto se pierde la salida al encender o agregar silencio al primer audio.

## Por confirmar

- 2026-10-29 · Instalar Rust para exportar Phonon a Core ML (primer audio < 20 ms en el ANE; enlazarlo suma ~4,2 MB). (Alfonso)

- 2026-10-15 · Empujar `main` a GitHub. (Alfonso)
- 2026-10-30 · Agregar Codex y Gemini CLI como agentes cuando estén instalados: cada uno necesita su adaptador como `DestinoClaudeCode` y `Agente.trabajaDeFondo`; las herramientas de encargos salen solas de la lista.

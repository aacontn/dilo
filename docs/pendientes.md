# Pendientes

El plan por fases vive en `/Volumes/SSD 1/Incubator/ingenieria-inversa/informes/02-plan-dilo.md`.
Estado al 2026-10-29: `main` local (sin push) en la 0.10.0, instalada y notarizada: dictado con Ultra, Phonon, Conversación y Reuniones fase 1. `versiones/` sigue con los archivos de la 0.9.4 (los arma `release.sh`).

## Por hacer

- 2026-10-30 · Rehacer la Conversación como un solo agente de voz. Prueba de la 0.11.1 (15:03): el traspaso a Claude Code anduvo, pero después ningún modelo contestó: 5 turnos seguidos con la frase fija de `PreguntaDeProyecto`, 2 a 24 ms después de transcribir, y `diloClaudeCodeUltimoProyecto` sigue vacío. Falta: que el agente no se vaya y use Claude Code como herramienta de fondo, interrumpir hablando (hoy es half duplex) y bajar el piso de 1,2-1,5 s sin modelo (700 ms de silencio + 340-640 ms de voz).
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
- 2026-10-30 · Agregar Codex y Gemini CLI como agentes cuando estén instalados: cada uno es un adaptador como `DestinoClaudeCode` (hablan distinto); el traspaso ya los alcanza solo. Hoy sólo está instalado `claude`.

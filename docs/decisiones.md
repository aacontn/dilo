# Decisiones

- 2026-09-20 · Dilo pasa a app nativa Swift, solo Mac (Apple Silicon, macOS 26+), sobre fork de Talkify (MIT); de Handy se porta el producto, no el código · upstream Handy reescribió su historia y ya no había merge barato.
- 2026-09-20 · `Dilo/app` (Tauri) se congela en 0.3.2: no se borra, cero horas más · todo el esfuerzo va al nativo.
- 2026-09-20 · El notch es la identidad de la app (estados de dictado, reunión, conversación; píldora igual sin notch) · diferenciarse de las demás apps de dictado.
- 2026-09-20 · Decisiones tipadas con reglas por defecto y FoundationModels como escalón; Laya no entra (65 % en español) · medido ese día contra «la app al frente decide» (100 %).
- 2026-09-20 · Reglas de v1: el gatillo nunca escribe símbolos, la píldora sin notch no tapa la barra de menús, nunca tocar el volumen maestro · aprendidas en los spikes.
- 2026-09-22 · Cada build que Alfonso usa se instala en `/Applications/Dilo.app` (reemplazando), firmada con su Developer ID; se abre solo cuando él lo pide · la usa a diario y cambiar de ruta o firma le vuelve a pedir permisos. Builds de prueba van al SSD2.
- 2026-09-24 · En el notch, íconos antes que palabras · «no me gusta que salga copiar».
- 2026-10-15 · Se abandona Dilo-MAS (App Store): «lo hacemos para nosotros»; un solo Dilo instalado, sin copias ni builds viejos tirados · es para uso propio, no para distribuir.
- 2026-10-21 · Reuniones (v2) al estilo FluidMeet: guion con quién dijo qué, diarización local, Claude solo a pedido, datos en `/Volumes/SSD 1/Dilo/reuniones/` · todo local por decisión de Alfonso. Diseño en la rama `docs/diseno-reuniones`.
- 2026-10-29 · FluidAudio de 0.15.8 a 0.18.0, con `TTS` y `NemoTextProcessing` apagados y sólo `Diarizer` encendido · trae Parakeet Ultra y Nemotron 3; el normalizador de 8 MB no cabe y los números hablados ya son de Dilo.
- 2026-10-29 · Parakeet Ultra queda como variante recomendada junto a v3, sin bajarse sola · un quinto menos de errores en FLEURS a la misma velocidad; se confirma con el banco sobre dictados reales.
- 2026-10-29 · Tus palabras en Parakeet (segunda pasada CTC) queda apagada · el CTC es inglés: subió el WER de 9 % a 16 % y el soltar→texto de 145 a 369 ms.
- 2026-10-29 · «Leer en voz alta» pasa a Phonon 40m en español (Gradium, CC BY-NC, uso personal) con Apple de respaldo; Kokoro descartado por Alfonso, Pocket TTS por inteligibilidad (30 % de WER), Supertonic por peso (+4,6 MB) · Alfonso: las voces premium de Apple «son malísimas».
- 2026-10-29 · La voz de Siri no se usa · macOS sólo la entrega a procesos firmados por Apple; disparar «Leer la selección» del sistema es a ciegas y choca con ⌥Esc.
- 2026-10-29 · Conversación: voz en el Mac y sólo el pensar en línea (Claude); router con Sonnet 5.5 en el primer turno, Haiku 5.5 para lo trivial y Opus 5.5 sólo con evidencia de dos turnos o pedido explícito, tres turnos de histéresis · decidido con Alfonso; ~US$0,10–0,15 por 10 minutos.
- 2026-10-29 · Reuniones se construyen sin esperar la Fase 0: Nemotron 3 de fábrica, Sortformer elegible, y la Fase 0 pasa a ser un banco (`scripts/banco-reuniones.sh`) que se corre con reuniones reales · Alfonso: «démosle no más».
- 2026-10-29 · La cuenta de Hugging Face (dev@espaciodigital.cl) vive en `Espacio Digital/herramientas/huggingface/`; otra cuenta irá en `huggingface-<cuenta>` · es de la agencia y el token sólo baja modelos.

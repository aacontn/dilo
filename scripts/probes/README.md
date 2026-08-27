# Probes de Gemini 3.5 Transcribe

Verifican el protocolo contra la API viva. Leen la key de
`post_process_api_keys.google` del settings store de Dilo en runtime — no la
contienen ni la imprimen. Correr con `bun <probe>.ts` desde esta carpeta.

- `gemini-probe.ts` — dictado: live por WebSocket (SMART) + batch
  `interactions` con WAV. Necesita `dictado.wav`.
- `meeting-probe.ts` — arma `reunion.wav` (2 voces) y prueba diarización en
  `interactions` (verificado 2026-08-27: la rechaza).
- `gc-probe.ts` — diarización + timestamps por `:generateContent` (la
  compuerta de entrada del spec de reuniones; 503 por congestión el día del
  lanzamiento). Necesita `reunion.wav` (lo genera `meeting-probe.ts`).

Regenerar los audios (no se versionan):

```bash
say -v "Eddy (Español (México))" -o dictado.aiff "Oye, eh, mándale un correo a la Carola diciéndole que la reunión queda para el jueves a las tres... no, mejor a las cuatro de la tarde, y dile que traiga el informe de ventas." && afconvert -f WAVE -d LEI16@16000 -c 1 dictado.aiff dictado.wav
```

```bash
say -v "Eddy (Español (México))" -o s1.aiff "Ya, entonces cerramos el presupuesto el viernes, ¿te parece?" && say -v "Flo (Español (España))" -o s2.aiff "Sí, perfecto, pero antes falta que marketing mande sus números, eh, los de julio y agosto." && say -v "Eddy (Español (México))" -o s3.aiff "Ok, yo les escribo hoy y les pido que los manden mañana a primera hora." && for f in s1 s2 s3; do afconvert -f WAVE -d LEI16@16000 -c 1 $f.aiff $f.wav; done
```

Resultados medidos el 2026-08-27 en los specs
`2026-08-27-motor-gemini-transcribe-design.md` y
`2026-08-27-reuniones-en-linea-design.md`.

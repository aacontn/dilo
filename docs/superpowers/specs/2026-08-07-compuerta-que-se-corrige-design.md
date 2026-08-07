# Dilo — La compuerta deja de ser sentencia: medir, mostrar, adaptar, reparar

**Fecha:** 2026-08-07 · **Estado:** diseño aprobado por Alfonso en conversación · **Base:** [reuniones en streaming](2026-08-04-reuniones-en-streaming-design.md), que sacó el VAD del camino de reuniones y lo reemplazó por la compuerta de energía que este diseño corrige

## De dónde sale esto

Alfonso grabó una llamada de WhatsApp (reunión 27) y el transcript se saltó
tramos enteros de habla. Medido contra su base:

|                        | Video YouTube (2026-08-04) | Llamada WhatsApp (2026-08-07) |
| ---------------------- | -------------------------- | ----------------------------- |
| Cobertura              | 95,2 %                     | **43,3 %**                    |
| Hueco más largo        | 1 s                        | **27,8 s**                    |
| Audio que llegó al ASR | —                          | **28 %** del tiempo de reloj  |

La causa está en `ENERGY_GATE_RMS = 0.005` (`managers/meeting.rs`): una
constante que el propio doc comment admite no calibrada contra hardware real.
La llamada, entrando por audio del sistema, queda bajo el umbral gran parte
del tiempo. Y la decisión es binaria por trozo de 30 ms: la compuerta abre
sólo en los picos, cortando arranques y finales de palabra — de ahí las
filas de una palabra ("pa", "y mejor") que se ven en las capturas.

### El patrón de las tres fallas

| Filtro                           | Pregunta que hacía                           | Resultado                  |
| -------------------------------- | -------------------------------------------- | -------------------------- |
| Silero VAD (hasta 2026-08-02)    | "¿es **seguro** voz?" — descarta por defecto | botó el 79 %               |
| Compuerta RMS (desde 2026-08-04) | "¿suena **fuerte**?" — constante fija        | botó la llamada baja       |
| Ambos                            | deciden por trozo, sin memoria               | cortan palabras a la mitad |

El diagnóstico lo puso Alfonso: _"el VAD no es mala cosa, sino cómo se
aplicaba"_. Los dos filtros cometían el mismo error de fondo — **la carga de
la prueba estaba sobre el audio**. Para reuniones va al revés: perder habla
es catastrófico e irrecuperable; dejar pasar un tramo dudoso cuesta, a lo
más, un pedazo sin texto.

## El principio

**El audio entra salvo que se demuestre que no es nada.** Y cuando el
sistema igual se equivoca, el error se detecta, se muestra, se corrige la
causa y se repara el daño. Cuatro capas, cada una cubriendo la falla de la
anterior: **medir → mostrar → adaptar → reparar**.

## Capa 0 — La compuerta bien hecha (el default invertido)

Reemplaza la decisión binaria por trozo. Se bloquea audio sólo cuando **dos
señales independientes** están de acuerdo, sostenido en el tiempo:

- **Energía contra piso medido.** El piso de ruido se mide de la fuente real
  (percentil bajo de una ventana rodante), y el umbral es "piso + margen en
  dB" — no una constante. Un video fuerte y una llamada baja quedan ambos
  bien calibrados.
- **Silero como veto, no como portero.** El mismo modelo que ya está cargado
  para el dictado, con la pregunta invertida: ya no "¿es seguro voz?" sino
  "¿confirmas que NO suena a habla?". Sólo su acuerdo con la energía cierra
  la compuerta. Silero distingue siseo de voz (lo que la energía no puede);
  la energía distingue niveles (lo que Silero calibrado para dictado hacía
  mal).
- **El silencio digital se bloquea siempre** — ceros exactos, el caso que
  produce alucinación real del ASR y que motivó la compuerta original. Piso
  absoluto, sin discusión.
- **Bordes con memoria:** histéresis (abre a un umbral, cierra a otro más
  bajo), cola (~1 s abierta tras caer la energía), y pre-búfer (~300 ms que
  se sueltan al abrir). Sin esto, cualquier umbral corta palabras.

El dictado no cambia: su VAD y su camino quedan como están. La compuerta
sigue protegiendo sólo al ASR de reuniones; Sortformer sigue recibiendo todo
el audio (decisión del fix round 1 del plan anterior, que se conserva).

## Capa 1 — Medir: Sortformer como árbitro

Sortformer ve el audio **sin filtrar** y emite tramos de voz. Cruzar sus
tramos contra lo que el ASR realmente recibió da, en vivo, la métrica que
hoy sólo se obtiene con SQL después del desastre: **cuánta habla detectada
no se transcribió**. Esa evidencia hoy existe y se tira.

El porcentaje que pasó la compuerta queda además en el log por minuto, para
que el próximo diagnóstico tarde un minuto y no una tarde.

## Capa 2 — Mostrar: el medidor a la vista

Un indicador discreto en la tarjeta de grabación (popover y ventana de
reuniones): voz detectada vs. transcrita. Cuando el desacuerdo es alto, el
aviso dice lo que pasa y qué hacer — "el audio llega muy bajo; sube el
volumen de la llamada". Misma filosofía que el tope de 4 voces: el límite se
muestra, no se esconde.

## Capa 3 — Adaptar: lazo cerrado

Si el desacuerdo Sortformer-vs-ASR supera un umbral sostenido, la compuerta
**baja su piso sola durante la reunión**, dentro de límites acotados. Se
equivoca una vez y aprende, en vez de equivocarse toda la reunión.

El piso aprendido se **persiste por fuente/dispositivo de audio**: la
próxima reunión por la misma fuente arranca calibrada. El caso de hoy pasa
una sola vez por instalación.

## Capa 4 — Reparar: el error deja de ser fatal

Un anillo con los últimos minutos de audio crudo (~4 MB/min, acotado).
Cuando el árbitro detecta un tramo con voz que el ASR no recibió, ese tramo
se **re-transcribe y se inserta donde iba**: el alineador ya trabaja por
milisegundos de reunión, así que el parche cae en su posición exacta. El
segmento llega tarde —segundos— pero llega.

Con esto, perder habla exige que **dos sistemas independientes fallen a la
vez sobre el mismo tramo**. El hueco de 27,8 s de la reunión 27 se habría
rellenado solo.

**Es la capa más valiosa y la más delicada:** inserta segmentos fuera de
orden en un flujo hoy estrictamente cronológico, y el parche no puede
solaparse con lo ya transcrito ni duplicarlo. Reglas duras:

- El tramo reparado se transcribe **aparte** (no por el stream en vivo, cuyo
  reloj no admite retrocesos).
- Sólo se repara lo que ninguna transcripción cubrió — el recorte va por
  marcas de tiempo contra lo ya persistido.
- Un segmento reparado se marca como tal internamente; la interfaz lo
  muestra igual que cualquier otro (llega tarde, no distinto).
- La regla de no adivinar sigue: su hablante sale del cruce con los tramos
  de Sortformer, y sin tramo que lo cubra queda "Sin identificar".

## Alcance

**Entra:** las cinco capas, la persistencia del piso por fuente, el medidor
en las dos superficies de grabación, y la telemetría de compuerta en el log.

**No entra:**

- **El dictado no cambia.** Su VAD, su camino y su modelo quedan como están.
- **Normalizar/amplificar el audio** (AGC): amplifica el ruido junto con la
  voz. Descartado.
- **Gatear el ASR con los tramos de Sortformer en vivo:** llegan con ~5 s de
  atraso y matarían la escritura en vivo que acaba de lograrse. El árbitro
  es retroactivo, nunca está en el camino del streaming.
- **Reprocesar reuniones ya guardadas.** Lo persistido no se toca (regla del
  diseño anterior, sigue vigente).

## Verificación

- **La llamada de WhatsApp es la prueba de fuego:** repetir una llamada como
  la de la reunión 27 y que la cobertura pase de 43 % a ≥90 %, **sin texto
  alucinado en las pausas** (revisar a mano los tramos de silencio).
- **El caso que motivó la compuerta no vuelve:** audio del sistema con nada
  sonando (silencio digital) sigue sin producir texto.
- **El video fuerte no empeora:** repetir la medición del 2026-08-04 y que
  siga ≥95 %.
- **La reparación repara:** provocar un tramo perdido (volumen bajo al
  inicio, antes de que el lazo adapte) y verificar que el segmento aparece,
  en su posición, sin duplicar vecinos.
- **Las palabras dejan de cortarse:** las filas de una palabra pegadas a
  huecos ("pa", "y mejor") desaparecen del patrón de la base.
- **Memoria y CPU medidas** con el anillo activo en la máquina de 16 GB.

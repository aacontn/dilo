# Dilo — Conversación por voz: palabra de activación local, sesión en línea

**Fecha:** 2026-07-31 · **Estado:** diseño aprobado por Alfonso en conversación · **Base:** [spec de plataforma conversacional abierta](2026-07-22-dilo-plataforma-conversacional-abierta.md) y su nota del 2026-07-24 sobre Dilo Online; mediciones del bucle local hechas el 2026-07-31

## El problema

Dilo ya escucha (Silero VAD + Parakeet), ya piensa (cliente LLM con proveedores) y **ya habla** (Supertonic, `tts_speak`). Lo que no existe es el pegamento: no hay forma de tener una conversación. Hoy cada pieza sirve a un dictado de un turno.

Lo que falta no son modelos. Es la **máquina de turnos**: cuándo entiende que terminaste, cuándo responde, y —lo más difícil— cómo se calla cuando le interrumpes a media frase.

## Lo que se midió antes de decidir (2026-07-31)

Se montó `huggingface/speech-to-speech` en el Mac de Alfonso (16 GB, Apple Silicon) y se midió inyectando audio en español por WebSocket:

| Etapa    | Modelo                           | En caliente |
| -------- | -------------------------------- | ----------- |
| Escuchar | Parakeet TDT 0.6B (MLX)          | 0,32 s      |
| Pensar   | qwen3.5:2b local, sin _thinking_ | 1,15 s      |
| Hablar   | Kokoro 82M                       | 0,47 s      |
|          | **Bucle local completo**         | **≈ 1,9 s** |

Dos hallazgos que decidieron el diseño:

1. **El bucle local es viable pero no alcanza para el objetivo.** ~2 s sirven para conversar; no sirven para un asistente que además razone y ejecute tareas. Un modelo capaz de eso no cabe en 16 GB a velocidad de conversación. **No existe hoy un modelo de voz local que razone lo suficiente.**
2. **El protocolo Realtime de OpenAI es el contrato que el spec de plataforma pedía.** Ya es estándar de facto, con implementaciones libres locales y de nube. Un cliente, y detrás va lo que sea.

## Decisiones tomadas (con Alfonso)

- **Conversación de verdad**, no pregunta-respuesta de un turno: ida y vuelta continuo, con hilo y con interrupción.
- **Palabra de activación**, no atajo. Se aceptó conscientemente el costo: rompe el reposo casi-cero y exige entrenar un detector propio.
- **Las dos juntas**, sin versión intermedia con atajo. No se muestra nada hasta que se pueda decir "Dilo" y conversar.
- **El cerebro es un proveedor de voz de nube** (GPT realtime; Nova Sonic vía adaptador), no el modelo local. La conversación offline queda como capacidad posterior, no como piso de esta versión.

## Diseño

### 1 · Qué corre dónde

**Local, siempre activo:** sólo la palabra de activación, con un modelo pequeño ONNX a través del `ort` que Dilo ya usa para diarización y TTS. **El audio no sale del computador hasta que se detecta la palabra** — ni siquiera para detectarla.

**En línea, sólo durante la sesión:** al activarse, Dilo abre una WebSocket Realtime con el proveedor configurado, transmite el micrófono y reproduce la respuesta. El proveedor resuelve detección de fin de turno, interrupción y voz.

**Dilo es dueño de la experiencia, no del cerebro:** captura, sesión, overlay, progreso, corte. El backend interpreta y responde. Es literalmente lo que fija el spec de plataforma abierta.

### 2 · La palabra de activación

El trabajo real no es integrar el detector: es **entrenar "Dilo"** y domar los falsos positivos. Es una palabra corta que aparece dentro del español corriente ("díselo", "dilo de nuevo", "no me lo dijo"), así que el umbral es el problema difícil, no la inferencia.

Plan: generar muestras sintéticas en muchas voces y acentos —incluido el chileno, que es el usuario— entrenar, y calibrar el umbral contra grabaciones reales de Alfonso hablando **sin** intención de activarlo.

Dos salvaguardas de producto:

- **Indicador visible mientras escucha.** Nunca escuchando en secreto.
- **La palabra es configurable sin recompilar.** Si "Dilo" resulta imposible de detectar limpio, cambiarla es una opción, no un rediseño. El spec de plataforma ya dice que el nombre y el wake word son configurables por usuario.

### 3 · La sesión: qué se ve y cómo termina

La pastilla del overlay es la superficie —no hay ventana nueva— con un estado "conversando" distinto del de dictado, reusando las ondas que ya existen.

Mientras la sesión está abierta hay una **marca clara de que está en línea**, coherente con las etiquetas LOCAL/ONLINE que ya usan los modos de dictado. La sesión se cierra por silencio prolongado o con el atajo de cancelar que ya existe. Nunca queda abierta sin que se vea.

### 4 · El contrato

Dilo implementa **un cliente del protocolo Realtime**, no una integración con un proveedor:

- Un proveedor compatible con Realtime entra directo.
- **Nova Sonic entra por un adaptador**: su API bidireccional es distinta y no debe filtrarse al núcleo. Hay US$1000 de créditos AWS disponibles para probarlo sin costo.
- El día que exista un servidor local que hable el mismo protocolo, ese cliente apunta ahí y no se reescribe nada. Ese es el camino a la conversación offline.

### 5 · Quién paga los minutos

Una conversación de voz en la nube **cuesta por minuto**, y eso choca de frente con la monetización elegida (pago único simbólico, sin suscripción).

Por eso la primera versión es **BYO**: el usuario pone su propia cuenta y su propia clave, igual que hoy con los proveedores de post-proceso. Dilo no revende minutos ni administra cuentas. La variante "Dilo Online administrado con minutos incluidos" que menciona la nota del 2026-07-24 queda **fuera de esta versión**: exige autenticación, facturación y un modelo de negocio que hoy no está decidido.

## Alcance

**Entra:** palabra de activación local entrenada, cliente del protocolo Realtime, sesión conversacional con interrupción, superficie visual en la pastilla, configuración del proveedor y su clave.

**No entra —y es deliberado:**

- **Que el asistente ejecute tareas.** Esta versión conversa: no toca archivos, no corre comandos, no manda mensajes. Eso viene después y exige permisos explícitos y confirmación visual segura, que la constitución no deja saltarse.
- **Conversación offline completa.** El bucle local medido queda documentado como camino posterior, detrás del mismo contrato.
- **Dilo Online administrado.** Ver arriba.

## Restricciones transversales

- **El dictado no cambia.** Todo lo de esta versión es aditivo; quien nunca active la conversación no debe notar ninguna diferencia, ni en reposo ni en latencia.
- **Copy es-first**, autoral, tuteo chileno; claves en los 21 idiomas.
- **Sin dependencias nuevas si es posible**: el detector debe correr por el `ort` existente.
- La voz puede proponer, nunca autoriza operaciones sensibles.

## Riesgos, nombrados

1. **El falso positivo del wake word es el riesgo número uno.** Una palabra corta y común en español puede volver la feature inusable. Mitigación: umbral calibrado con audio real, palabra configurable, y la disposición a cambiar "Dilo" por otra si los números no dan.
2. **Dependencia de red y de cuenta ajena.** Sin internet o sin clave, la conversación no existe. El dictado sí sigue funcionando: ese es el piso que no se toca.
3. **El costo por minuto** puede sorprender al usuario. Mitigación: que la sesión se vea siempre y se cierre sola.
4. **Privacidad.** Durante la sesión, la voz viaja al proveedor. Se compensa con: nada sale antes de la activación, marca visible de sesión en línea, y cierre automático.

## Verificación

- **Latencia medida, no estimada**: inyectando audio como se hizo el 2026-07-31, no "se siente rápido".
- **Falsos positivos del wake word** durante un día completo de uso normal de Alfonso, contando activaciones no intencionadas.
- **Interrupción real**: cortarlo a media frase tiene que callarlo, no encimarse.
- **El dictado intacto**: medir que el reposo y la latencia del dictado no cambian con la conversación desactivada.

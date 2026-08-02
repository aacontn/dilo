# Feature Specification: Notetaker de Reuniones

**Feature Branch**: `001-meeting-notetaker`

**Created**: 2026-07-27

**Status**: Draft

**Input**: User description: "Meeting/notes notetaker for Dilo — the second major pillar of the product alongside voice dictation. Capture a meeting or a stream of spoken thoughts and turn it into a transcript + summary + action items, searchable, synced to Apple Notes or a configurable destination. Must solve the presencial (in-person, single far-field mic, overlapping speech) case, not just the easy virtual-meeting case that every existing notetaker optimizes for — that is the differentiation and it is explicitly in scope, not deferred."

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Grabar y transcribir una reunión presencial con varios hablantes (Priority: P1)

Alfonso está dando o participando de una clase o reunión presencial, con un solo
micrófono de campo lejano captando a varias personas que a veces hablan
encimadas. Activa la grabación y, al terminar, tiene un transcript donde cada
intervención está atribuida a un hablante distinguible (aunque no sepa sus
nombres todavía), sin haber subido audio a ningún servidor.

**Why this priority**: es el problema que ningún competidor resuelve bien
(todos optimizan para reunión virtual con canales limpios) y la razón de ser
de esta feature — no es la versión más fácil de construir, es la que define
si el notetaker es una ventaja real o una copia de lo que ya existe.

**Independent Test**: grabar una conversación de 3 personas en la misma sala,
con turnos que se pisan al menos una vez, y verificar que el transcript
resultante separa las intervenciones por hablante sin haber enviado audio
fuera del dispositivo.

**Acceptance Scenarios**:

1. **Given** Dilo no está grabando, **When** el usuario inicia una grabación de
   reunión presencial, **Then** el sistema empieza a capturar audio del
   micrófono y muestra que la sesión está activa.
2. **Given** una grabación presencial en curso con 2+ personas hablando en
   turnos que se superponen parcialmente, **When** el usuario detiene la
   grabación, **Then** el transcript resultante marca cada segmento con un
   identificador de hablante consistente (ej. "Hablante 1", "Hablante 2") a lo
   largo de toda la sesión.
3. **Given** una reunión presencial grabada, **When** se revisa el transcript,
   **Then** no existe ningún registro de que el audio haya salido del equipo
   (sin llamadas de red asociadas a la transcripción o diarización).
4. **Given** el sistema no puede determinar con confianza quién habla en un
   segmento, **When** se genera el transcript, **Then** ese segmento se marca
   como de hablante incierto en vez de asignarlo silenciosamente al hablante
   equivocado.

---

### User Story 2 - Grabar una reunión virtual (Zoom/Meet) (Priority: P2)

Alfonso está en una videollamada. Activa la grabación y Dilo captura el audio
del sistema (todos los participantes) además de su propio micrófono, sin
necesidad de que los demás instalen nada ni de un bot que se una a la llamada.

**Why this priority**: caso más simple que el presencial (canales de audio ya
relativamente separados), pero sigue siendo el uso más frecuente día a día;
reutiliza el mismo pipeline de transcripción y diarización de la Historia 1.

**Independent Test**: grabar una videollamada de prueba con 2 participantes y
verificar que el transcript incluye las intervenciones de ambos sin haber
compartido pantalla ni invitado un bot externo.

**Acceptance Scenarios**:

1. **Given** una videollamada activa, **When** el usuario inicia la grabación
   de reunión virtual, **Then** el sistema captura tanto el micrófono del
   usuario como el audio de salida del sistema.
2. **Given** una grabación virtual en curso, **When** el usuario deja de
   compartir o cierra la llamada, **Then** la grabación puede detenerse
   manualmente y el transcript generado hasta ese punto se conserva.

---

### User Story 3 - Detección automática de reunión virtual (Priority: P3)

Alfonso entra a una videollamada (Zoom, Meet) sin haber pensado en grabar.
Dilo nota que hay una llamada activa y muestra una notificación chica y
descartable con un botón de un solo click para empezar a grabar — no arranca
solo. Cuando la llamada termina, Dilo pregunta si parar la grabación o
seguir (por si la charla sigue después de colgar).

**Why this priority**: construye directamente sobre la Historia 2 (mismo
mecanismo de captura) — sin esto, el usuario tiene que acordarse de grabar a
tiempo, que es la razón más común por la que una reunión se pierde sin
capturar.

**Independent Test**: iniciar una videollamada de prueba sin tocar Dilo y
verificar que aparece la notificación de "reunión detectada"; hacer click en
grabar y confirmar que la grabación arranca desde ahí (no desde el inicio
real de la llamada, que no se grabó).

**Acceptance Scenarios**:

1. **Given** Dilo no está grabando, **When** se detecta una videollamada
   activa (Zoom/Meet u otra con audio de sistema), **Then** aparece una
   notificación descartable ofreciendo grabar con un solo click.
2. **Given** el usuario descarta la notificación, **When** la misma llamada
   sigue activa, **Then** Dilo no vuelve a insistir con otra notificación
   para esa misma llamada.
3. **Given** una grabación iniciada por detección automática, **When** la
   videollamada termina, **Then** aparece una confirmación para detener la
   grabación, con opción de seguir grabando en vez de parar automáticamente.
4. **Given** una reunión presencial en curso (Historia 1), **When** no hay
   ninguna llamada de sistema activa, **Then** no aplica detección
   automática — el inicio sigue siendo manual (ver Assumptions: la
   detección presencial es un problema distinto, no resuelto en esta spec).

---

### User Story 4 - Revisar una reunión pasada (Priority: P4)

Alfonso quiere volver a una reunión de hace unos días y ver qué se dijo, qué
anotó él mismo en el momento, cuál fue el resumen y qué quedó pendiente, sin
releer el audio entero.

**Why this priority**: es donde se materializa el valor de haber grabado —
sin una revisión útil, capturar la reunión no sirve de nada.

**Independent Test**: abrir una reunión ya grabada y confirmar que se puede
navegar entre notas propias, transcript completo, resumen y lista de
pendientes sin volver a procesar el audio.

**Acceptance Scenarios**:

1. **Given** una reunión ya finalizada y procesada, **When** el usuario la
   abre, **Then** puede navegar entre pestañas de **Mis Pensamientos**,
   Transcript, Resumen y Pendientes (action items) de esa reunión.
2. **Given** una reunión en curso o ya terminada, **When** el usuario
   escribe algo en la pestaña Mis Pensamientos, **Then** ese texto queda
   guardado como una nota propia, separada del transcript de lo que se
   habló — no se mezcla ni se sobreescribe con la transcripción.
3. **Given** una reunión con action items detectados, **When** el usuario
   revisa la pestaña de Pendientes, **Then** ve cada acción como un ítem
   independiente, no mezclado dentro del texto del resumen.
4. **Given** una reunión que se interrumpió a mitad (crash de la app, cierre
   forzado), **When** el usuario reabre Dilo, **Then** encuentra la reunión
   marcada como interrumpida, con el transcript parcial que sí se logró
   capturar antes del corte (no se pierde silenciosamente).

---

### User Story 5 - Buscar y preguntar sobre reuniones pasadas (Priority: P5)

Alfonso no recuerda en qué reunión se habló de un tema, y quiere encontrarlo
sin abrir una por una.

**Why this priority**: escala el valor de tener muchas reuniones grabadas;
sin búsqueda, el historial se vuelve inútil después de las primeras semanas.

**Independent Test**: con al menos 3 reuniones grabadas que mencionan un mismo
tema en momentos distintos, buscar ese tema y confirmar que las tres
aparecen con el fragmento relevante resaltado.

**Acceptance Scenarios**:

1. **Given** varias reuniones ya transcritas, **When** el usuario busca una
   palabra o frase, **Then** el sistema muestra las reuniones donde aparece,
   con el fragmento de contexto donde se dijo.
2. **Given** una reunión específica abierta, **When** el usuario pregunta algo
   sobre su contenido en lenguaje natural (ej. "¿qué dijo Fulano de X?"),
   **Then** recibe una respuesta basada en el transcript de esa reunión, no
   una respuesta genérica sin fundamento en lo grabado.

---

### User Story 6 - Sincronizar la reunión con Apple Notes u otro destino (Priority: P6)

Alfonso quiere que el resumen y los pendientes de la reunión terminen en
Apple Notes (o donde él configure) sin copiar y pegar a mano.

**Why this priority**: cierra el loop hacia las herramientas donde el usuario
ya vive; es la conveniencia final, no el corazón del problema técnico.

**Independent Test**: configurar Apple Notes como destino, grabar y procesar
una reunión, y confirmar que aparece una nota nueva con el resumen y los
pendientes sin intervención manual.

**Acceptance Scenarios**:

1. **Given** un destino de sincronización configurado, **When** una reunión
   termina de procesarse, **Then** se crea o actualiza automáticamente una
   nota en ese destino con el resumen y los pendientes.
2. **Given** ningún destino configurado, **When** una reunión termina de
   procesarse, **Then** la reunión queda disponible dentro de Dilo igual,
   sin que la sincronización sea un requisito para poder revisarla.

---

### Edge Cases

- ¿Qué pasa si dos o más personas hablan exactamente al mismo tiempo por más
  de un par de segundos? El transcript debe reflejar que hubo superposición
  en vez de inventar una sola línea coherente que nadie dijo así.
- ¿Qué pasa si el número de hablantes cambia durante la reunión (alguien se
  suma o se va a mitad)? El sistema debe poder incorporar un hablante nuevo
  sin haber sabido de antemano cuántos habría.
- ¿Qué pasa si se corta la luz o se cierra la laptop a mitad de una reunión
  presencial de dos horas? No se debe perder el transcript ya capturado hasta
  ese punto.
- ¿Qué pasa sin conexión a internet? Grabación, transcripción y diarización
  presencial deben seguir funcionando; solo una sincronización a un destino
  externo (Historia 6) puede quedar pendiente hasta que vuelva la conexión.
- ¿Qué pasa si dos videollamadas están activas al mismo tiempo (ej. una en
  segundo plano que el usuario olvidó cerrar)? La detección automática
  (Historia 3) no debe ofrecer grabar ambas como si fueran una sola sesión.
- ¿Qué pasa si el usuario ignora repetidamente la notificación de "reunión
  detectada"? No debe volverse insistente ni bloquear el flujo de la
  videollamada.
- ¿Qué pasa con una reunión de varias horas (ej. una clase completa)? El
  sistema no debe esperar a que termine para empezar a mostrar avance, ni
  degradarse en precisión o uso de memoria a medida que la sesión se alarga.
- ¿Qué pasa si hay ruido de fondo fuerte o varios hablantes con acentos o
  modismos regionales distintos? La atribución de hablante no debe degradarse
  a "todo es un solo hablante" como salida por defecto ante la incertidumbre.
- ¿Qué pasa si el usuario cambia de español a otro idioma a mitad de la
  reunión (spanglish, términos técnicos en inglés)? No debe romper la sesión
  de transcripción en curso.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: El sistema MUST permitir iniciar y detener manualmente una
  grabación de reunión, tanto presencial (micrófono) como virtual (audio de
  sistema).
- **FR-002**: El sistema MUST transcribir el audio de forma incremental
  durante la grabación, mostrando avance sin esperar a que la sesión termine.
- **FR-003**: El sistema MUST identificar y distinguir hablantes distintos en
  audio de un solo micrófono de campo lejano con voces que se superponen
  parcialmente, sin conocer de antemano cuántos hablantes hay.
- **FR-004**: El sistema MUST marcar como incierto un segmento de audio donde
  no pueda determinar con confianza razonable quién habla, en vez de
  asignarlo a un hablante existente por defecto.
- **FR-005**: Users MUST be able to asignar un nombre a cada hablante
  detectado, renombrarlo después, y fusionar dos identificadores de hablante
  cuando el sistema separó erróneamente a la misma persona en dos.
- **FR-006**: El sistema MUST generar un resumen y una lista de pendientes
  (action items) separada del resumen, a partir del transcript de cada
  reunión.
- **FR-007**: El sistema MUST persistir el transcript parcial de una reunión
  de forma incremental durante la grabación, de modo que una interrupción
  (cierre forzado, corte de energía) no pierda lo capturado hasta ese punto.
- **FR-008**: El sistema MUST marcar visiblemente como interrumpida una
  reunión que no llegó a cerrarse normalmente, al reabrir la aplicación.
- **FR-009**: Users MUST be able to revisar una reunión pasada navegando por
  separado sus notas propias (Mis Pensamientos), su transcript completo, su
  resumen y sus pendientes.
- **FR-009b**: Users MUST be able to escribir notas propias en la pestaña
  Mis Pensamientos durante o después de una reunión, guardadas de forma
  independiente del transcript generado.
- **FR-017**: El sistema MUST detectar cuando hay una videollamada activa
  (audio de sistema de una app de videollamada) y mostrar una notificación
  descartable ofreciendo iniciar la grabación con una sola acción, sin
  iniciar la grabación automáticamente sin confirmación del usuario.
- **FR-018**: El sistema MUST ofrecer detener la grabación cuando detecta
  que la videollamada que la originó terminó, dejando al usuario la opción
  de seguir grabando en vez de forzar el corte.
- **FR-010**: Users MUST be able to buscar texto a través de todas las
  reuniones grabadas y ver en qué reunión y contexto aparece.
- **FR-011**: Users MUST be able to hacer una pregunta en lenguaje natural
  sobre el contenido de una reunión específica y recibir una respuesta basada
  en su transcript.
- **FR-012**: El sistema MUST permitir configurar un destino de
  sincronización (ej. Apple Notes) al que se envíe automáticamente el
  resumen y los pendientes al terminar de procesar una reunión.
- **FR-013**: El sistema MUST seguir siendo completamente funcional (grabar,
  transcribir, diarizar) sin conexión a internet; solo la sincronización a un
  destino externo puede depender de conectividad.
- **FR-014**: El sistema MUST realizar la transcripción y la diarización de
  forma local, sin transmitir el audio capturado a un servidor externo.
- **FR-015**: El sistema MUST soportar sesiones de grabación de varias horas
  sin degradar su precisión ni requerir reiniciar la sesión.
- **FR-016**: El sistema MUST capturar tanto el micrófono del usuario como el
  audio de salida del sistema para el caso de reunión virtual, sin requerir
  que otros participantes instalen software ni que un bot se una a la
  llamada.

### Key Entities

- **Reunión (Meeting)**: una sesión de captura, con hora de inicio, hora de
  fin (o marca de interrupción), tipo (presencial/virtual), transcript,
  resumen y lista de pendientes asociados.
- **Segmento de transcript**: un fragmento de texto transcrito, con marca de
  tiempo y el hablante al que está atribuido (o marcado como incierto).
- **Hablante (Speaker)**: un identificador de voz distinguido dentro de una
  reunión, que puede tener un nombre asignado por el usuario y puede
  fusionarse con otro identificador de la misma reunión.
- **Pendiente (Action item)**: una acción detectada dentro del contenido de
  una reunión, independiente del texto del resumen.
- **Nota propia (My Thoughts)**: texto libre escrito por el usuario durante
  o después de una reunión, independiente del transcript y del resumen —
  no generado automáticamente.
- **Destino de sincronización**: configuración de a dónde se envía el
  resumen y los pendientes de una reunión al terminar de procesarla.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: En una reunión presencial de 3 personas con al menos una
  superposición de habla, el transcript resultante atribuye correctamente
  más del 80% de los segmentos al hablante correcto.
- **SC-002**: El transcript incremental muestra texto nuevo dentro de los
  pocos segundos posteriores a que alguien terminó de hablar, sin esperar al
  fin de la reunión.
- **SC-003**: Ninguna sesión de grabación pierde más del último segmento sin
  guardar ante una interrupción abrupta (cierre forzado o corte de energía).
- **SC-004**: Una reunión de 2+ horas se transcribe y diariza sin que el uso
  de memoria ni la latencia de transcripción se degraden notablemente entre
  el inicio y el final de la sesión.
- **SC-005**: El 100% de la grabación, transcripción y diarización de una
  reunión ocurre sin conexión a internet activa.
- **SC-006**: Un usuario puede encontrar una reunión pasada por su contenido
  (no por fecha o título) en menos de 10 segundos usando la búsqueda.
- **SC-007**: Al configurar un destino de sincronización, el 100% de las
  reuniones procesadas posteriormente aparecen ahí sin intervención manual.
- **SC-008**: La notificación de "reunión detectada" aparece dentro de los
  primeros segundos posteriores a que una videollamada activa comienza a
  transmitir audio.

## Assumptions

- El usuario ya tiene Dilo instalado y configurado para dictado; el
  notetaker es una pata nueva del mismo producto, no una app separada.
- El límite superior de hablantes simultáneos que el sistema debe soportar
  bien en el caso presencial es un grupo chico (una reunión de equipo o una
  clase), no un auditorio grande — el caso "salón con cientos de personas"
  queda fuera de alcance de esta especificación.
- El transcript y el audio se conservan localmente; las políticas de
  retención/eliminación del audio crudo después de transcribir siguen el
  mismo criterio que el resto de Dilo (configurable, ver `CLAUDE.md`), no se
  redefinen aquí.
- "Apple Notes u otro destino configurable" asume que el mecanismo de
  sincronización en sí (cómo se conecta a Apple Notes u otros destinos) es
  un detalle de implementación a resolver en la fase de plan, no en esta
  especificación.
- La detección automática (Historia 3) aplica solo al caso **virtual**, vía
  la misma señal de audio de sistema que ya se usa para capturar la
  llamada — detectar automáticamente que "hay una reunión/clase presencial
  en curso" sin ninguna señal de sistema es un problema distinto y más
  difícil (no hay una app de videollamada de la cual colgarse), y queda
  explícitamente fuera de alcance de esta especificación. La Historia 1
  (presencial) sigue asumiendo inicio manual.

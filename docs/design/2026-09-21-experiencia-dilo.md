# Dilo: voz en el notch, trabajo en su ventana

Dirección de producto precisada por Alfonso el 21 de septiembre de 2026.
Estado: propuesta de experiencia y primera depuración de la app existente.
No describe reuniones ni asistente como funcionalidades ya implementadas.

## Norte

Dilo es una interfaz de voz para trabajar: dictado y reuniones primero;
conversación con un asistente que opera apps y se conecta al HUD personal después.
El notch es la superficie inmediata. La ventana conserva, organiza y permite
revisar resultados. Un monitor sin notch recibe la misma experiencia en una
píldora debajo de la barra de menús, sin simular una cámara ni tapar íconos.

Premium significa comportamiento confiable, jerarquía clara y continuidad entre
superficies. No exige más shaders, más estilos ni más opciones en primer plano.
La migración a Swift tiene sentido por la integración nativa; no se atribuye
la lentitud antigua a Tauri sin comparar mediciones equivalentes.

## Referencias revisadas

- [Sapphire](https://sapphire-app.tech): presenta actividades compactas que se
  expanden en controles y widgets, además de una bandeja de archivos. Para Dilo
  interesa la continuidad compacto → expandido. Sus funciones de sistema,
  música, finanzas y deportes no forman parte del scope de Dilo.
- [Boring Notch](https://github.com/TheBoredTeam/boring.notch): expansión al
  acercar el puntero, controles de música, calendario y bandeja de archivos.
  Interesa la interacción; no se incorpora código ni una dependencia.
- [NotchDrop](https://github.com/Lakr233/NotchDrop): arrastrar archivos hacia
  una zona reconocible del notch. Dilo debe aceptar audio y video y explicar
  que va a transcribirlos, en vez de convertirse en un almacén de cualquier archivo.
- [Notchy / alternativas](https://notchy.dev/alternatives/): catálogo comercial
  del propio producto, útil para explorar categorías. Sus comparaciones y
  cifras de consumo no se toman como benchmarks independientes.

No se instalaron esas apps ni se verificó su rendimiento. Esta comparación
se basa en sus páginas y repositorios, no en una prueba de uso.

## Contrato del notch

| Estado | Qué comunica | Acción disponible | Qué no debe pasar |
| --- | --- | --- | --- |
| Reposo | Presencia discreta, sin animación continua | Abrir acciones por clic o gatillo | Escuchar sin activación |
| Dictando | Nivel real, texto parcial, destino y modo cuando aplique | Soltar, terminar, cancelar | Robar foco o confundir silencio con fallo |
| Preparando | Qué falta: cargar motor o permiso | Cancelar; resolver permiso fuera del HUD | Mostrar onda ficticia |
| Procesando | Trabajo pendiente sobre lo ya grabado | Cancelar cuando sea posible | Parecer que sigue grabando |
| Resultado | Texto entregado o recuperable | Copiar; abrir original | Perder las palabras porque falló el pegado |
| Reunión | Captura activa, tiempo y fuentes de audio | Abrir reunión; terminar | Esconder la grabación al cerrar la ventana |
| Asistente (futuro) | Escuchando, pensando o preparando una acción | Revisar acción, confirmar o cancelar | Confundir una frase dictada con una orden |

El hover puede revelar contexto con tolerancia; no arranca una captura.
Durante dictado, el HUD sigue sin activar la app. Las acciones de resultado y
reunión usan estados interactivos explícitos. Esto amplía el contrato actual
sólo al implementar esos estados, no cambiando la captura de foco global.
No hay paneles compitiendo: una superficie arbitra la sesión y los trabajos.

## El notch como escenario permanente (2026-09-21, tarde)

Alfonso probó la píldora en su Mac mini con dos 1080p sin notch y el
diagnóstico fue de forma, no de velocidad —rápido sí le pareció—:

> «no se ve como un notch; tiene una línea con un micrófono más arriba, que se
> ve raro; me sale el Transformar sin modo de colores; no está arriba como en
> notch, está como una ventana que se abrió; cuando se deja de dictar,
> desaparece y no es funcional.»

Lo que cambia, y por qué:

- **Sin carcasa, el default pasa a ser el notch simulado.** Revierte el
  default de la lección 2 del spec §8 —no el *motivo* de esa lección—: la
  forma sigue sin tapar un status item, porque sólo ocupa la franja del centro
  de la barra, que macOS deja vacía. La píldora se queda elegible a mano. Quien
  nunca eligió pasa al notch simulado; quien eligió conserva su elección.
- **Fuera la corona.** La franja mango con el micrófono iba *encima* de la
  píldora y se leía como un segundo objeto pegado arriba. El contenido va
  dentro de la silueta, como con notch real, y la cabecera de la forma abierta
  **es** la silueta en reposo: la forma crece desde donde estaba descansando.
- **El escenario es permanente.** El HUD ya no aparece y desaparece: cambia de
  tamaño. En reposo queda la silueta compacta con una marca mínima, quieta;
  no escucha, y un clic abre el menú de acciones —el mismo del status item—.
- **Los cinco estados del contrato son un tipo.** `EstadoDelNotch` con
  `MaquinaDelNotch` (pura) y `ControlDelNotch` (los tiempos, con reloj
  inyectable). Procesando dejó de ser un hueco: antes la forma se iba al
  terminar de escuchar y el resultado aterrizaba con el notch fuera de
  pantalla, que es la mitad de «no es funcional».
- **El chip de modo dice el nombre del modo, en mango.** «Transformar: Correo»
  en gris nombraba el mecanismo en vez de la sesión. Sin modo, no hay chip.
- **Reposo no puede costar.** `EstadoDelNotch.anima` es falso en reposo y un
  test lo afirma; ningún `TimelineView` ni shader queda montado. Los números
  del spec §3 se re-miden en CI.

Reunión y asistente siguen siendo casos explícitos sin UI (`HUDSessionKind`).

## La muesca (2026-09-21, noche)

El escenario permanente quedó, pero la forma no. Alfonso vio el notch simulado
en sus dos 1080p:

> «deja tu cuadrado terrible feo; la idea es que sea una pequeña muesca, algo
> chiquitito, igual que las apps que te pasé.»

Las referencias son Boring Notch y Sapphire: una muesca negra pegada al borde
de arriba, del alto de la barra de menús, angosta, con las dos esquinas de
arriba cóncavas. Lo que había era un rectángulo de 185×32 —el notch de un
MacBook de 14", prestado— con los fillets en cero.

- **El alto sale de la pantalla.** `frame.maxY - visibleFrame.maxY`, con el
  piso de `menuBarClearanceFloor` para cuando la barra se autooculta. Una
  constante no sirve: la barra mide distinto en un 1080p y en un Retina
  escalado, y una muesca más alta que la barra sobresale al escritorio.
- **El ancho es de muesca**, no de carcasa prestada
  (`anchoDeLaMuescaSimulada`). Más angosta se lee como una pestaña; más ancha
  vuelve a ser el bloque.
- **Las dos curvas cóncavas de arriba entran** y las de abajo se redondean
  más. Enmienda ADR-0001: son las curvas las que funden la silueta con el
  borde, y sin ellas cualquier tamaño se lee como un rectángulo apoyado.
- **En reposo, nada de contenido.** La silueta y a lo sumo un punto mango de
  tres puntos abajo al centro. La raya de 18×3 ocupaba media muesca y se leía
  como una etiqueta.
- **Crecer es la misma muesca más grande.** El hover —con tolerancia, sin
  capturar— y el dictado la abren con el mismo resorte corto, anclada a `y = 0`
  y centrada, conservando las curvas. Con Reducir movimiento es un corte de
  120 ms.
- **La forma se aprueba en PNG.** `scripts/render-muesca.sh` compila la
  geometría real y rasteriza fuera de pantalla: es lo que deja revisar la
  silueta sin tocar la GUI del Mac.

Queda pendiente decidir el ancho de la forma **abierta**: hoy son los 540
puntos heredados, ajustables en Ajustes → Apariencia.

### Las referencias, y qué se puede mirar de cada una

El patrón que Alfonso quiere es el de **Notch Buddy**: cerrada, la forma es
sólo el notch —la barra negra que ya está ahí—; se abre al pasar el mouse con
un retardo configurable para no dispararse por accidente; se esconde cuando
hay una app en pantalla completa; en monitores sin carcasa dibuja uno simulado
y deja elegir en qué pantalla vive. **OmniNotch** aporta el resorte «líquido»
al expandir. También están a la vista NotchOwl, Notchy, Boring Notch, Atoll,
Sapphire y NotchDrop.

**Qué se puede leer y qué no.** NotchDrop (MIT) se puede leer y adaptar,
citándolo en el `LICENSE` y en Acerca de. Boring Notch, Atoll (GPL-3) y
Sapphire son **sólo para mirar**: ni una línea. De esta pasada no salió código
adaptado de ninguna, así que el `LICENSE` no cambia; el día que se adapte algo
de NotchDrop, la atribución entra antes que el código.

### Lo que se sumó con las referencias

- **Esconderse en pantalla completa, pero sólo el reposo.** Sin barra de menús
  no hay franja de la que colgar. Dictando, procesando y el resultado siguen
  apareciendo: están diciendo algo que no puede esperar a que alguien salga del
  espacio. La señal es la barra misma —`menuBarHeight == 0`—, así que a quien
  la tenga en «ocultar automáticamente» también se le esconde, que es lo que
  pidió.
- **El retardo del hover es un ajuste** (`hudRetardoDeHover`, medio segundo de
  fábrica, «Al instante» en cero). Dónde está la línea entre acercarse a mirar
  y pasar camino al menú depende de cómo mueve el mouse cada persona.
- **En qué pantalla vive la muesca es un ajuste** (`hudPantalla`). Automática
  es la del cursor o la principal; elegir una la deja siempre ahí. Se guarda
  por nombre y no por `CGDirectDisplayID`, que se reparte de nuevo en cada
  arranque; si esa pantalla se desconecta, vuelve a la automática sin perder
  la elección.
- **Un único dato minúsculo en reposo, opcional.** El nombre del modo activo
  en 9 pt gris, apagado de fábrica (`hudModoEnReposo`). Nunca junto con el
  punto ni con lo que revela el hover: uno solo, o ninguno.

## Ventana y navegación

Destino de producto: Recientes, Reuniones y Ajustes.

- Recientes reúne dictados guardados, notas y archivos, con su tipo explícito.
  Una vista de detalle muestra el original y el resultado, nunca los confunde.
- Reuniones reúne registro, transcripción, notas y acuerdos. Los acuerdos
  generados apuntan a un fragmento con tiempo; nombres y fechas no se inventan.
- Ajustes configura. Biblioteca y reuniones no deben quedar enterradas ahí.

La primera depuración conserva la ventana actual y sus capacidades existentes.
No crea entradas de Reuniones ni Asistente vacías. El prototipo explora la
ventana final con contenido ficticio, no sustituye la implementación Swift.

## Diagnóstico del checkout revisado

- Ajustes arrancaba en Apariencia, con 17 entradas en una columna sin scroll.
- Modos de Dilo y Transformar heredado son bibliotecas distintas. El controlador
  de dictado todavía usa `shapingPrompts`; los gatillos de modos necesitan
  integración real y tests de extremo a extremo del controlador.
- El control «Un atajo, Dilo decide» se persiste pero no llega al dictado.
- Hay copy de error y progreso heredado, incluida una ruta del repo en Novedades.
- Reunión y Conversación siguen siendo estados previstos sin experiencia completa.
- La implementación anterior interrumpida de unificación no está aplicada en
  este main. No se recuperó a ciegas sobre el trabajo posterior de Claude.

## Cambios de esta pasada

- Primera pantalla: Dictado, con recordatorio del gatillo configurado.
- Once destinos principales en tres grupos: Tu voz, Ajustes y Dilo.
- Idiomas y traducción dentro de Dictado; Sonidos dentro de Apariencia;
  lectura en voz alta dentro de General, respetando capacidades del anfitrión.
- Actividad dentro de Historial; actualizaciones junto a Acerca de.
- La reescritura heredada queda accesible dentro de Modos con un nombre que
  explica que afecta el dictado normal. Esta agrupación NO unifica sus datos.
- Scroll del sidebar, nombres de destino más claros, progreso en español y
  mensaje de Novedades sin rutas internas. Sin renombrar claves persistidas.

## Qué significa quitar las trazas del árbol de origen

Quitar identidad y conceptos heredados del recorrido cotidiano, no borrar
atribuciones. Se mantienen la licencia MIT, las licencias de terceros en Acerca
de y los agradecimientos del README. Lo que sí cambió (2026-09-21): las
carpetas pasaron a `Dilo/` y `DiloTests/` y el proyecto a `Dilo.xcodeproj`,
porque el árbol dejó de seguir a `upstream` y el nombre heredado ya no compraba
merges baratos. Lo que no se toca: bundle ids y claves persistidas, que
romperían las preferencias de quien ya tiene la app.

Los sonidos Pop y el orbe Siri ya se retiraron del bundle (2026-09-21): lo que
queda es CC0, MIT o propio.

## Orden recomendado para continuar el core

1. **Un único sistema de modos:** migración idempotente que conserve instrucciones,
   ejemplos y preferencias; gatillos funcionales y validados contra todos los
   demás; proveedor congelado por sesión; nunca fallback silencioso de local a remoto.
   El interruptor automático sólo debe mostrarse cuando tenga integración real.
2. **Resultado recuperable:** original antes de limpiar, resultado separado y
   «Copiar último dictado» en memoria sin activar historial persistente.
3. **Notch de dictado terminado:** preparar, escuchar, procesar, resultado y error,
   un diseño principal con mango y menta. Probar Mac mini, notch real,
   pantalla completa, varios monitores y Reducir movimiento.
4. **Biblioteca y reuniones:** persistencia incremental, ambas fuentes de audio,
   recuperación de interrupciones y detalle legible antes de resúmenes.
5. **Asistente conectado:** intención y acción distintas del dictado; integración
   con HUD personal por un contrato explícito, con estado y revisión de acciones.

## Verificación

Por cambio de Swift: ambos targets, paquete propio y suite de app. El layout
requiere verificación visual además de compilar. No presentar una animación del
prototipo como evidencia de rendimiento ni una medición vieja como prueba de
la build actual. Esta pasada no cambia motores, arranque, reposo ni pegado.

Resultado de la validación de esta pasada: `Dilo` Debug y `Dilo-MAS` Debug
compilan; `swift test` pasa 134 tests y la suite de app pasa 469 tests con
`DILO_SUFIJO_ID=.experiencia`. `git diff --check` sin errores. No se ejecutaron
benchmarks nuevos ni se instaló esta build sobre la copia de uso diario.
La revisión visual nativa quedó pendiente por timeout de la herramienta de UI.
El prototipo tiene comprobación de sintaxis JavaScript y estructura; su preview
local no pudo abrirse por la política de URLs del navegador integrado.

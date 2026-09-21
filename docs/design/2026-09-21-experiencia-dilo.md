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

## Qué significa quitar las trazas de Talkify

Quitar identidad y conceptos heredados del recorrido cotidiano, no borrar
atribuciones. Se mantienen MIT, el agradecimiento en Acerca de y README y las
carpetas `Talkify/` y `TalkifyTests/` para mantener el fork. No se hace un
reemplazo masivo que rompa preferencias, IDs, tests o referencias upstream.

Los sonidos Pop y el orbe Siri siguen siendo activos a retirar del bundle antes
de publicar; ocultarlos no equivale a retirarlos. Esto requiere una pasada de
recursos y comprobación del Release independiente del diseño de navegación.

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

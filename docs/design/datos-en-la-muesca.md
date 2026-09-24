# Datos a los costados de la muesca

Pedido de Alfonso, 2026-09-23: «mostrar cosas más entretenidas de forma
permanente, alargar un poquito el notch y poner stats, como los consumos de IA
o los stats del computador […] y que todo sea personalizable». Y: «estaríamos
abarcando cosas que ya hay open source y que sería solamente una aplicación».

Este documento dice qué hay, cómo está armado y **cómo se suma un proveedor
más**. La referencia de todo esto es [CodexBar](https://github.com/steipete/CodexBar)
(MIT), que ya resolvió dónde deja su uso cada herramienta: se lee y se escribe
de nuevo en Swift, no se copia. El día que se adapte código suyo, la atribución
entra en el `LICENSE` antes que el código.

## Qué hay (v1)

| Dato | De dónde sale | Qué muestra | Permisos |
| --- | --- | --- | --- |
| Codex | `~/.codex/sessions/AAAA/MM/DD/rollout-*.jsonl`, último evento `token_count` con `rate_limits` | % de la ventana de 5 h (y semanal en el detalle) | Ninguno |
| Claude | `~/.claude/projects/**/*.jsonl`, bloques de 5 h al modo de `ccusage` | Tokens del bloque: entrada + salida + escritura de caché | Ninguno |
| Claude, % del plan (opcional) | `GET api.anthropic.com/api/oauth/usage` con la sesión de Claude Code del Llavero (`Claude Code-credentials`) | % de la ventana de 5 h | Diálogo del Llavero, una vez |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)`, diferencia entre dos lecturas | % de todo el sistema | Ninguno |
| RAM | `host_statistics64(HOST_VM_INFO64)`: activa + fija + comprimida | % de la memoria física | Ninguno |

En App Store el sandbox no deja leer `~/.claude` ni `~/.codex`
(`Capacidad.consumoDeIADeOtrasApps`): sus tarjetas dicen «No disponible en
esta versión» con el porqué, y quedan CPU y RAM.

## Cómo está armado

- **`DiloCore/Sources/DiloConsumo`** — lo que no sabe nada de la app y se
  prueba con `swift test`: `DatoDeLaMuesca` (qué se puede elegir),
  `DisposicionDeLaMuesca` (qué está encendido y a qué costado va),
  `DeteccionDeFuentes` (si hay de dónde leer, con el disco inyectado),
  `VentanaDeUso` y `ConsumoDeIA` (qué se sabe de un proveedor), un lector por
  fuente (`LectorDeCodex`, `LectorDeClaude`, `ClienteDeUsoDeClaude`,
  `MuestraDelSistema`), `TextoDelDato` (cómo se escribe) y `DetalleDelDato`
  (las filas del hover).
- **`Dilo/CoreHUD/DatosDeLaMuesca.swift`** — la tarea que refresca: CPU y RAM
  cada 3 s, archivos cada 30 s, el plan de Claude cada 2 min. Sin datos
  elegidos no corre nada.
- **La geometría** — `HUDScreenSnapshot.anchoDeLosLados` alarga
  `reposoSize` a los dos lados por igual (`HUDNotchGeometry.anchoDeUnLado`),
  y con eso la ventana, la zona del mouse y la silueta quedan de acuerdo.
- **La vista** — `HUDMarcaDeReposo` dibuja cada costado: etiqueta apagada,
  valor claro, mango desde el 75 % y rojo desde el 90 %.
- **El hover** — con datos, el panel del hover crece
  `HUDNotchGeometry.altoDelDetalleDeDatos` (40 puntos; sigue bajo
  `altoMaximoDelHover`) y `HUDDetalleDeLosDatos` pone debajo del contexto una
  columna por dato: Codex con su ventana de 5 h y la semanal, Claude con los
  tokens del bloque y, si se pidió, el % del plan; cada una con cuánto falta
  para que se reinicie. CPU y RAM, su valor. Letra fija: el alto es fijo.

## Ajustes: la sección «Datos en la muesca»

Pedido de Alfonso, 2026-09-23: «hay que poner en las configuraciones cómo
configurar y activar». Los datos se elegían con dos pickers en Apariencia que
no decían nada; ahora tienen sección propia en el grupo Ajustes, justo después
de Apariencia (`SettingsSection.datosDeLaMuesca`,
`DatosDeLaMuescaSettingsView`). Se llama «Datos en la muesca» y no «La
muesca» porque lo visual de la muesca —tamaño, pantalla, retardo del hover—
sigue en Apariencia.

- **Arriba**: una frase de qué es y una vista previa a tamaño real con la
  muesca de verdad (`DictationHUDShellView`) y valores de ejemplo en los
  costados elegidos. Con el mouse encima abre el panel del hover con el
  detalle.
- **Una tarjeta por fuente** (Claude Code, Codex, CPU, Memoria), cada una con:
  - el **estado detectado en vivo** (`DeteccionDeFuentes`, cada 4 s mientras
    la sección está abierta): *Listo para usar* si hay al menos una sesión
    —`~/.claude/projects/<proyecto>/*.jsonl`,
    `~/.codex/sessions/AAAA/MM/DD/*.jsonl`—, *No encontrado* con el cómo
    («Instala Claude Code y úsalo una vez; Dilo lee sus registros locales, sin
    clave»), o *No disponible en esta versión* en App Store, con el porqué.
    CPU y RAM siempre están listos. La detección corta en el primer `.jsonl`
    que encuentra y mira a lo más 300 carpetas;
  - el **interruptor** y el **costado**. Cabe un dato por costado
    (`DisposicionDeLaMuesca.porCostado`). Lo encendido se guarda en orden
    (`hudDatosDeLaMuesca`, «claude:izquierdo,cpu:derecho»): el que llegó
    primero a un costado se queda, y el que llega después **dice en su
    tarjeta que no cabe**, quién le ocupa el lugar y qué hacer. Si el primero
    se apaga, el que esperaba se ve solo;
  - **qué se lee y de dónde**, en una línea y sin jerga;
  - en Claude, **el % del plan** como sub-opción apagada de fábrica, con la
    regla de las credenciales dicha entera y un botón **Probar ahora** que
    hace una consulta y dice el resultado o la falla en palabras
    (`DatosDeLaMuescaCopy.Prueba`; sesión vencida → «Abre Claude Code para
    que renueve su sesión»).
- **Gemini no tiene tarjeta.** Una tarjeta «Próximamente» es un panel que no
  puede hacer nada, y en Ajustes lo que no se puede hacer se esconde
  (`SettingsSection.isAvailable`). Entra cuando tenga lector (abajo).
- **La elección de antes se migra**: quien tenía algo en los pickers de
  Apariencia (`hudDatoIzquierdo`, `hudDatoDerecho`) lo sigue teniendo en el
  mismo costado.
- **Primeros pasos** dice, en una línea al final y sólo cuando el dictado de
  prueba funcionó, que esto existe y dónde está.

La sección y el hover se revisan en PNG con
`scripts/render-datos-de-la-muesca.sh`, sin lanzar la app.

## La regla de las credenciales

Algunos proveedores sólo dicen su porcentaje a quien presenta la sesión del
usuario. Cuando Dilo la usa:

1. Es **opcional y apagado de fábrica**, con un texto en Ajustes que dice qué
   se lee y a quién se le pregunta.
2. Se lee **en cada consulta** y se suelta: no se guarda, no se registra, y
   sólo viaja al servidor que la emitió.
3. **Nunca se renueva** un token ajeno: dos apps renovando la misma sesión
   terminan cerrándosela a la otra. Si venció, se espera a que la herramienta
   dueña la renueve y mientras tanto se muestra el dato local.
4. Cookies del navegador, no. Es la fuente más frágil y la más invasiva.

## Cómo se suma un proveedor

1. Un caso nuevo en `DatoDeLaMuesca` (el `rawValue` es lo que se guarda: no
   se renombra después) y su `leeArchivosDeOtraApp`. Con eso aparece solo en
   `DatoDeLaMuesca.fuentes`, que es la lista de tarjetas.
2. Un lector en `DiloConsumo` que devuelva `ConsumoDeIA`, con tests armados
   con la forma exacta del archivo o la respuesta. Nada de red ni de carpetas
   de verdad en los tests.
3. Dónde deja sus registros y a qué profundidad, en
   `DeteccionDeFuentes.carpeta(de:en:)` y `niveles(de:)`, con su test contra
   el disco de mentira. Los lectores arrancan de esa misma carpeta.
4. Sus filas del hover en `DetalleDelDato`, y su rama en
   `DatosDeLaMuesca.lado(_:)` y en `refrescar()`, con una cadencia que respete
   el reposo.
5. Su tarjeta en `DatosDeLaMuescaCopy`: título, qué se lee y de dónde
   (`queSeLee`), cómo conseguirlo si no se encuentra (`comoConseguirlo`), y un
   valor de ejemplo para la vista previa (`VistaPreviaDeLosDatos.ejemplo`).
   Todo con su inglés en `Localizable.xcstrings`.
6. Si pide credencial, la regla de arriba entera: la sub-opción apagada de
   fábrica en su tarjeta, con el texto de qué se lee y a quién se le pregunta,
   y «Probar ahora».

## Candidatos, por orden de cuánto se usan

Lo que dice «según CodexBar» está leído de su documentación
(`docs/<proveedor>.md`) el 2026-09-23 y no se probó todavía desde Dilo.

| Proveedor | Fuente según CodexBar | Qué haría falta | Notas |
| --- | --- | --- | --- |
| **Gemini** | Sesión OAuth del CLI de Gemini (`~/.gemini/oauth_creds.json`) contra APIs de cuota privadas de Google | Tener el CLI de Gemini con sesión iniciada | En el Mac de Alfonso no hay sesión del CLI (2026-09-23): la app web de Gemini no deja nada en disco. Pendiente de que lo use |
| **Cursor** | Token de Cursor.app en su base SQLite (`cursorAuth/accessToken`) y APIs de cursor.com | Leer la base de Cursor; credencial ⇒ regla de arriba | |
| **GitHub Copilot** | Device flow de GitHub + API interna de uso de Copilot | Un inicio de sesión propio de Dilo con GitHub | Pide un flujo de OAuth nuevo |
| **OpenRouter** | Clave de API: créditos, tope y gasto (`/api/v1/credits`, `/key`) | Que la persona pegue su clave; guardarla en el Llavero de Dilo | API pública y documentada |
| **OpenAI API** (no ChatGPT) | Admin API: `/v1/organization/costs` y `/usage/completions` | Clave de administrador de la organización | Para cuentas de empresa |
| **Windsurf** | Caché SQLite local (`state.vscdb`) o la web | Leer su base local | Según CodexBar, el local se desactualiza cuando Windsurf está cerrado |
| **Ollama Cloud** | Clave de API o cookies de ollama.com | Clave de API | Las cuotas sólo por cookies |
| **Ollama local / LM Studio** | Su servidor local (`localhost`) | Nada | No es consumo sino qué modelo está cargado; podría ser un dato «Modelo local» |

Otros que CodexBar cubre y quedan para después: Perplexity, Grok (xAI),
Mistral, DeepSeek, Kimi, z.ai, Factory, Amp, Warp, Kiro, Vertex AI, Bedrock.

## Lo que falta

- Más de un dato por costado: `porCostado` es 1 porque la muesca se alarga
  72 puntos por lado. Subirlo es subir `HUDNotchGeometry.anchoDeUnLado` y
  mirar el render en un 1080p.
- Gemini y el resto de los candidatos de arriba.

## Íconos, barrita y avisos (2026-09-24)

«Pondría el ícono de la IA más que el nombre; se ve más bonito si usamos
íconos en general.» Cada costado lleva ahora el ícono del dato y el número, con
una barrita debajo que se llena con el nivel (sólo si el dato es un
porcentaje). El nombre queda para VoiceOver y para el encabezado del detalle
del hover (`IconoDelDato`).

- **Logos de Claude y Codex**: SVG de un color traídos de CodexBar (MIT), en
  el catálogo como plantilla (`LogoClaude`, `LogoCodex`). Los diseños son de
  Anthropic y de OpenAI y se usan para decir de qué herramienta es el número.
  En la versión de App Store hay que pedir permiso o cambiarlos por un SF
  Symbol (guía 5.2.1 de Apple).
- **Sistema**: SF Symbols — `cpu`, `memorychip`, `square.stack.3d.up.fill`
  (GPU), `arrow.down` (red: lo que baja) e `internaldrive`.
- **Fuentes nuevas**: GPU (`PerformanceStatistics` de IOKit), red
  (`NET_RT_IFLIST2`, contadores de 64 bits) y disco (propiedades del volumen
  de arranque). La temperatura queda fuera: en Apple Silicon sólo se lee por
  el SMC, sin API pública.
- **Avisos de límite** (`VigiaDeLimites`): al cruzar el 80 % y el 95 % de una
  ventana con porcentaje —Codex, y el plan de Claude si se pidió—, la muesca
  se abre un momento. Una vez por umbral y por ventana; nunca mientras se
  dicta: si la muesca está ocupada, el aviso espera la vuelta siguiente.
  Interruptor en Ajustes, encendido de fábrica.

## El panel del hover (2026-09-24)

De la lista de lo que hacen otras apps de notch, Alfonso eligió el 3 (próxima
reunión), el 6 (portapapeles junto a los dictados) y los modos. Viven en el
panel que abre el hover (`HUDPanelDelHover`), en este orden y cada sección
sólo si tiene algo:

1. **Recientes** — hasta tres: tus dictados y lo que copias, lo más nuevo
   arriba, con «Copiar» por fila. Reemplaza la línea de contexto. En memoria
   y nada más: se pierde al cerrar Dilo. Lo que un gestor de contraseñas marca
   como oculto, transitorio o autogenerado (convención de nspasteboard.org) no
   entra (`VigiaDelPortapapeles`). El mismo texto no se repite: Dilo pega sus
   dictados por el portapapeles.
2. **Datos** — el detalle de lo que va a los costados.
3. **Próxima reunión** — la primera que no terminó en las próximas 12 horas,
   sin eventos de todo el día, con «Unirse» si el evento trae un enlace de
   Zoom, Meet, Teams, Webex o Whereby (`LectorDelCalendario`). Apagada de
   fábrica; encenderla pide el permiso de calendario, que necesita el
   entitlement `com.apple.security.personal-information.calendars` en los dos
   targets y `NSCalendarsFullAccessUsageDescription`.
4. **Modos** — «Normal» y los de la biblioteca. Elegir uno guarda
   `hudModoDelAtajoGeneral`: desde ahí el atajo de siempre dicta con ese modo;
   los modos con tecla propia siguen con la suya.

El alto es la suma de altos fijos por sección
(`HUDNotchGeometry.altoDelPanelDeHover`), con techo de 190. La ventana abierta
se dimensiona por lo **encendido** en Ajustes (`HUDScreenSnapshot.seccionesPosibles`),
no por todo lo posible: una ventana más grande de lo necesario es pantalla que
no deja pasar clics mientras el hover está abierto.


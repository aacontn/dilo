# Dilo — Un atajo por modo: se acaba el "modo activo"

**Fecha:** 2026-08-05 · **Estado:** diseño aprobado por Alfonso en conversación · **Base:** [proveedor por modo](2026-07-29-proveedor-por-modo.md), que introdujo la IA por modo y los atajos por modo sin terminar de resolver cómo conviven con el atajo general

## De dónde sale esto

Alfonso usó Dilo un día completo y llegó al diagnóstico antes que nadie:

> "El tema de los atajos es un tema. Yo dejaría el atajo de transformar
> opcional, porque yo no quiero que me transforme todo, sino que sea solo
> para correo y para mensaje."

Y sobre la pantalla: _"es súper confusa y no agradable"_.

### Lo que se midió en su instalación

| Atajo                 | Valor guardado          |
| --------------------- | ----------------------- |
| Transformar (general) | `fn+f17`                |
| Modo "Correo"         | `f17` — **sin el `fn`** |

Su teclado emite `fn+f17`. El atajo general coincide y dispara; **el del modo
no coincide nunca.** Por eso reportó que "toma solamente el mismo botón": el
atajo del modo estaba muerto, no compitiendo. La interfaz le dejó guardar un
atajo que no podía dispararse, y nada le avisó.

Los otros cuatro modos no tenían atajo. De cinco modos, **uno era invocable, y
estaba roto**.

Además, su modo Correo tenía el proveedor en OpenAI —sin clave— como residuo
del bug corregido en 0.2.2, donde elegir "Online" preseleccionaba el primer
proveedor del catálogo en vez del que la persona ya usaba.

## El cambio de fondo

**El "modo activo" deja de existir.**

Hoy hay un desplegable ("Prompt activo") que elige un modo, y un atajo general
que lo aplica. Para escribir un correo en vez de un mensaje hay que ir a
Ajustes y cambiar el desplegable.

Pasa a: **cada modo es un prompt + una tecla + un proveedor**, invocable por su
tecla. En palabras de Alfonso:

> "Lo dejaría en lo simple, cada tecla con su modo, porque no veo cómo puede
> ser de otra forma."

## Atajos

**Uno por modo.** De fábrica, **Limpio en `fn+F17`** — la tecla que hoy es
"transformar". Así una instalación nueva tiene algo funcionando de inmediato,
y empata con la conclusión del día anterior: que el dictado ya salga limpio sin
que haya que pensarlo. Los demás modos llegan sin tecla; cada persona asigna
las que quiera, incluidos los modos que cree.

Dos correcciones vienen incluidas porque son la causa del problema:

- **La captura de teclas se arregla.** Debe capturar exactamente lo mismo que
  el resto de los atajos de la app (`fn+F17`, no `f17`). Un atajo que no puede
  dispararse no debe poder guardarse.
- **Se detectan las colisiones.** Asignar una tecla ya ocupada avisa, en vez de
  dejar un atajo muerto en silencio.

## Pantalla Transformar

Dos pestañas: **Modos** y **Proveedor**.

Hoy la página apila tres cosas en un solo scroll —el atajo global, la
configuración de API, y la edición del prompt— que se tocan en momentos
distintos: la API una vez al instalar, el prompt al crear un modo, el modo al
usarlo. Separarlas reconoce eso.

**Modos** es la lista: nombre, ícono, tecla, y si usa modelo local u online.
Tocar un modo abre su detalle — nombre, instrucciones, tecla, y su IA.

**Proveedor** es la configuración general: proveedor, clave, modelo.

**Código se queda** en la lista, sin tecla de fábrica. Alfonso no lo usa nunca
pero pidió explícitamente dejarlo "opcional para la gente, no solamente para
mí".

## Proveedor por modo: se mantiene

Cada modo puede usar un proveedor distinto del general. No es complejidad
gratuita — habilita el caso que importa: **Limpio con el modelo local**
(gratis, instantáneo, sin internet, y para puntuación y mayúsculas sobra) y
**Correo con el proveedor bueno**, donde sí se quiere calidad. Un modo que no
elige usa el general.

## Inicio

Estado arriba —Dilo listo, qué modelo usa, lo último que dictaste— y abajo el
recordatorio de teclas: qué hace cada una. Sin edición; para editar se va a
Transformar.

Hoy el Inicio dice "Modo inteligente activo: fn+F17" como si hubiera un solo
modo inteligente. Con este diseño esa frase deja de tener sentido.

## Migración de la configuración existente

Una instalación viva tiene estado que choca con el diseño nuevo. Debe cargar
sin que nadie pierda lo que había elegido:

- **`post_process_selected_prompt_id`** (el modo activo) desaparece como
  concepto. El modo al que apunta hereda la tecla que tenía el atajo general,
  para no perder la elección de la persona.
- **Atajos que no pueden dispararse** (como `f17` donde el teclado emite
  `fn+f17`) **se borran**, no se intentan corregir adivinando: la app no sabe
  qué teclado tiene la persona, y un atajo inventado sería otro atajo fantasma.
  El modo queda sin tecla, visible en la lista, para que se le asigne una.
- **Proveedores por modo apuntando a un proveedor sin clave** vuelven a
  "General", que es lo que la persona esperaba antes de que el bug se los
  cambiara.

## Alcance

**Entra:** el modelo mental sin modo activo, un atajo por modo con su captura y
detección de colisiones arregladas, la pantalla Transformar en dos pestañas, el
Inicio con estado y recordatorio, y la migración.

**No entra:**

- **El dictado no cambia.** Su atajo, su camino y su modelo se quedan como
  están.
- **La limpieza automática del dictado.** Se evaluó y Alfonso la descartó:
  _"ya lo limpia lo suficiente, no es necesario meterle más cosas"_.
- **El asistente por voz** y su atajo. Necesita su propio modelo configurable,
  que es un diseño aparte.
- **Reuniones**, notas y todo lo que no sea transformar.

## Verificación

- **El atajo de un modo dispara ese modo**, no el general — que es exactamente
  lo que hoy falla.
- **Una tecla ya ocupada no se puede asignar** sin aviso.
- **Un atajo capturado desde la interfaz coincide** con lo que emite el teclado
  (probar con las teclas de función, que son donde apareció el bug).
- **Un `settings.json` de 0.2.2 carga** y conserva la elección de modo de la
  persona.
- **Un modo con proveedor local y otro con proveedor online** funcionan los dos
  en la misma sesión.

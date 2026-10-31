# Probar Reuniones en vivo con audio real

La causa de la pista `ellos` muda y el cálculo de la tasa están demostrados con
los datos de la reunión del 2026-10-31. Lo que sigue no se puede probar sin una
llamada: el tap desde un terminal entrega ceros y nadie toma el Mac mientras
Alfonso lo usa.

## Antes

1. Con Dilo cerrado: `./scripts/instalar-local.sh`, y abrir Dilo.

## El permiso

2. Empezar a grabar con algo sonando. macOS tiene que preguntar por grabar el
   audio del sistema. Aceptar.
3. Si no preguntó: Ajustes del Sistema → Privacidad y seguridad → Grabación de
   pantalla y audio del sistema → «Solo audio del sistema» tiene que listar a
   Dilo. Sin eso, el panel muestra «Sin audio de la llamada: falta un permiso»
   a los 15 s, con «Abrir».
4. Si se dio el permiso con la grabación andando, la marca del parlante tiene
   que encenderse sola en menos de 15 s. Si no pasa, terminar y grabar de nuevo,
   y anotarlo: el rearmado no alcanzó.

## La llamada

5. Una llamada de 5 minutos con **audífonos Bluetooth y su micrófono** (el caso
   que falló) y otra con la salida normal. En las dos, al terminar:
   - `afinfo ellos.m4a` y `afinfo yo.m4a` tienen que durar casi lo mismo;
   - un clic en una línea de otra persona se oye a velocidad normal, sin voz de
     ardilla ni voz lenta (la tasa medida no se pudo oír sin audio real);
   - el guion tiene más de un hablante.
6. Cortar el micrófono de la llamada a la mitad para que los audífonos vuelvan a
   44,1 kHz. El log de `reuniones` tiene que decir «La pista ellos llega a…» y el
   audio seguir a velocidad normal.

## El vivo

7. El panel se abre solo al grabar, sin quitarle el foco a la llamada.
8. Lo dicho aparece por las dos pistas a unos 3 s, primero en gris y después
   firme, «Yo» y «Ellos» intercalados. Subir a leer no te baja de golpe, e «Ir a
   lo último» vuelve.
9. Dictar con Dilo durante la reunión: lo dictado no aparece, el dictado no se
   siente más lento, y lo que dijeron los demás aparece después.
10. Cerrar el panel 1 minuto y abrirlo desde la muesca: está todo.
11. Al terminar, lo dicho sigue a la vista bajo «Afinando el guion…» y queda el
    guion final.

## Las notas

12. Con la llamada activa, clic en «Agregar una nota», escribir, Intro: la nota
    aparece a su hora y el teclado vuelve a la llamada (⌘ de la app de la
    reunión, la barra de espacio para silenciar).
13. Esc con texto escrito: el texto queda en el pie y el teclado vuelve.
14. Clic en la llamada a medio escribir: lo mismo.
15. Pegar con ⌘V en el campo, y dictar con Dilo en el campo.
16. Terminar con una nota a medio escribir: queda guardada.
17. En la carpeta de la reunión: `notas.jsonl`, y `guion.md` con `## Notas` al
    final. La nota sale en «Copiar», en «Copiar para Claude» y al buscarla en
    Reuniones.

## Medir

18. `scripts/metrics.sh` no cubre esto: en una reunión de 30 minutos, mirar la
    CPU de Dilo en Monitor de Actividad (spec: < 25 % de un núcleo) y si el vivo
    alguna vez va a más de 4 s de lo dicho.
19. Agrandar el panel desde el borde; tiene que quedarse del tamaño elegido la
    próxima vez.

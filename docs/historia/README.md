# De dónde viene este código

Dilo Mac no se escribió desde cero. El árbol de la app —el HUD del notch, la
máquina de sesión del dictado y el tap global de teclado— viene de **Talkify**,
de Tornike Gomareli, MIT: <https://github.com/tornikegomareli/Talkify>.

Y el producto viene de **Handy**, de CJ Pais, MIT:
<https://github.com/cjpais/Handy>. De ahí salieron los specs que el Dilo de
Tauri implementó y que esta app reescribió en Swift.

Esta nota es **el único lugar del repo donde esos nombres aparecen fuera de
donde la licencia los pide**, y es a propósito:

- El copyright de los dos se conserva en `LICENSE`, junto al de Dilo, y la app
  los nombra en **Ajustes → Acerca de → Licencias de terceros**. Eso es lo que
  la licencia MIT pide y ahí es donde se cumple, una sola vez en cada lado.
- Dilo se presenta como **producto propio**: no se anuncia como fork ni en la
  portada del README ni en la app. Quien quiera la genealogía completa, la
  tiene acá.
- Los documentos de diseño fechados de `docs/superpowers/` dicen «el árbol de
  origen» o «la app de origen». Son este proyecto: se dejaron sin el nombre
  para no repetir la atribución en cada archivo, no para esconder nada.

Lo que estuvo archivado acá y ya no está: el `CONTEXT.md` de Talkify 0.8.3 y
sus notas de versión de la 0.6.0 a la 0.8.3. Son documentos de ese repo, siguen
publicados ahí, y tener una copia congelada sólo garantizaba que envejeciera
mal. El `CONTEXT.md` de la raíz dice lo que de todo aquello sigue siendo cierto
para Dilo.

El remote `upstream` sigue apuntando al repo de origen: un remote no es un
archivo del proyecto, y sirve para ir a mirar qué cambió allá.

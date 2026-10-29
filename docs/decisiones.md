# Decisiones

- 2026-09-20 · Dilo pasa a app nativa Swift, solo Mac (Apple Silicon, macOS 26+), sobre fork de Talkify (MIT); de Handy se porta el producto, no el código · upstream Handy reescribió su historia y ya no había merge barato.
- 2026-09-20 · `Dilo/app` (Tauri) se congela en 0.3.2: no se borra, cero horas más · todo el esfuerzo va al nativo.
- 2026-09-20 · El notch es la identidad de la app (estados de dictado, reunión, conversación; píldora igual sin notch) · diferenciarse de las demás apps de dictado.
- 2026-09-20 · Decisiones tipadas con reglas por defecto y FoundationModels como escalón; Laya no entra (65 % en español) · medido ese día contra «la app al frente decide» (100 %).
- 2026-09-20 · Reglas de v1: el gatillo nunca escribe símbolos, la píldora sin notch no tapa la barra de menús, nunca tocar el volumen maestro · aprendidas en los spikes.
- 2026-09-22 · Cada build que Alfonso usa se instala en `/Applications/Dilo.app` (reemplazando), firmada con su Developer ID; se abre solo cuando él lo pide · la usa a diario y cambiar de ruta o firma le vuelve a pedir permisos. Builds de prueba van al SSD2.
- 2026-09-24 · En el notch, íconos antes que palabras · «no me gusta que salga copiar».
- 2026-10-15 · Se abandona Dilo-MAS (App Store): «lo hacemos para nosotros»; un solo Dilo instalado, sin copias ni builds viejos tirados · es para uso propio, no para distribuir.
- 2026-10-21 · Reuniones (v2) al estilo FluidMeet: guion con quién dijo qué, diarización local, Claude solo a pedido, datos en `/Volumes/SSD 1/Dilo/reuniones/` · todo local por decisión de Alfonso. Diseño en la rama `docs/diseno-reuniones`.

/// Una cosa que Dilo puede o no puede hacer según dónde corra.
///
/// El target directo las tiene todas; el de App Store pierde las que dependen
/// de la API de Accesibilidad **hacia otra app**, que el sandbox corta sin
/// importar lo que TCC haya concedido (spike 1-2: `-25204 CannotComplete`).
/// La regla es una sola: **lo que no se puede, se esconde**. Consultar antes
/// de dibujar una opción, nunca al apretarla.
public enum Capacidad: String, CaseIterable, Sendable {
  /// Capturar el elemento exacto que tenía el foco antes de dictar, y saber
  /// si es un campo de contraseña. Sin esto el pegado sigue siendo posible
  /// —portapapeles y Cmd+V— pero apunta a la app al frente, no al campo.
  case focoAntesDePegar
  /// Releer lo que está seleccionado en otra app. Es todo Leer en voz alta.
  case relecturaDelFoco
  /// El título de la ventana al frente. Lo pide el notetaker de v2 para
  /// reconocer una reunión; hoy nadie más lo usa.
  case tituloDeVentanaActiva
  /// Dejar el texto donde estabas escribiendo, con portapapeles y Cmd+V.
  /// Es legal en sandbox (precedente TypeMeIt); cuelga de Accesibilidad
  /// concedida, que es un estado de TCC y no de esta capa.
  case pegadoDirecto
  /// El tap de teclado que escucha el gatillo con otra app al frente.
  /// Legal en los dos anfitriones; cuelga de Input Monitoring.
  case atajoGlobal
  /// Grabar lo que suena en el sistema. Medido en sandbox el 2026-09-20:
  /// con `device.audio-input` entrega audio real y sin prompt de TCC —
  /// siempre que la app se lance con `open -a` y no desde el terminal.
  case tapDeAudioDelSistema
  /// Arrastrar un audio al notch. Necesita un monitor global de mouse
  /// (Accesibilidad) y, peor, una extensión de sandbox para el archivo que
  /// un monitor de mouse no otorga: en sandbox se ve el URL y no se puede
  /// abrir. Ahí el archivo entra por el panel de abrir.
  case arrastreDeArchivosAlNotch
  /// Leer cuánto va gastado en Claude Code y en Codex, de sus propias
  /// carpetas (`~/.claude`, `~/.codex`). El sandbox sólo deja ver el
  /// contenedor de la app, así que en App Store esos datos no existen y los
  /// costados de la muesca ofrecen sólo CPU y RAM.
  case consumoDeIADeOtrasApps
}

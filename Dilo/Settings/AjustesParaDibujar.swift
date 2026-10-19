import DiloModes

extension AppSettings {
  /// Lo mismo que `sessionSettings`, sin preguntarle al Llavero: para las
  /// vistas previas de Ajustes, que sólo dibujan la muesca.
  ///
  /// `sessionSettings` arma la foto de una sesión de verdad y por eso mira
  /// qué proveedores tienen clave (`Llavero().tieneClave`, síncrono). Con
  /// Anthropic de proveedor general —lo de fábrica con clave desde la
  /// 0.9.0— la vista previa de Apariencia, la de Datos en la muesca y la de
  /// Transcripciones consultaban el Llavero en cada evaluación de su `body`:
  /// cada paso del deslizador de tamaño, cada vez que el mouse entraba o
  /// salía de la vista previa. Una muesca dibujada no necesita saber de
  /// claves.
  var sessionSettingsParaDibujar: DictationSessionSettings {
    DictationSessionSettings(settings: self, claves: AlmacenEnMemoria())
  }
}

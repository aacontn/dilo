import AppKit
import DiloModes

/// El puente entre el `KeyBinding` de la app —que necesita AppKit y sólo se
/// puede probar con una ventana abierta— y el `Gatillo` de `DiloModes`, que es
/// un valor puro.
///
/// Las reglas de qué tecla sirve viven del lado puro a propósito: el bug que
/// Alfonso encontró dictando (⌥ derecha disparando el segundo idioma en un
/// teclado latino) es exactamente el tipo de cosa que un test sin pantalla
/// atrapa y una revisión a ojo no.
extension KeyBinding {
  var gatillo: Gatillo {
    Gatillo(
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      esModificador: isModifierKey,
      etiqueta: label,
      equivalenteDeMenu: keyEquivalent,
      botonDelMouse: mouseButtonNumber
    )
  }

  init?(_ gatillo: Gatillo) {
    if let boton = gatillo.botonDelMouse {
      var cocoa: NSEvent.ModifierFlags = []
      if gatillo.modifierFlags & Gatillo.Modificador.comando != 0 { cocoa.insert(.command) }
      if gatillo.modifierFlags & Gatillo.Modificador.opcion != 0 { cocoa.insert(.option) }
      if gatillo.modifierFlags & Gatillo.Modificador.control != 0 { cocoa.insert(.control) }
      if gatillo.modifierFlags & Gatillo.Modificador.mayuscula != 0 { cocoa.insert(.shift) }
      guard let binding = KeyBinding.mouseButton(number: boton, modifiers: cocoa) else {
        return nil
      }
      self = binding
      return
    }
    guard let keyCode = gatillo.keyCode else { return nil }
    self = KeyBinding(
      keyCode: keyCode,
      modifierFlags: gatillo.modifierFlags,
      isModifierKey: gatillo.esModificador,
      label: gatillo.etiqueta,
      keyEquivalent: gatillo.equivalenteDeMenu
    )
  }

  /// El veredicto del validador sobre este gatillo. Un atajo que no puede
  /// dispararse no debe poder guardarse (spec 2026-08-05): de los cinco modos
  /// de Alfonso, uno era invocable y estaba roto, y nada se lo dijo.
  var veredicto: ValidadorDeGatillos.Veredicto {
    ValidadorDeGatillos.revisar(gatillo)
  }
}

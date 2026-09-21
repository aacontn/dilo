import Testing

@testable import DiloModes

/// Alfonso tiene un teclado Apple extendido y no podía asignar F18 ni F19: el
/// mapa de nombres terminaba en F15 y de ahí en adelante la tecla se mostraba
/// en blanco. Estos tests son el mapa completo, sin pantalla.
struct NombresDeTeclaTests {
  @Test func nombraLaFilaExtendidaCompleta() {
    let esperado: [Int64: String] = [
      105: "F13", 107: "F14", 113: "F15", 106: "F16",
      64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    for (codigo, nombre) in esperado {
      #expect(NombresDeTecla.nombre(codigo) == nombre, "keyCode \(codigo)")
    }
  }

  @Test func nombraTambienLasDoceDeSiempre() {
    #expect(NombresDeTecla.nombre(122) == "F1")
    #expect(NombresDeTecla.nombre(111) == "F12")
  }

  /// El nombre fijo gana sobre la leyenda: F18 no es lo que imprima la
  /// distribución para el código 79, y una distribución rara no puede
  /// renombrarla.
  @Test func elNombreFijoGanaSobreLaLeyenda() {
    #expect(NombresDeTecla.nombre(79, leyenda: "ß") == "F18")
  }

  @Test func unaTeclaConLeyendaUsaLaLeyendaEnMayuscula() {
    #expect(NombresDeTecla.nombre(12, leyenda: "q") == "Q")
  }

  /// El último recurso nunca es vacío: una fila de ajustes en blanco es la que
  /// hace creer que el atajo no quedó guardado.
  @Test func unaTeclaSinNombreNiLeyendaMuestraSuCodigo() {
    #expect(NombresDeTecla.nombre(79 + 1000) == "Tecla 0x437")
    #expect(NombresDeTecla.nombre(200).isEmpty == false)
    #expect(NombresDeTecla.nombre(200, leyenda: "") == "Tecla 0xC8")
  }

  @Test func nombraLosModificadoresConSuLado() {
    #expect(NombresDeTecla.nombre(63) == "fn")
    #expect(NombresDeTecla.nombre(61) == "⌥ derecha")
    #expect(NombresDeTecla.nombre(54) == "⌘ derecha")
  }

  @Test func nombraElTecladoNumericoYLaNavegacion() {
    #expect(NombresDeTecla.nombre(71) == "Clear")
    #expect(NombresDeTecla.nombre(81) == "Num =")
    #expect(NombresDeTecla.nombre(115) == "Inicio")
    #expect(NombresDeTecla.nombre(117) == "⌦")
  }

  /// AppKit manda las teclas de función como caracteres del área de uso
  /// privado (`NSF18FunctionKey` es `U+F715`). No dibujan nada, así que no
  /// pueden usarse de leyenda: ese era el síntoma exacto.
  @Test func reconoceLosCaracteresPrivadosDeAppKit() {
    #expect(NombresDeTecla.esCaracterPrivado("\u{F715}"))
    #expect(NombresDeTecla.esCaracterPrivado("\u{F700}"))
    #expect(NombresDeTecla.esCaracterPrivado(""))
    #expect(NombresDeTecla.esCaracterPrivado("q") == false)
    #expect(NombresDeTecla.esCaracterPrivado("ñ") == false)
  }

  /// Un código por tecla: dos teclas con el mismo número serían dos atajos que
  /// se pisan y nadie lo vería hasta usarlos.
  @Test func ningunCodigoEstaEnDosMapasALaVez() {
    let funcion = Set(NombresDeTecla.funcion.keys)
    let fijas = Set(NombresDeTecla.fijas.keys)
    let modificadores = Set(NombresDeTecla.modificadores.keys)
    #expect(funcion.isDisjoint(with: fijas))
    #expect(funcion.isDisjoint(with: modificadores))
    #expect(fijas.isDisjoint(with: modificadores))
  }
}

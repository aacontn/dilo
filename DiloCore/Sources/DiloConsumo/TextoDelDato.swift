import Foundation

/// Cómo se escribe cada dato en el costado de la muesca: corto, con cifras
/// que no bailan de ancho.
public enum TextoDelDato {
  /// La etiqueta fija de cada dato.
  public static func etiqueta(_ dato: DatoDeLaMuesca) -> String {
    switch dato {
    case .ninguno: ""
    case .claude: "Claude"
    case .codex: "Codex"
    case .cpu: "CPU"
    case .ram: "RAM"
    }
  }

  /// Un porcentaje entero: «34 %» se lee de un vistazo, «34,2 %» no.
  public static func porcentaje(_ valor: Double) -> String {
    "\(Int(valor.rounded()))%"
  }

  /// Tokens abreviados: 950 → «950», 12 400 → «12k», 3 400 000 → «3,4M».
  public static func tokens(_ valor: Int) -> String {
    switch valor {
    case ..<1_000: return "\(valor)"
    case ..<1_000_000: return "\(Int((Double(valor) / 1_000).rounded()))k"
    default:
      let millones = Double(valor) / 1_000_000
      let texto = millones < 10
        ? String(format: "%.1f", millones).replacingOccurrences(of: ".", with: ",")
        : "\(Int(millones.rounded()))"
      return "\(texto)M"
    }
  }

  /// El valor de una ventana: el porcentaje si la herramienta lo da, si no los
  /// tokens.
  public static func valor(_ ventana: VentanaDeUso) -> String? {
    if let porcentaje = ventana.porcentaje { return self.porcentaje(porcentaje) }
    if let tokens = ventana.tokens { return self.tokens(tokens) }
    return nil
  }

  /// Cuánto falta para que se reinicie una ventana: «2 h 14 min», «8 min».
  public static func faltaPara(_ fecha: Date, desde ahora: Date) -> String {
    let minutos = max(0, Int(fecha.timeIntervalSince(ahora) / 60))
    if minutos < 60 { return "\(minutos) min" }
    let horas = minutos / 60
    if horas >= 24 { return "\(horas / 24) d \(horas % 24) h" }
    return "\(horas) h \(minutos % 60) min"
  }
}

import SwiftUI

/// La barra de llamada de la Conversación en PNG: la vista de verdad
/// (`BarraDeLlamada`, compilada junto con este archivo) dentro de la ventana
/// simulada, una lámina por escena (`FotoDeLaConversacion.Muestra`), más una
/// con todas sobre barra clara y oscura.
extension RenderDeLaMuesca {
  /// La pantalla del Mac mini con la conversación puesta: la ventana abierta
  /// reserva la barra desplegada.
  static var pantallaConLlamada: HUDScreenSnapshot {
    var conLlamada = pantalla
    conLlamada.llevaConversacion = true
    return conLlamada
  }

  static func llamada(_ muestra: FotoDeLaConversacion.Muestra) -> some View {
    let foto = FotoDeLaConversacion.deMuestra(muestra)
    let tamaño = HUDNotchGeometry.tamañoDeLaConversacion(for: pantallaConLlamada, desplegada: foto.desplegada)
    return enLaVentana(
      tamaño: tamaño,
      radio: FormaAbierta.radioDelAviso(para: tamaño),
      en: pantallaConLlamada
    ) {
      BarraDeLlamada(foto: foto, altoDeCabecera: HUDNotchGeometry.alturaDeCabecera(for: pantallaConLlamada))
        .frame(width: tamaño.width, height: tamaño.height, alignment: .top)
    }
  }

  @MainActor
  static func escribirLaConversacion(en carpeta: URL) throws {
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    for muestra in FotoDeLaConversacion.Muestra.allCases {
      try escribir(lienzo(claro: true) { llamada(muestra) }, en: carpeta, como: "conversacion-\(muestra.rawValue)")
      medir("conversacion-\(muestra.rawValue)", llamada(muestra))
    }
    let lamina = HStack(alignment: .top, spacing: 24) {
      ForEach([true, false], id: \.self) { claro in
        VStack(spacing: 18) {
          ForEach(FotoDeLaConversacion.Muestra.allCases, id: \.self) { muestra in
            lienzo(claro: claro) { llamada(muestra) }
          }
        }
      }
    }
    .padding(24)
    .background(Color(white: 0.5))
    try escribir(lamina, en: carpeta, como: "conversacion-todas", escala: 1)
    let cerrada = HUDNotchGeometry.tamañoDeLaConversacion(for: pantallaConLlamada, desplegada: false)
    let abierta = HUDNotchGeometry.tamañoDeLaConversacion(for: pantallaConLlamada, desplegada: true)
    let ventana = HUDNotchGeometry.windowSize(for: pantallaConLlamada)
    print("""
      barra de llamada: \(Int(cerrada.width))×\(Int(cerrada.height)) pt, \
      desplegada \(Int(abierta.width))×\(Int(abierta.height)) pt, \
      ventana abierta con llamada \(Int(ventana.width))×\(Int(ventana.height)) pt
      """)
  }
}
